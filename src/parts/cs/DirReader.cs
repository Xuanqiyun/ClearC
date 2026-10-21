// ==================== 读一个文件夹里的条目：一次读一大批，文件名用到时才转成字符串 ====================
// Windows 上用 GetFileInformationByHandleEx 一次读 64 KB 的目录记录；第一次用时和 FindFirstFileEx 的结果核对，
// 不一致就一直用 FindFirstFileEx。不是 Windows（测试用）时用 .NET 自带的列举。
public sealed class DirReader {
    public static volatile int Mode;      // 0 还没定  1 批量读  2 FindFirstFileEx  3 .NET
    static int tests, mismatches;
    static readonly object gate = new object();

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FD {
        public uint attr;
        public uint c1, c2, a1, a2, w1, w2;
        public uint sizeHigh, sizeLow, r0, r1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string alt;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out FD lpFindFileData, int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextFileW(IntPtr hFindFile, out FD lpFindFileData);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr hFindFile);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(IntPtr h, int infoClass, IntPtr buffer, uint size);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    static readonly IntPtr BAD = new IntPtr(-1);
    const int BUF = 64 * 1024;

    readonly int force;                    // 0 = 按 Mode；其他 = 固定用这种方式（自检时用）
    int mode;
    IntPtr h = BAD, hf = BAD, hbuf = IntPtr.Zero;
    byte[] buf;
    int pos, len; bool more, first;
    FD fd;
    List<FileSystemInfo> list; int li;
    string dirPath; int count;
    public bool FellBack;                  // 批量读出错，这个文件夹改用了 FindFirstFileEx

    public uint Attr; public long Size, Write;
    public uint Tag;                       // 重解析点的类型（有重解析点时才有）
    int nameOff, nameLen; string name;

    public DirReader() { force = 0; }
    DirReader(int forceMode) { force = forceMode; }

    public bool IsDir { get { return (Attr & 0x10) != 0; } }
    public bool IsReparse { get { return (Attr & 0x400) != 0; } }
    // 指向别处的链接（目录联接、符号链接这类「代替名字」的重解析点）。OneDrive 等云端文件夹也带重解析点，但不是链接，里面的东西要算
    public bool IsLink { get { return IsReparse && (Tag == 0 || (Tag & 0x20000000) != 0); } }
    public string Name { get { if (name == null && mode == 1) name = Encoding.Unicode.GetString(buf, nameOff, nameLen); return name; } }

    static bool Win { get { return System.IO.Path.DirectorySeparatorChar == '\\'; } }
    public static string LongPath(string dir) {
        string d = dir.TrimEnd('\\', '/');
        if (d.Length == 2 && d[1] == ':') return "\\\\?\\" + d + "\\";
        if (d.StartsWith("\\\\?\\")) return d;
        if (d.StartsWith("\\\\")) return "\\\\?\\UNC\\" + d.Substring(2);
        return "\\\\?\\" + d;
    }

    public bool Open(string dir) {
        Close();
        mode = force != 0 ? force : ChooseMode(dir);
        name = null; dirPath = dir; count = 0;
        if (mode == 3) {
            try { list = new List<FileSystemInfo>(new DirectoryInfo(dir).EnumerateFileSystemInfos()); li = 0; return true; }
            catch { list = null; return false; }
        }
        if (mode == 2) return OpenFind(dir);
        h = CreateFileW(LongPath(dir), 0x0001 /*FILE_LIST_DIRECTORY*/, 7, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0x02000000 /*BACKUP_SEMANTICS*/, IntPtr.Zero);
        if (h == BAD) return false;
        if (hbuf == IntPtr.Zero) { hbuf = Marshal.AllocHGlobal(BUF); buf = new byte[BUF]; }
        pos = 0; len = 0; more = true;
        return true;
    }

    bool OpenFind(string dir) {
        string p = LongPath(dir); if (!p.EndsWith("\\")) p += "\\";
        hf = FindFirstFileExW(p + "*", 1, out fd, 0, IntPtr.Zero, 2);
        if (hf == BAD) return false;
        first = true; return true;
    }

    public bool Next() {
        name = null; Tag = 0;
        if (mode == 3) {
            while (list != null && li < list.Count) {
                FileSystemInfo e = list[li++];
                try {
                    Attr = (uint)e.Attributes; count++;
                    FileInfo fi = e as FileInfo;
                    Size = fi != null ? fi.Length : 0;
                    Write = e.LastWriteTimeUtc.ToFileTimeUtc();
                    name = e.Name;
                    return true;
                } catch { }
            }
            return false;
        }
        if (mode == 2) {
            while (true) {
                if (first) first = false;
                else if (!FindNextFileW(hf, out fd)) return false;
                if (fd.name == "." || fd.name == "..") continue;
                Attr = fd.attr; Size = ((long)fd.sizeHigh << 32) | fd.sizeLow; Write = ((long)fd.w2 << 32) | fd.w1;
                if ((Attr & 0x400) != 0) Tag = fd.r0;      // dwReserved0：重解析点的类型
                name = fd.name; count++;
                return true;
            }
        }
        while (true) {
            if (pos >= len) {
                if (!more) return false;
                if (!GetFileInformationByHandleEx(h, 14 /*FileFullDirectoryInfo*/, hbuf, BUF)) {
                    int err = Marshal.GetLastWin32Error();
                    more = false;
                    // 一条都还没读到就出错（不是「没有了」）：这个文件夹改用 FindFirstFileEx 再列一遍，免得当成空文件夹
                    if (count == 0 && err != 18 /*NO_MORE_FILES*/ && err != 2 /*FILE_NOT_FOUND*/) {
                        CloseHandle(h); h = BAD;
                        FellBack = true;
                        if (!OpenFind(dirPath)) return false;
                        mode = 2;
                        return Next();
                    }
                    return false;
                }
                Marshal.Copy(hbuf, buf, 0, BUF);
                pos = 0; len = BUF;
            }
            int e = pos;
            int next = BitConverter.ToInt32(buf, e);
            int nl = BitConverter.ToInt32(buf, e + 60);
            if (next < 0 || nl < 0 || e + 68 + nl > BUF) { more = false; return false; }
            pos = next == 0 ? len : e + next;
            if (nl == 2 && buf[e + 68] == '.' && buf[e + 69] == 0) continue;
            if (nl == 4 && buf[e + 68] == '.' && buf[e + 69] == 0 && buf[e + 70] == '.' && buf[e + 71] == 0) continue;
            Attr = BitConverter.ToUInt32(buf, e + 56);
            Size = BitConverter.ToInt64(buf, e + 40);
            Write = BitConverter.ToInt64(buf, e + 24);
            if ((Attr & 0x400) != 0) Tag = BitConverter.ToUInt32(buf, e + 64);   // 有重解析点时 EaSize 这一格放的是它的类型
            nameOff = e + 68; nameLen = nl; count++;
            return true;
        }
    }

    public void Close() {
        if (h != BAD) { CloseHandle(h); h = BAD; }
        if (hf != BAD) { FindClose(hf); hf = BAD; }
        list = null;
    }
    public void Free() { Close(); if (hbuf != IntPtr.Zero) { Marshal.FreeHGlobal(hbuf); hbuf = IntPtr.Zero; } }
    ~DirReader() { Close(); if (hbuf != IntPtr.Zero) { Marshal.FreeHGlobal(hbuf); hbuf = IntPtr.Zero; } }

    static int ChooseMode(string dir) {
        if (!Win) return 3;
        int m = Mode;
        if (m != 0) return m;
        lock (gate) {
            if (Mode != 0) return Mode;
            int r = SelfTest(dir);
            if (r == 1) { Mode = 1; return 1; }
            // 对不上可能只是那个文件夹正好在变：换几个文件夹再试，三个都对不上才一直用 FindFirstFileEx
            if (r == 2 && ++mismatches >= 3) Mode = 2;
            else if (++tests >= 20) Mode = 2;
            return 2;
        }
    }
    // 同一个文件夹用两种方式各列一遍：个数、名字、大小、时间、属性都一样，才用批量读
    // 自检用：同一个文件夹两种方式各列一遍，说明有没有差别
    public static string Compare(string dir) {
        if (!Win) return "not Windows";
        DirReader a = new DirReader(1), b = new DirReader(2);
        try {
            if (!b.Open(dir)) return "cannot list";
            if (!a.Open(dir)) return "batch read: cannot open";
            Dictionary<string, string> sa = new Dictionary<string, string>(StringComparer.Ordinal), sb = new Dictionary<string, string>(StringComparer.Ordinal);
            while (a.Next()) { sa[a.Name] = a.Attr + "|" + a.Size + "|" + a.Write + "|" + a.Tag; if (sa.Count > 200000) break; }
            while (b.Next()) { sb[b.Name] = b.Attr + "|" + b.Size + "|" + b.Write + "|" + b.Tag; if (sb.Count > 200000) break; }
            int diff = 0; string first = "";
            foreach (KeyValuePair<string, string> kv in sb) {
                string v;
                if (!sa.TryGetValue(kv.Key, out v) || v != kv.Value) { diff++; if (first.Length == 0) first = kv.Key + " find=" + kv.Value + " batch=" + (v ?? "missing"); }
            }
            foreach (string k in sa.Keys) if (!sb.ContainsKey(k)) { diff++; if (first.Length == 0) first = k + " only in batch"; }
            return "batch " + sa.Count + ", find " + sb.Count + ", differ " + diff + (a.FellBack ? ", batch fell back" : "") + (first.Length > 0 ? " (first: " + first + ")" : "");
        } catch (Exception ex) { return "error " + ex.GetType().Name + ": " + ex.Message; }
        finally { a.Free(); b.Free(); }
    }
    // 返回 1 一致  2 对不上  0 看不出来（文件太少、打不开）
    static int SelfTest(string dir) {
        DirReader a = new DirReader(1), b = new DirReader(2);
        try {
            if (!b.Open(dir)) return 0;
            if (!a.Open(dir)) return 2;
            Dictionary<string, string> sa = new Dictionary<string, string>(StringComparer.Ordinal), sb = new Dictionary<string, string>(StringComparer.Ordinal);
            while (a.Next()) { sa[a.Name] = a.Attr + "|" + a.Size + "|" + a.Write + "|" + a.Tag; if (sa.Count > 5000) break; }
            while (b.Next()) { sb[b.Name] = b.Attr + "|" + b.Size + "|" + b.Write + "|" + b.Tag; if (sb.Count > 5000) break; }
            if (sb.Count < 3 || sb.Count > 5000) return 0;  // 太少看不出来；太多只比了一部分
            if (sa.Count != sb.Count) return 2;
            foreach (KeyValuePair<string, string> kv in sb) { string v; if (!sa.TryGetValue(kv.Key, out v) || v != kv.Value) return 2; }
            return 1;
        } catch { return 2; }
        finally { a.Free(); b.Free(); }
    }
}

// 快速统计文件夹大小：不进入链接目录（搬走后留下的链接不会把别的盘算进来），Files/Bytes 实时可读，用来显示进度。
// SSD 上多线程一起数，机械硬盘上线程少一点（来回寻道反而慢）
public static class DirStat {
    public static long Files, Bytes;
    // 统计时跳过的特殊项目（链接、用 Windows 压缩功能压过的文件等）的个数和第一个的位置
    public static long Reparse; public static string ReparseSample;
    // 用户点了「取消」：数到一半就停。结果不完整，调用方看到取消标记后不会再用它做判断
    public static volatile bool Cancel;
    public static volatile bool ThreadsReady;
    static readonly Dictionary<char, int> threads = new Dictionary<char, int>();
    public static void SetThreads(string drive, int n) { if (string.IsNullOrEmpty(drive)) return; lock (threads) threads[char.ToUpperInvariant(drive[0])] = Math.Max(1, Math.Min(16, n)); }
    public static int ThreadsFor(string path) {
        int n;
        if (!string.IsNullOrEmpty(path) && path.Length >= 2 && path[1] == ':') { lock (threads) { if (threads.TryGetValue(char.ToUpperInvariant(path[0]), out n)) return n; } }
        return Math.Max(2, Math.Min(4, Environment.ProcessorCount));
    }

    public static long Measure(string root) {
        Files = 0; Bytes = 0; Reparse = 0; ReparseSample = "";
        if (string.IsNullOrEmpty(root)) return 0;
        try { if (!Directory.Exists(root)) return 0; } catch { return 0; }
        string r0 = root.TrimEnd('\\', '/');
        if (r0.Length == 0 || (r0.Length == 2 && r0[1] == ':')) r0 = root;
        ConcurrentStack<string> work = new ConcurrentStack<string>();
        int pending = 1; work.Push(r0);
        object sampleLock = new object();
        int n = ThreadsFor(root);
        // 先在调用的线程里数，待数的文件夹多起来才逐个加线程：统计很多个小文件夹时不用每次都开一堆线程
        List<Thread> helpers = new List<Thread>();
        int started = 1;
        ThreadStart job = null;
        job = delegate {
            DirReader r = new DirReader();
            try {
                while (true) {
                    string d;
                    if (work.TryPop(out d)) {
                        try {
                            if (!Cancel && r.Open(d)) {
                                long f = 0, b = 0;
                                string sep = (d.EndsWith("\\") || d.EndsWith("/")) ? "" : System.IO.Path.DirectorySeparatorChar.ToString();
                                while (r.Next()) {
                                    if (r.IsReparse) {
                                        if (Interlocked.Increment(ref Reparse) == 1) lock (sampleLock) ReparseSample = d + sep + r.Name;
                                        continue;
                                    }
                                    if (r.IsDir) { Interlocked.Increment(ref pending); work.Push(d + sep + r.Name); }
                                    else { f++; b += r.Size; if ((f & 1023) == 0) { Interlocked.Add(ref Files, f); Interlocked.Add(ref Bytes, b); f = 0; b = 0; } }
                                }
                                Interlocked.Add(ref Files, f); Interlocked.Add(ref Bytes, b);
                                if (n > 1 && Volatile.Read(ref started) < n && !work.IsEmpty) {   // IsEmpty 很快；Count 要数一遍
                                    if (Interlocked.Increment(ref started) <= n) {
                                        try { Thread t = new Thread(job); t.IsBackground = true; t.Start(); lock (helpers) helpers.Add(t); }
                                        catch { Interlocked.Decrement(ref started); }
                                    } else Interlocked.Decrement(ref started);
                                }
                            }
                        } catch { }
                        finally { r.Close(); }
                        if (Interlocked.Decrement(ref pending) == 0) break;
                    } else {
                        if (Volatile.Read(ref pending) == 0) break;
                        Thread.Sleep(1);
                    }
                }
            } finally { r.Free(); }
        };
        job();
        while (true) {
            Thread[] ts; lock (helpers) ts = helpers.ToArray();
            foreach (Thread t in ts) t.Join();
            lock (helpers) { if (helpers.Count == ts.Length) break; }
        }
        return Bytes;
    }
}

