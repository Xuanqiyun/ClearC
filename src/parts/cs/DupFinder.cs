using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// 扫描位置
public class RootItem {
    public string Path { get; set; }
    public string Label { get; set; }
    public string Detail { get; set; }
    public bool Removable { get; set; }
    public bool Enabled { get; set; }
}

// 界面里的一行（一个文件副本）
public class DupRow : INotifyPropertyChanged {
    public static bool Dirty;
    public int GroupId { get; set; }
    public string GroupName { get; set; }
    public string GroupMeta { get; set; }
    public string GroupBadge { get; set; }
    public string GroupBadgeTip { get; set; }
    string _badgeBg, _badgeFg;
    public string GroupBadgeBg { get { return Theme.B(_badgeBg); } set { _badgeBg = value; } }
    public string GroupBadgeFg { get { return Theme.F(_badgeFg); } set { _badgeFg = value; } }
    public bool Verified { get; set; }
    public string Path { get; set; }
    public string Dir { get; set; }
    public string FileName { get; set; }
    public string Modified { get; set; }
    public long ModifiedTicks { get; set; }
    public long Size { get; set; }
    public string Risk { get; set; }
    public bool HasRisk { get; set; }
    string _type; public string TypeBrush { get { return Theme.F(_type); } set { _type = value; } }
    public bool Protected { get; set; }          // 在 C 盘个人文件夹里
    public bool Blocked { get; set; }            // 系统位置、软件文件夹、搬家后的数据、聊天记录：怎么都不能删（不受个人文件夹开关影响）
    private bool _can = true;
    public bool CanDelete {
        get { return _can; }
        set { if (_can != value) { _can = value; PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("CanDelete")); } }
    }
    private bool _del;
    public bool ToDelete {
        get { return _del; }
        set {
            if (_del != value) {
                _del = value; Dirty = true;
                PropertyChangedEventHandler h = PropertyChanged;
                if (h != null) h(this, new PropertyChangedEventArgs("ToDelete"));
            }
        }
    }
    public event PropertyChangedEventHandler PropertyChanged;
}

public class DupFile {
    public string Path;
    public long Size;
    public DateTime Modified;
    public string Risk = "";
    public string Key;          // 名字|大小
    public ulong H1, H2;        // 头尾指纹、深度指纹
    public bool Full;           // 指纹覆盖了整个文件内容
    public bool Bad;            // 读不了
}

public class DupGroup {
    public string Name;
    public long Size;
    public bool Verified;       // true：组内每个文件都读完整个内容算过指纹
    public List<DupFile> Files = new List<DupFile>();
    public long Waste { get { return Size * (Files.Count - 1); } }
}

// 64 位快速哈希（xxHash64 的轮函数和收尾混合），4 路并行累加，每 32 字节一轮
public sealed class FastHasher {
    const ulong P1 = 11400714785074694791UL, P2 = 14029467366897019727UL, P3 = 1609587929392839161UL,
                P4 = 9650029242287828579UL, P5 = 2870177450012600261UL;
    ulong v1, v2, v3, v4;
    long total;
    readonly byte[] tail = new byte[32];
    int tailLen;
    ulong[] lanes = new ulong[1 << 17];

    public FastHasher() { Reset(); }
    public void Reset() { unchecked { v1 = P1 + P2; v2 = P2; v3 = 0; v4 = 0UL - P1; } total = 0; tailLen = 0; }

    static ulong Rotl(ulong x, int r) { return (x << r) | (x >> (64 - r)); }
    static ulong Round(ulong acc, ulong input) { unchecked { acc += input * P2; acc = Rotl(acc, 31); return acc * P1; } }
    static ulong Merge(ulong acc, ulong val) { unchecked { acc ^= Round(0, val); return acc * P1 + P4; } }

    public void Update(byte[] buf, int off, int count) {
        if (count <= 0) return;
        total += count;
        if (tailLen > 0) {
            int take = Math.Min(32 - tailLen, count);
            Buffer.BlockCopy(buf, off, tail, tailLen, take);
            tailLen += take; off += take; count -= take;
            if (tailLen < 32) return;
            Stripe(tail);
            tailLen = 0;
        }
        int bytes = (count / 32) * 32;
        if (bytes > 0) {
            int nl = bytes / 8;
            if (lanes.Length < nl) lanes = new ulong[nl];
            Buffer.BlockCopy(buf, off, lanes, 0, bytes);
            ulong a = v1, b = v2, c = v3, d = v4;
            ulong[] L = lanes;
            unchecked {
                for (int i = 0; i < nl; i += 4) {
                    a = Rotl(a + L[i] * P2, 31) * P1;
                    b = Rotl(b + L[i + 1] * P2, 31) * P1;
                    c = Rotl(c + L[i + 2] * P2, 31) * P1;
                    d = Rotl(d + L[i + 3] * P2, 31) * P1;
                }
            }
            v1 = a; v2 = b; v3 = c; v4 = d;
            off += bytes; count -= bytes;
        }
        if (count > 0) { Buffer.BlockCopy(buf, off, tail, 0, count); tailLen = count; }
    }

    void Stripe(byte[] b) {
        v1 = Round(v1, BitConverter.ToUInt64(b, 0));
        v2 = Round(v2, BitConverter.ToUInt64(b, 8));
        v3 = Round(v3, BitConverter.ToUInt64(b, 16));
        v4 = Round(v4, BitConverter.ToUInt64(b, 24));
    }

    public ulong Final() {
        unchecked {
            ulong h;
            if (total >= 32) {
                h = Rotl(v1, 1) + Rotl(v2, 7) + Rotl(v3, 12) + Rotl(v4, 18);
                h = Merge(h, v1); h = Merge(h, v2); h = Merge(h, v3); h = Merge(h, v4);
            } else h = v3 + P5;
            h += (ulong)total;
            int i = 0;
            for (; i + 8 <= tailLen; i += 8) { h ^= Round(0, BitConverter.ToUInt64(tail, i)); h = Rotl(h, 27) * P1 + P4; }
            for (; i < tailLen; i++) { h ^= tail[i] * P5; h = Rotl(h, 11) * P1; }
            h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
            return h;
        }
    }
}

// 查重：
// 1. 多线程列举文件，按（名字, 大小）分桶，只有桶里有 2 个以上才可能重复
// 2. 只读头尾各 64 KB 算指纹，筛掉绝大多数
// 3. 剩下的：16 MB 以内读全文；更大的抽 16 处各 64 KB（完整比对模式则全部读完）
// 4. 每块磁盘单独安排线程：固态多线程并行，机械硬盘单线程按路径顺序读
// 抽样判定的组，删除前由 SameContent 逐字节完整比对，不同就不删
public static class DupFinder {
    public static volatile string Phase = "";
    public static volatile string Current = "";
    public static long FilesSeen, DirsSeen, CandidateFiles, BytesDone, BytesTotal, GroupsFound, FilesDone, FilesTotal;
    public static long VerifyDone, VerifyTotal;
    public static volatile bool Cancel;
    public static volatile bool UsedFastEnum;

    const int BLOCK = 64 * 1024;
    const long FULL_LIMIT = 16L * 1024 * 1024;
    const int SAMPLES = 16;

    static Dictionary<string, bool> MakeSet(string[] items) {
        Dictionary<string, bool> d = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (string s in items) d[s] = true;
        return d;
    }

    // 不进入的目录：系统、已安装程序、软件内部数据、开发环境。这些地方的「重复」是正常的，删了会坏东西。
    static readonly Dictionary<string, bool> SkipDirs = MakeSet(new string[] {
        "$Recycle.Bin", "System Volume Information", "Program Files", "Program Files (x86)", "ProgramData",
        "AppData", "WindowsApps", "Windows.old", "$WINDOWS.~BT", "$WINDOWS.~WS", "$WinREAgent", "$SysReset",
        "$GetCurrent", "Recovery", "MSOCache", "Config.Msi", "PerfLogs",
        "node_modules", ".git", ".svn", ".hg", "site-packages", "__pycache__", ".venv", "venv", "envs",
        ".conda", "anaconda3", "miniconda3", "Anaconda", "Miniconda", ".cache", ".cargo", ".rustup",
        ".gradle", ".m2", ".nuget", ".npm", ".vscode", ".vscode-insiders", ".cursor", ".codex",
        "steamapps", "SteamLibrary"
    });

    // 不比对的文件类型：程序库和系统小文件，同名同内容是正常的（每个软件都带一份）
    static readonly Dictionary<string, bool> SkipExt = MakeSet(new string[] {
        ".dll", ".sys", ".ocx", ".pyd", ".so", ".node", ".mui", ".cat", ".manifest", ".lnk", ".ini",
        ".tmp", ".pdb", ".lib", ".obj", ".pyc", ".drv", ".efi"
    });

    // ================= 列举 =================
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WIN32_FIND_DATAW {
        public uint dwFileAttributes;
        public uint ftCreationLow, ftCreationHigh, ftAccessLow, ftAccessHigh, ftWriteLow, ftWriteHigh;
        public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out WIN32_FIND_DATAW lpFindFileData, int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATAW lpFindFileData);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr hFindFile);

    const uint ATTR_DIR = 0x10, ATTR_REPARSE = 0x400, ATTR_SYSTEM = 0x4, ATTR_OFFLINE = 0x1000, ATTR_RECALL = 0x440000;

    sealed class EnumJob {
        public readonly ConcurrentStack<string> Work = new ConcurrentStack<string>();
        public readonly ConcurrentDictionary<string, byte> Seen = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        public readonly List<Dictionary<string, List<DupFile>>> Results = new List<Dictionary<string, List<DupFile>>>();
        public int Pending;
        public long MinSize, MaxSize;
        public bool MatchName, Fast;
        public Dictionary<string, bool> Allow;
        public string SysRoot;

        public void Push(string d) { Interlocked.Increment(ref Pending); Work.Push(d); }

        public void Run() {
            Dictionary<string, List<DupFile>> local = new Dictionary<string, List<DupFile>>();
            lock (Results) Results.Add(local);
            while (!Cancel) {
                string d;
                if (Work.TryPop(out d)) {
                    try { ScanDir(d, local); } catch { }
                    Interlocked.Decrement(ref Pending);
                } else {
                    if (Interlocked.CompareExchange(ref Pending, 0, 0) == 0) break;
                    Thread.Sleep(1);
                }
            }
        }

        void ScanDir(string d, Dictionary<string, List<DupFile>> local) {
            string key = d.TrimEnd('\\', '/');
            if (key.Length == 0) key = d;
            if (!Seen.TryAdd(key, 0)) return;
            if (SysRoot.Length > 0 && string.Equals(key, SysRoot, StringComparison.OrdinalIgnoreCase)) return;
            Interlocked.Increment(ref DirsSeen);
            Current = d;
            bool atRoot = key.Length <= 2 || key == "/";
            if (Fast) ScanFast(key, atRoot, local); else ScanSlow(d, atRoot, local);
        }

        // 一次读一大批目录记录（见 DirReader）；每个线程留一个，不用每个文件夹都重新分配缓冲区
        [ThreadStatic] static DirReader reader;
        void ScanFast(string dir, bool atRoot, Dictionary<string, List<DupFile>> local) {
            DirReader r = reader;
            if (r == null) { r = new DirReader(); reader = r; }
            if (!r.Open(dir)) return;
            try {
                while (!Cancel && r.Next()) Entry(dir, r.Name, r.Attr, r.Size, r.Write, atRoot, local);
            } finally { r.Close(); }
        }

        void ScanSlow(string d, bool atRoot, Dictionary<string, List<DupFile>> local) {
            DirectoryInfo di = new DirectoryInfo(d);
            string dir = di.FullName.TrimEnd('\\', '/');
            foreach (FileSystemInfo e in di.EnumerateFileSystemInfos()) {
                uint a;
                try { a = (uint)e.Attributes; } catch { continue; }
                long size = 0, ft = 0;
                FileInfo fi = e as FileInfo;
                if (fi != null) {
                    try { size = fi.Length; ft = fi.LastWriteTime.ToFileTime(); } catch { continue; }
                }
                Entry(dir, e.Name, a, size, ft, atRoot, local);
            }
        }

        void Entry(string dir, string name, uint a, long size, long ft, bool atRoot, Dictionary<string, List<DupFile>> local) {
            if ((a & ATTR_REPARSE) != 0) return;     // 链接/快捷目录不进，避免同一份文件算两次
            string full = dir + System.IO.Path.DirectorySeparatorChar + name;
            if ((a & ATTR_DIR) != 0) {
                if (SkipDirs.ContainsKey(name)) return;
                if (atRoot && string.Equals(name, "Windows", StringComparison.OrdinalIgnoreCase)) return;
                Push(full);
                return;
            }
            if ((a & (ATTR_SYSTEM | ATTR_OFFLINE)) != 0) return;
            if ((a & ATTR_RECALL) != 0) return;     // OneDrive 等云端占位文件，读它会触发下载
            if (size < MinSize) return;
            if (MaxSize > 0 && size > MaxSize) return;
            int dot = name.LastIndexOf('.');
            string ext = dot >= 0 ? name.Substring(dot) : "";
            if (SkipExt.ContainsKey(ext)) return;
            if (Allow != null && !Allow.ContainsKey(ext)) return;
            Interlocked.Increment(ref FilesSeen);
            string k = (MatchName ? name.ToLowerInvariant() : "") + "|" + size.ToString();
            List<DupFile> lst;
            if (!local.TryGetValue(k, out lst)) { lst = new List<DupFile>(1); local[k] = lst; }
            DupFile df = new DupFile();
            df.Path = full; df.Size = size; df.Key = k;
            try { df.Modified = ft > 0 ? DateTime.FromFileTime(ft) : DateTime.MinValue; } catch { df.Modified = DateTime.MinValue; }
            lst.Add(df);
        }
    }

    // 先用一个目录核对一下快速列举的结果和 .NET 自带列举是否一致，不一致就不用快速列举
    static bool FastEnumWorks(string probe) {
        try {
            int slow = 0;
            foreach (string x in Directory.EnumerateFileSystemEntries(probe)) { slow++; if (slow > 2000) break; }
            string dir = probe.TrimEnd('\\', '/');
            string pattern = dir.StartsWith("\\\\") ? "\\\\?\\UNC\\" + dir.Substring(2) + "\\*" : "\\\\?\\" + dir + "\\*";
            WIN32_FIND_DATAW fd;
            IntPtr h = FindFirstFileExW(pattern, 1, out fd, 0, IntPtr.Zero, 2);
            if (h == new IntPtr(-1)) return false;
            int fast = 0;
            try {
                do { if (fd.cFileName != "." && fd.cFileName != "..") { fast++; if (fast > 2000) break; } } while (FindNextFileW(h, out fd));
            } finally { FindClose(h); }
            return fast == slow;
        } catch { return false; }
    }

    // ================= 读文件 =================
    sealed class IoWorker {
        public readonly byte[] Buf = new byte[1 << 20];
        public readonly FastHasher H = new FastHasher();
    }

    static FileStream Open(string p, bool sequential) {
        try { return new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, sequential ? FileOptions.SequentialScan : FileOptions.RandomAccess); }
        catch { return null; }
    }

    static int ReadFull(Stream s, byte[] buf, int count) {
        int total = 0;
        while (total < count) {
            int n = s.Read(buf, total, count - total);
            if (n <= 0) break;
            total += n;
        }
        return total;
    }

    // 第 2 步：头尾各 64 KB；128 KB 以内的小文件直接整个读
    static void HashHeadTail(DupFile f, IoWorker w) {
        FileStream fs = Open(f.Path, false);
        if (fs == null) { f.Bad = true; return; }
        try {
            w.H.Reset();
            if (f.Size <= 2 * BLOCK) {
                int n = ReadFull(fs, w.Buf, (int)f.Size);
                if (n != f.Size) { f.Bad = true; return; }
                w.H.Update(w.Buf, 0, n);
                Interlocked.Add(ref BytesDone, n);
                f.Full = true;
            } else {
                int n = ReadFull(fs, w.Buf, BLOCK);
                w.H.Update(w.Buf, 0, n);
                fs.Position = f.Size - BLOCK;
                int m = ReadFull(fs, w.Buf, BLOCK);
                w.H.Update(w.Buf, 0, m);
                Interlocked.Add(ref BytesDone, n + m);
                if (n != BLOCK || m != BLOCK) { f.Bad = true; return; }
            }
            f.H1 = w.H.Final();
        } catch { f.Bad = true; }
        finally { fs.Dispose(); Interlocked.Increment(ref FilesDone); }
    }

    // 第 3 步：读全文，或抽 16 处
    static void HashDeep(DupFile f, IoWorker w, bool exact) {
        bool full = exact || f.Size <= FULL_LIMIT;
        FileStream fs = Open(f.Path, full);
        if (fs == null) { f.Bad = true; return; }
        try {
            w.H.Reset();
            if (full) {
                long left = f.Size;
                Current = f.Path;
                while (left > 0 && !Cancel) {
                    int n = ReadFull(fs, w.Buf, (int)Math.Min(w.Buf.Length, left));
                    if (n <= 0) break;
                    w.H.Update(w.Buf, 0, n);
                    left -= n;
                    Interlocked.Add(ref BytesDone, n);
                }
                if (left != 0) { f.Bad = true; return; }
                f.Full = true;
            } else {
                long span = f.Size - BLOCK;
                for (int i = 0; i < SAMPLES; i++) {
                    fs.Position = span * i / (SAMPLES - 1);
                    int n = ReadFull(fs, w.Buf, BLOCK);
                    if (n != BLOCK) { f.Bad = true; return; }
                    w.H.Update(w.Buf, 0, n);
                    Interlocked.Add(ref BytesDone, n);
                }
            }
            f.H2 = w.H.Final();
        } catch { f.Bad = true; }
        finally { fs.Dispose(); Interlocked.Increment(ref FilesDone); }
    }

    static string VolumeOf(string path) {
        if (path.Length >= 2 && path[1] == ':') return path.Substring(0, 2).ToUpperInvariant();
        return "/";
    }

    public static volatile bool LowPriority;          // 设置里的「查重复文件时让着其他程序」
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
    // 按磁盘分组并行：每块盘各自的线程数；同一块盘内按路径排序，机械硬盘少跳磁头
    static void RunPerVolume(List<DupFile> files, Dictionary<string, int> threads, Action<DupFile, IoWorker> work) {
        Dictionary<string, List<DupFile>> byVol = new Dictionary<string, List<DupFile>>(StringComparer.OrdinalIgnoreCase);
        foreach (DupFile f in files) {
            string v = VolumeOf(f.Path);
            List<DupFile> l;
            if (!byVol.TryGetValue(v, out l)) { l = new List<DupFile>(); byVol[v] = l; }
            l.Add(f);
        }
        List<Thread> all = new List<Thread>();
        foreach (KeyValuePair<string, List<DupFile>> kv in byVol) {
            List<DupFile> lst = kv.Value;
            lst.Sort(delegate (DupFile a, DupFile b) { return string.CompareOrdinal(a.Path, b.Path); });
            ConcurrentQueue<DupFile> q = new ConcurrentQueue<DupFile>(lst);
            int n;
            if (threads == null || !threads.TryGetValue(kv.Key, out n)) n = 2;
            n = Math.Max(1, Math.Min(n, lst.Count));
            for (int i = 0; i < n; i++) {
                Thread t = new Thread(new ThreadStart(delegate () {
                    // 让着其他程序：Windows 的后台模式，磁盘和内存都用低优先级（读过的文件不把别的程序缓存的数据挤出内存）
                    bool bg = false;
                    if (LowPriority && System.IO.Path.DirectorySeparatorChar == '\\') { try { bg = SetThreadPriority(GetCurrentThread(), 0x00010000 /*THREAD_MODE_BACKGROUND_BEGIN*/); } catch { } }
                    try {
                        IoWorker w = new IoWorker();
                        DupFile f;
                        while (!Cancel && q.TryDequeue(out f)) {
                            try { work(f, w); } catch { f.Bad = true; }
                        }
                    } finally { if (bg) { try { SetThreadPriority(GetCurrentThread(), 0x00020000 /*THREAD_MODE_BACKGROUND_END*/); } catch { } } }
                }));
                t.IsBackground = true;
                t.Start();
                all.Add(t);
            }
        }
        foreach (Thread t in all) t.Join();
    }

    static Dictionary<string, int> ParseThreads(string[] spec) {
        Dictionary<string, int> d = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        if (spec == null) return d;
        foreach (string s in spec) {
            int eq = s.IndexOf('=');
            int n;
            if (eq > 0 && int.TryParse(s.Substring(eq + 1), out n)) d[s.Substring(0, eq).Trim()] = n;
        }
        return d;
    }

    // ================= 主流程 =================
    public static List<DupGroup> Find(string[] roots, long minSize, long maxSize, bool matchName, string[] onlyExt, bool exact, string[] driveThreads) {
        FilesSeen = 0; DirsSeen = 0; CandidateFiles = 0; BytesDone = 0; BytesTotal = 0;
        GroupsFound = 0; FilesDone = 0; FilesTotal = 0;
        Phase = "list"; Current = "";
        progDirCache = new ConcurrentDictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, int> threads = ParseThreads(driveThreads);

        // ---- 第 1 步：多线程列举 ----
        EnumJob job = new EnumJob();
        job.MinSize = Math.Max(1, minSize); job.MaxSize = maxSize; job.MatchName = matchName;
        job.Allow = (onlyExt != null && onlyExt.Length > 0) ? MakeSet(onlyExt) : null;
        job.SysRoot = (Environment.GetFolderPath(Environment.SpecialFolder.Windows) ?? "").TrimEnd('\\', '/');
        string probe = null;
        if (roots != null) {
            for (int i = roots.Length - 1; i >= 0; i--) {
                // 根本身是链接（比如本工具搬走后留下的）：它和指向的地方是同一份东西，一起扫会把同一个文件当成两份
                try { if (Directory.Exists(roots[i]) && (File.GetAttributes(roots[i]) & FileAttributes.ReparsePoint) == 0) { job.Push(roots[i]); probe = roots[i]; } } catch { }
            }
        }
        job.Fast = System.IO.Path.DirectorySeparatorChar == '\\' && probe != null && FastEnumWorks(probe);
        UsedFastEnum = job.Fast;
        int nEnum = Math.Max(2, Math.Min(8, Environment.ProcessorCount));
        List<Thread> ets = new List<Thread>();
        for (int i = 0; i < nEnum; i++) {
            Thread t = new Thread(new ThreadStart(job.Run));
            t.IsBackground = true; t.Start(); ets.Add(t);
        }
        foreach (Thread t in ets) t.Join();
        if (Cancel) return new List<DupGroup>();

        Dictionary<string, List<DupFile>> buckets = new Dictionary<string, List<DupFile>>();
        foreach (Dictionary<string, List<DupFile>> part in job.Results) {
            foreach (KeyValuePair<string, List<DupFile>> kv in part) {
                List<DupFile> l;
                if (!buckets.TryGetValue(kv.Key, out l)) buckets[kv.Key] = kv.Value;
                else l.AddRange(kv.Value);
            }
        }

        // ---- 第 2 步：头尾指纹 ----
        List<DupFile> cands = new List<DupFile>();
        long quickBytes = 0;
        foreach (KeyValuePair<string, List<DupFile>> kv in buckets) {
            if (kv.Value.Count < 2) continue;
            foreach (DupFile f in kv.Value) { cands.Add(f); quickBytes += Math.Min(f.Size, 2L * BLOCK); }
        }
        buckets = null;
        CandidateFiles = cands.Count;
        BytesDone = 0; BytesTotal = quickBytes; FilesDone = 0; FilesTotal = cands.Count;
        Phase = "quick";
        RunPerVolume(cands, threads, HashHeadTail);
        if (Cancel) return new List<DupGroup>();

        Dictionary<string, List<DupFile>> b2 = GroupBy(cands, false);
        cands = null;

        // ---- 第 3 步：深度指纹 ----
        List<DupFile> deep = new List<DupFile>();
        long deepBytes = 0;
        foreach (List<DupFile> l in b2.Values) {
            if (l.Count < 2) continue;
            foreach (DupFile f in l) {
                if (f.Full) { f.H2 = f.H1; continue; }
                deep.Add(f);
                deepBytes += (exact || f.Size <= FULL_LIMIT) ? f.Size : (long)SAMPLES * BLOCK;
            }
        }
        BytesDone = 0; BytesTotal = deepBytes; FilesDone = 0; FilesTotal = deep.Count;
        Phase = "deep";
        RunPerVolume(deep, threads, delegate (DupFile f, IoWorker w) { HashDeep(f, w, exact); });
        if (Cancel) return new List<DupGroup>();

        List<DupFile> survivors = new List<DupFile>();
        foreach (List<DupFile> l in b2.Values) if (l.Count >= 2) survivors.AddRange(l);
        Dictionary<string, List<DupFile>> b3 = GroupBy(survivors, true);

        // ---- 收尾：成组、标注风险、排序 ----
        Phase = "finish";
        List<DupGroup> result = new List<DupGroup>();
        foreach (List<DupFile> l in b3.Values) {
            if (l.Count < 2) continue;
            DupGroup g = new DupGroup();
            g.Name = System.IO.Path.GetFileName(l[0].Path);
            g.Size = l[0].Size;
            g.Files = l;
            g.Verified = true;
            foreach (DupFile f in l) { if (!f.Full) g.Verified = false; f.Risk = RiskOf(f.Path); }
            l.Sort(delegate (DupFile x, DupFile y) { return y.Modified.CompareTo(x.Modified); });
            result.Add(g);
        }
        GroupsFound = result.Count;
        result.Sort(delegate (DupGroup x, DupGroup y) { return y.Waste.CompareTo(x.Waste); });
        Phase = "done";
        return result;
    }

    static Dictionary<string, List<DupFile>> GroupBy(List<DupFile> files, bool useH2) {
        Dictionary<string, List<DupFile>> d = new Dictionary<string, List<DupFile>>();
        foreach (DupFile f in files) {
            if (f.Bad) continue;
            string k = f.Key + "|" + f.H1.ToString("x16") + (useH2 ? "|" + f.H2.ToString("x16") : "");
            List<DupFile> l;
            if (!d.TryGetValue(k, out l)) { l = new List<DupFile>(2); d[k] = l; }
            l.Add(f);
        }
        return d;
    }

    // 删除前的最终核对：两个文件逐字节完全相同才返回 true（按 8 字节一组比较）
    public static bool SameContent(string a, string b) {
        FileStream fa = Open(a, true), fb = Open(b, true);
        try {
            if (fa == null || fb == null) return false;
            if (fa.Length != fb.Length) return false;
            VerifyTotal = fa.Length; VerifyDone = 0;
            byte[] ba = new byte[1 << 20], bb = new byte[1 << 20];
            ulong[] la = new ulong[1 << 17], lb = new ulong[1 << 17];
            while (true) {
                if (Cancel) return false;
                int na = ReadFull(fa, ba, ba.Length);
                int nb = ReadFull(fb, bb, bb.Length);
                if (na != nb) return false;
                if (na == 0) return true;
                int words = na / 8;
                Buffer.BlockCopy(ba, 0, la, 0, words * 8);
                Buffer.BlockCopy(bb, 0, lb, 0, words * 8);
                for (int i = 0; i < words; i++) if (la[i] != lb[i]) return false;
                for (int i = words * 8; i < na; i++) if (ba[i] != bb[i]) return false;
                VerifyDone += na;
            }
        } catch { return false; }
        finally { if (fa != null) fa.Dispose(); if (fb != null) fb.Dispose(); }
    }

    static ConcurrentDictionary<string, bool> progDirCache = new ConcurrentDictionary<string, bool>(StringComparer.OrdinalIgnoreCase);

    public static string RiskOf(string path) {
        string lower = path.ToLowerInvariant().Replace('/', '\\');
        if (lower.Contains("xwechat_files") || lower.Contains("wechat files") || lower.Contains("tencent files") ||
            lower.Contains("\\tencent\\") || lower.Contains("tencentdata") || lower.Contains("_tencent"))
            return L10n.T("微信/QQ 的数据，删掉后对应聊天里这个文件会打不开");
        string dir;
        try { dir = System.IO.Path.GetDirectoryName(path); } catch { return ""; }
        if (string.IsNullOrEmpty(dir)) return "";
        bool prog;
        if (!progDirCache.TryGetValue(dir, out prog)) {
            // 同一文件夹里既有 .exe 又有 .dll，或者有 3 个以上 .dll，就当作程序目录
            prog = false;
            try {
                int dlls = 0; bool exe = false;
                foreach (string x in Directory.EnumerateFiles(dir, "*.dll")) { dlls++; if (dlls >= 3) break; }
                if (dlls > 0 && dlls < 3) { foreach (string x in Directory.EnumerateFiles(dir, "*.exe")) { exe = true; break; } }
                prog = dlls >= 3 || (dlls > 0 && exe);
            } catch { }
            progDirCache[dir] = prog;
        }
        if (prog) return L10n.T("所在文件夹像是程序目录（里面有 .dll），删掉后这里的程序可能打不开");
        return "";
    }
}

