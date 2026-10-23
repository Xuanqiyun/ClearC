// ==================== 直接读 NTFS 的文件表（MFT） ====================
// NTFS 把每个文件的名字、所在文件夹、大小都记在 MFT 里。按顺序把它整块读出来，比一个文件夹一个文件夹地问系统快得多。
// 只读：以只读方式打开整个分区，不写任何东西。读不了（不是 NTFS、结构不认识、和直接列目录核对不上）就退回逐个文件夹扫描。
// 统计口径和逐个文件夹扫描一样：硬链接每个名字算一次，链接目录（搬家留下的、挂载点）不往里算，备用数据流不算。
public interface IVolume {
    int SectorSize { get; set; }
    int Read(long offset, byte[] buffer, int count);   // offset、count 都要是扇区大小的整数倍
    void Close();
}
public sealed class FileVolume : IVolume {           // 测试用：读一个磁盘镜像文件
    readonly FileStream fs;
    public int SectorSize { get; set; }
    public FileVolume(string path) { fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); SectorSize = 512; }
    public int Read(long offset, byte[] buffer, int count) {
        fs.Seek(offset, SeekOrigin.Begin);
        int total = 0;
        while (total < count) { int n = fs.Read(buffer, total, count - total); if (n <= 0) break; total += n; }
        return total;
    }
    public void Close() { fs.Dispose(); }
}
public sealed class WinVolume : IVolume {             // Windows：\\.\C:
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(IntPtr h, long dist, out long newPos, uint method);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, IntPtr buffer, int toRead, out int read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);
    IntPtr nbuf = IntPtr.Zero; int nlen;          // 按页对齐的读盘缓冲区：有的磁盘要求缓冲区对齐
    byte[] recOut;
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    public IntPtr Handle;
    public int SectorSize { get; set; }
    public WinVolume(string root) {
        string v = "\\\\.\\" + root.Substring(0, 2);
        Handle = CreateFileW(v, 0x80000000 /*GENERIC_READ*/, 3 /*SHARE_READ|WRITE*/, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0, IntPtr.Zero);
        if (Handle == new IntPtr(-1)) throw new IOException("open volume: " + Marshal.GetLastWin32Error());
        SectorSize = 512;
    }
    public int Read(long offset, byte[] buffer, int count) {
        if (count > nlen) {
            if (nbuf != IntPtr.Zero) { VirtualFree(nbuf, UIntPtr.Zero, 0x8000 /*MEM_RELEASE*/); nbuf = IntPtr.Zero; nlen = 0; }
            int want = (count + 0xFFFF) & ~0xFFFF;
            nbuf = VirtualAlloc(IntPtr.Zero, (UIntPtr)(uint)want, 0x3000 /*COMMIT|RESERVE*/, 0x04 /*READWRITE*/);
            if (nbuf == IntPtr.Zero) throw new IOException("alloc: " + Marshal.GetLastWin32Error());
            nlen = want;
        }
        long np;
        if (!SetFilePointerEx(Handle, offset, out np, 0)) throw new IOException("seek: " + Marshal.GetLastWin32Error());
        int got;
        if (!ReadFile(Handle, nbuf, count, out got, IntPtr.Zero)) throw new IOException("read: " + Marshal.GetLastWin32Error());
        if (got > 0) Marshal.Copy(nbuf, buffer, 0, got);
        return got;
    }
    // 经文件系统读一条记录（走缓存，刚改过的也是新的）。1 读到了  0 这条记录现在没在用  -1 读不了
    public int GetRecord(long frn, byte[] rec, int rs) {
        if (recOut == null || recOut.Length < rs + 16) recOut = new byte[rs + 16];
        int got, err;
        if (!Ioctl(0x00090068 /*FSCTL_GET_NTFS_FILE_RECORD*/, BitConverter.GetBytes(frn), recOut, out got, out err)) return -1;
        if (got < 12) return -1;
        // 要的那条没在用时，返回的是它前面最近一条在用的
        if ((BitConverter.ToInt64(recOut, 0) & 0xFFFFFFFFFFFF) != frn) return 0;
        if (BitConverter.ToInt32(recOut, 8) != rs || got < 12 + rs) return -1;
        Buffer.BlockCopy(recOut, 12, rec, 0, rs);
        return 1;
    }
    public bool Ioctl(uint code, byte[] inBuf, byte[] outBuf, out int returned, out int err) {
        bool ok = DeviceIoControl(Handle, code, inBuf, inBuf == null ? 0 : inBuf.Length, outBuf, outBuf.Length, out returned, IntPtr.Zero);
        err = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }
    public void Close() {
        if (Handle != new IntPtr(-1)) { CloseHandle(Handle); Handle = new IntPtr(-1); }
        if (nbuf != IntPtr.Zero) { VirtualFree(nbuf, UIntPtr.Zero, 0x8000); nbuf = IntPtr.Zero; nlen = 0; }
    }
}

public struct MftLink { public int Parent; public ushort ParentSeq; public string Name; }

// 读出来的文件表：每个记录号一格
// 文件按扩展名分成几类，扫描时顺手统计每类有多少个、多大。0 其他 1 视频 2 图片 3 音乐 4 文档 5 压缩包和安装包 6 镜像和虚拟磁盘 7 程序 8 日志和临时文件 9 代码和开发
public static class FileCats {
    public const int N = 10;
    public static readonly string[] Keys = { "other", "video", "picture", "music", "doc", "archive", "image", "program", "log", "code" };
    static readonly Dictionary<long, byte> map = new Dictionary<long, byte>();
    static FileCats() {
        Add(1, "mp4 mkv avi mov wmv flv m4v ts m2ts webm mpg mpeg rmvb rm 3gp vob");
        Add(2, "jpg jpeg png gif bmp tif tiff heic webp raw cr2 cr3 nef arw dng psd svg ico");
        Add(3, "mp3 flac wav aac m4a ogg wma ape opus");
        Add(4, "pdf doc docx xls xlsx ppt pptx txt md epub mobi csv wps et dps rtf odt ods odp one");
        Add(5, "zip rar 7z tar gz tgz bz2 xz zst cab msi msp msix msixbundle appx appxbundle apk dmg");
        Add(6, "iso img vhd vhdx avhdx vmdk vdi qcow2 wim esd gho");
        Add(7, "exe dll sys ocx pak bin vpk pck assets bundle resource uasset upk");
        Add(8, "log etl dmp mdmp hdmp tmp temp bak old cache chk");
        Add(9, "cs js ts tsx jsx py java h hpp c cpp cc go rs rb php json xml yml yaml map obj pdb lib o class pyc ipynb sql ps1 psm1 sh bat cmd swift kt scala lock toml");
    }
    static void Add(byte cat, string exts) { foreach (string x in exts.Split(' ')) { long k = Key(x); if (k >= 0) map[k] = cat; } }
    // 最多 10 个字符的小写扩展名装进一个 long（每个字符 6 位：字母、数字和少数符号）
    static int Code(int c) {
        if (c >= 'A' && c <= 'Z') c += 32;
        if (c >= 'a' && c <= 'z') return c - 'a' + 1;
        if (c >= '0' && c <= '9') return c - '0' + 27;
        if (c == '-') return 37; if (c == '_') return 38; if (c == '~') return 39; if (c == '+') return 40;
        return -1;
    }
    public static long Key(string ext) {
        if (ext.Length == 0 || ext.Length > 10) return -1;
        long k = 0;
        for (int i = 0; i < ext.Length; i++) { int c = Code(ext[i]); if (c < 0) return -1; k = (k << 6) | (uint)c; }
        return k;
    }
    public static byte OfName(string name) {
        if (string.IsNullOrEmpty(name)) return 0;
        int dot = name.LastIndexOf('.');
        if (dot < 0 || dot == name.Length - 1 || dot == 0) return 0;
        byte c; return map.TryGetValue(Key(name.Substring(dot + 1)), out c) ? c : (byte)0;
    }
    // UTF-16LE 的名字（文件表里的样子）
    public static byte Of(byte[] b, int off, int len) {
        int chars = len / 2, dot = -1;
        for (int i = chars - 1; i >= 0; i--) { int o = off + i * 2; if (b[o] == '.' && b[o + 1] == 0) { dot = i; break; } }
        if (dot <= 0 || dot == chars - 1 || chars - 1 - dot > 10) return 0;
        long k = 0;
        for (int i = dot + 1; i < chars; i++) {
            int o = off + i * 2; if (b[o + 1] != 0) return 0;
            int c = Code(b[o]); if (c < 0) return 0;
            k = (k << 6) | (uint)c;
        }
        byte cat; return map.TryGetValue(k, out cat) ? cat : (byte)0;
    }
}
public sealed class MftIndex {
    public string Root;
    public int RecordSize, SectorSize; public long ClusterSize;
    public List<long[]> Runs = new List<long[]>();   // MFT 在盘上的各段：{ 盘上的字节位置, 字节数 }
    public long MftBytes;
    public int Count;
    public int[] Parent; public ushort[] ParentSeq, Seq;
    public long[] Size, Write;
    public long[] Disk;                               // 这条记录里的数据实际占的盘（主记录和续页各记各的；压缩、稀疏、只在云端的文件比文件大小小，很小的文件放在记录里不另占）
    public byte[] Flag;                               // 1 在用  2 文件夹  4 链接（重解析点）  8 有属性列表  16 别的重解析点  32 系统压缩或重复数据删除（对程序就是普通文件）
    public uint[] Attr;                               // $STANDARD_INFORMATION 里的文件属性（系统、脱机、云端占位、重解析点……），查重复文件时按它跳过
    public byte[] Cat;                                // 文件类别（FileCats）
    public string[] Name;                             // 只存文件夹、1 MB 以上的文件和有属性列表的文件的名字
    public Dictionary<int, List<MftLink>> Extra = new Dictionary<int, List<MftLink>>();   // 第二个起的名字（硬链接）
    public long Bad;                                  // 校验不过的记录
    public List<int> BadList = new List<int>();       // 校验不过的在用记录：读完后再试一次
    public HashSet<int> OpenFiles = new HashSet<int>();   // 变更日志里还没「关闭」的文件：开着的文件后面再改不会有新记录，每次都重读
    public bool Partial;                              // 中途停下了
    public ulong JournalId; public long NextUsn; public bool HasJournal;
    public DateTime At;
    public void Alloc(int n) {
        Count = n;
        Parent = new int[n]; ParentSeq = new ushort[n]; Seq = new ushort[n];
        Size = new long[n]; Write = new long[n]; Disk = new long[n]; Flag = new byte[n]; Name = new string[n]; Cat = new byte[n]; Attr = new uint[n];
        for (int i = 0; i < n; i++) Parent[i] = -1;
    }
    public void Grow(int n) {
        if (n <= Count) return;
        int old = Count;
        Array.Resize(ref Parent, n); Array.Resize(ref ParentSeq, n); Array.Resize(ref Seq, n);
        Array.Resize(ref Size, n); Array.Resize(ref Write, n); Array.Resize(ref Disk, n); Array.Resize(ref Flag, n); Array.Resize(ref Name, n); Array.Resize(ref Cat, n); Array.Resize(ref Attr, n);
        for (int i = old; i < n; i++) Parent[i] = -1;
        Count = n;
    }
    public void Clear(int frn) {
        Parent[frn] = -1; ParentSeq[frn] = 0; Seq[frn] = 0; Size[frn] = 0; Write[frn] = 0; Disk[frn] = 0; Flag[frn] = 0; Name[frn] = null; Cat[frn] = 0; Attr[frn] = 0;
        Extra.Remove(frn); ExtOf.Remove(frn);
    }
    public Dictionary<int, List<int>> ExtOf = new Dictionary<int, List<int>>();   // 主记录 → 读到过的续页
    public Dictionary<int, ushort> ExtClaim = new Dictionary<int, ushort>();    // 续页 → 它记着的主记录序号
    public HashSet<int> Failed = new HashSet<int>();                            // 上次没重读成的记录：下次接着读
    public IVolume Vol;                                                         // 读放在盘上别处的重解析数据用
    public Dictionary<int, long> Recent = new Dictionary<int, long>();          // 属性列表是从盘上读的（可能还没写进最新的）：两分钟内每次都重读
}

public static class Mft {
    public static long BigMin = 1L * 1024 * 1024;
    public static long RecordsDone, RecordsTotal;     // 进度

    static ushort U16(byte[] b, int o) { return (ushort)(b[o] | (b[o + 1] << 8)); }
    static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static long I64(byte[] b, int o) { return BitConverter.ToInt64(b, o); }
    static ulong U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }

    // 读任意一段（自动按扇区对齐）
    static void ReadAt(IVolume v, long off, byte[] dst, int dstOff, int count) {
        int ss = v.SectorSize;
        long a = off / ss * ss;
        int pre = (int)(off - a);
        int len = (pre + count + ss - 1) / ss * ss;
        byte[] tmp = new byte[len];
        int got = v.Read(a, tmp, len);
        if (got < pre + count) throw new IOException("short read");
        Buffer.BlockCopy(tmp, pre, dst, dstOff, count);
    }

    // 每个扇区末尾两个字节在写盘时换成了校验号，读出来要换回去；对不上说明这条记录坏了
    public static bool Fixup(byte[] b, int off, int size) {
        int usaOfs = U16(b, off + 4), usaCnt = U16(b, off + 6);
        if (usaCnt != size / 512 + 1 || usaOfs < 0x28 || usaOfs + usaCnt * 2 > size) return false;
        int usn0 = off + usaOfs;
        for (int i = 1; i < usaCnt; i++) {
            int p = off + i * 512 - 2;
            if (b[p] != b[usn0] || b[p + 1] != b[usn0 + 1]) return false;
            b[p] = b[usn0 + 2 * i]; b[p + 1] = b[usn0 + 2 * i + 1];
        }
        return true;
    }

    // 非常驻属性的数据在盘上的位置：{ 盘上字节位置, 字节数 }
    static List<long[]> DecodeRuns(byte[] b, int off, int end, long cluster) {
        List<long[]> runs = new List<long[]>();
        long lcn = 0;
        while (off < end) {
            int h = b[off++];
            if (h == 0) break;
            int lb = h & 0xF, ob = h >> 4;
            if (lb == 0 || lb > 8 || ob > 8 || off + lb + ob > end) throw new InvalidDataException("runlist");
            long len = 0;
            for (int i = 0; i < lb; i++) len |= (long)b[off + i] << (8 * i);
            off += lb;
            if (ob == 0) throw new InvalidDataException("sparse run");
            long delta = 0;
            for (int i = 0; i < ob; i++) delta |= (long)b[off + i] << (8 * i);
            if (ob < 8 && (b[off + ob - 1] & 0x80) != 0) delta |= -1L << (8 * ob);
            off += ob;
            lcn += delta;
            if (lcn < 0 || len <= 0) throw new InvalidDataException("runlist value");
            runs.Add(new long[] { lcn * cluster, len * cluster });
        }
        return runs;
    }

    // 引导扇区 + 第 0 条记录（$MFT 自己）：算出记录大小、MFT 在盘上的各段、一共有多少条记录
    public static MftIndex Open(IVolume v, string root) {
        byte[] boot = new byte[4096];
        if (v.Read(0, boot, 4096) < 512) throw new IOException("boot");
        if (Encoding.ASCII.GetString(boot, 3, 8) != "NTFS    ") throw new InvalidDataException("not NTFS");
        int bps = U16(boot, 0x0B);
        int spc = boot[0x0D]; if (spc > 0x80) spc = 1 << (256 - spc);
        if (bps != 512 && bps != 1024 && bps != 2048 && bps != 4096) throw new InvalidDataException("sector size");
        long cluster = (long)bps * spc;
        if (cluster <= 0 || cluster > 2 * 1024 * 1024 || (cluster & (cluster - 1)) != 0) throw new InvalidDataException("cluster size");
        long mftLcn = I64(boot, 0x30);
        int cpr = (sbyte)boot[0x40];
        int rs = cpr > 0 ? (int)(cpr * cluster) : (1 << (-cpr));
        if (rs != 1024 && rs != 2048 && rs != 4096) throw new InvalidDataException("record size");
        v.SectorSize = bps;
        MftIndex ix = new MftIndex();
        ix.Root = root; ix.RecordSize = rs; ix.SectorSize = bps; ix.ClusterSize = cluster;
        byte[] r0 = new byte[rs];
        // Windows 上经文件系统读 $MFT 自己的记录（刚变长、还没写到盘上时也是新的）；读不了再直接读盘
        WinVolume wv0 = v as WinVolume;
        if (wv0 == null || FreshRecord(wv0, 0, r0, rs) != 1) {
            ReadAt(v, mftLcn * cluster, r0, 0, rs);
            if (U32(r0, 0) != 0x454C4946 || !Fixup(r0, 0, rs)) throw new InvalidDataException("$MFT record");
        }
        long dataSize = -1;
        List<KeyValuePair<long, List<long[]>>> segs = new List<KeyValuePair<long, List<long[]>>>();
        byte[] attrList = null;
        ScanMftRecordForData(r0, rs, cluster, segs, ref dataSize, ref attrList, v);
        if (dataSize < 0 || segs.Count == 0) throw new InvalidDataException("$MFT data");
        ix.Runs = segs[0].Value;
        // $MFT 本身很碎时，后面几段记在别的记录里（属性列表指过去）
        if (attrList != null) {
            ix.MftBytes = Sum(ix.Runs);
            HashSet<int> seenSeg = new HashSet<int>();
            for (int o = 0; o + 26 <= attrList.Length; ) {
                uint type = U32(attrList, o); int el = U16(attrList, o + 4);
                if (el < 26 || o + el > attrList.Length) break;
                int nl = attrList[o + 6];
                long vcn = I64(attrList, o + 8);
                int seg = (int)(U64(attrList, o + 16) & 0xFFFFFFFFFFFF);
                if (type == 0x80 && nl == 0 && seg != 0 && vcn > 0 && seenSeg.Add(seg)) {   // 一条续页里可能有好几段，只读一次
                    byte[] rec = new byte[rs];
                    if (wv0 == null || FreshRecord(wv0, seg, rec, rs) != 1) {
                        ReadVirtual(v, ix, (long)seg * rs, rec, rs);
                        if (U32(rec, 0) != 0x454C4946 || !Fixup(rec, 0, rs)) throw new InvalidDataException("$MFT extension");
                    }
                    long ds = -1; byte[] al2 = null;
                    List<KeyValuePair<long, List<long[]>>> s2 = new List<KeyValuePair<long, List<long[]>>>();
                    ScanMftRecordForData(rec, rs, cluster, s2, ref ds, ref al2, v);
                    foreach (KeyValuePair<long, List<long[]>> kv in s2) segs.Add(kv);
                }
                o += el;
            }
            segs.Sort((a, b) => a.Key.CompareTo(b.Key));
            ix.Runs = new List<long[]>();
            long expect = 0;                                // 各段要首尾相接，否则后面的记录号全对不上
            foreach (KeyValuePair<long, List<long[]>> kv in segs) {
                if (kv.Key != expect) throw new InvalidDataException("$MFT extents");
                foreach (long[] r in kv.Value) expect += r[1] / cluster;
                ix.Runs.AddRange(kv.Value);
            }
        }
        long runBytes = Sum(ix.Runs);
        ix.MftBytes = Math.Min(dataSize, runBytes);
        long n = ix.MftBytes / rs;
        if (n <= 16 || n > int.MaxValue) throw new InvalidDataException("record count");
        ix.Count = (int)n;
        return ix;
    }
    static long Sum(List<long[]> runs) { long s = 0; foreach (long[] r in runs) s += r[1]; return s; }

    static void ScanMftRecordForData(byte[] r, int rs, long cluster, List<KeyValuePair<long, List<long[]>>> segs, ref long dataSize, ref byte[] attrList, IVolume v) {
        int a = U16(r, 0x14), end = Math.Min(rs, (int)U32(r, 0x18));
        while (a + 16 <= end) {
            uint type = U32(r, a);
            if (type == 0xFFFFFFFF) break;
            int len = (int)U32(r, a + 4);
            if (len < 16 || a + len > end) break;
            bool nonRes = r[a + 8] != 0; int nameLen = r[a + 9];
            if (type == 0x80 && nameLen == 0 && nonRes) {
                long vcn = I64(r, a + 0x10);
                int ro = U16(r, a + 0x20);
                if (vcn == 0) dataSize = Math.Min(I64(r, a + 0x30), I64(r, a + 0x38));
                segs.Add(new KeyValuePair<long, List<long[]>>(vcn, DecodeRuns(r, a + ro, a + len, cluster)));
            } else if (type == 0x20) {
                if (!nonRes) { int c = a + U16(r, a + 0x14); int cl = (int)U32(r, a + 0x10); attrList = new byte[cl]; Buffer.BlockCopy(r, c, attrList, 0, cl); }
                else {
                    long sz = I64(r, a + 0x30);
                    List<long[]> runs = DecodeRuns(r, a + U16(r, a + 0x20), a + len, cluster);
                    byte[] buf = new byte[sz]; long got = 0;
                    foreach (long[] run in runs) { if (got >= sz) break; int take = (int)Math.Min(run[1], sz - got); ReadAt(v, run[0], buf, (int)got, take); got += take; }
                    attrList = buf;
                }
            }
            a += len;
        }
    }

    // 按 MFT 里的位置读（跨过它在盘上的各段）
    static void ReadVirtual(IVolume v, MftIndex ix, long vpos, byte[] dst, int count) {
        int done = 0; long cur = 0;
        foreach (long[] run in ix.Runs) {
            if (done >= count) break;
            long runEnd = cur + run[1];
            if (vpos + done < runEnd) {
                long inRun = vpos + done - cur;
                int take = (int)Math.Min(run[1] - inRun, count - done);
                ReadAt(v, run[0] + inRun, dst, done, take);
                done += take;
            }
            cur = runEnd;
        }
        if (done < count) throw new InvalidDataException("beyond MFT");
    }

    // 把整个 MFT 按顺序读一遍
    public static void ReadAll(IVolume v, MftIndex ix, Func<bool> cancelled) {
        ix.Alloc(ix.Count); ix.Vol = v;
        int rs = ix.RecordSize;
        int ss = v.SectorSize;
        int chunk = (int)Math.Max(ix.ClusterSize, rs);
        chunk = (4 * 1024 * 1024 / chunk) * chunk;
        byte[] buf = new byte[chunk + (int)Math.Max(ix.ClusterSize, ss)];
        RecordsTotal = ix.Count; RecordsDone = 0;
        long vdone = 0; int frn = 0;
        byte[] carry = new byte[rs]; int carryLen = 0;
        foreach (long[] run in ix.Runs) {
            long pos = 0;
            while (pos < run[1] && vdone < ix.MftBytes) {
                if (cancelled != null && cancelled()) { ix.Partial = true; return; }
                long want = Math.Min(Math.Min((long)chunk, run[1] - pos), ix.MftBytes - vdone);
                int rd = (int)((want + ss - 1) / ss * ss);
                if (rd > run[1] - pos) rd = (int)(run[1] - pos);
                int got = v.Read(run[0] + pos, buf, rd);
                if (got < want) throw new IOException("short read");
                int n = (int)want, k = 0;
                if (carryLen > 0) {                         // 上一段末尾剩下半条记录
                    int need = rs - carryLen;
                    if (need > n) { Buffer.BlockCopy(buf, 0, carry, carryLen, n); carryLen += n; k = n; }
                    else {
                        Buffer.BlockCopy(buf, 0, carry, carryLen, need);
                        Parse(ix, carry, 0, frn++); carryLen = 0; k = need;
                    }
                }
                for (; k + rs <= n; k += rs) Parse(ix, buf, k, frn++);
                if (k < n) { Buffer.BlockCopy(buf, k, carry, 0, n - k); carryLen = n - k; }
                pos += want; vdone += want;
                RecordsDone = frn;
                if (frn >= ix.Count) return;
            }
        }
    }

    [ThreadStatic] static int[] nmOff, nmLen; [ThreadStatic] static ulong[] nmPar;
    // 解析一条记录。扩展记录（文件太碎、硬链接太多时用的续页）里的名字和大小记到它的主记录上
    public static void Parse(MftIndex ix, byte[] b, int off, int frn) {
        int rs = ix.RecordSize;
        if (frn >= ix.Count) return;
        uint sig = U32(b, off);
        if (sig == 0x44414142) { ix.Bad++; if (ix.BadList.Count < 100000) ix.BadList.Add(frn); return; }   // "BAAD"
        if (sig != 0x454C4946) return;                      // "FILE"；不是的话是从没用过的空记录
        if (!Fixup(b, off, rs)) {
            // 读的时候正好在写的记录：在用的才算坏（标志在第一个扇区里，校验不过也读得到），读完再试一次
            if ((U16(b, off + 0x16) & 1) != 0) { ix.Bad++; if (ix.BadList.Count < 100000) ix.BadList.Add(frn); }
            return;
        }
        ParseFixed(ix, b, off, frn);
    }
    static void ParseFixed(MftIndex ix, byte[] b, int off, int frn) {
        int rs = ix.RecordSize;
        int flags = U16(b, off + 0x16);
        ix.Disk[frn] = 0;
        if ((flags & 1) == 0) return;
        ulong baseRef = U64(b, off + 0x20);
        bool ext = (baseRef & 0xFFFFFFFFFFFF) != 0;
        int owner = ext ? (int)(baseRef & 0xFFFFFFFFFFFF) : frn;
        if (owner < 0 || owner >= ix.Count) return;
        // 续页指向的主记录已经换了人（序号对不上）：是过时的续页，不算
        if (ext && (ix.Flag[owner] & 1) != 0 && ix.Seq[owner] != (ushort)(baseRef >> 48)) return;
        if (ext) {
            List<int> el;
            if (!ix.ExtOf.TryGetValue(owner, out el)) { el = new List<int>(2); ix.ExtOf[owner] = el; }
            if (!el.Contains(frn)) el.Add(frn);
            ix.ExtClaim[frn] = (ushort)(baseRef >> 48);
        }
        if (!ext) {
            ix.Seq[frn] = U16(b, off + 0x10);
            ix.Flag[frn] |= 1;
            if ((flags & 2) != 0) ix.Flag[frn] |= 2;
        }
        int a = off + U16(b, off + 0x14);
        int end = off + Math.Min(rs, (int)U32(b, off + 0x18));
        int nNames = 0;
        if (nmOff == null) { nmOff = new int[8]; nmLen = new int[8]; nmPar = new ulong[8]; }
        long size = 0, disk = 0; bool hasData = false;
        while (a + 16 <= end) {
            uint type = U32(b, a);
            if (type == 0xFFFFFFFF) break;
            int len = (int)U32(b, a + 4);
            if (len < 16 || a + len > end) { ix.Bad++; break; }
            bool nonRes = b[a + 8] != 0;
            int attrNameLen = b[a + 9];
            if (type == 0x10 && !nonRes && !ext) {
                int c = a + U16(b, a + 0x14);
                if (c + 0x24 <= a + len) { ix.Write[frn] = I64(b, c + 8); ix.Attr[frn] = U32(b, c + 0x20); }
            } else if (type == 0x20) {
                ix.Flag[owner] |= 8;
            } else if (type == 0x30 && !nonRes) {
                int c = a + U16(b, a + 0x14); int cl = (int)U32(b, a + 0x10);
                if (cl >= 0x42 && c + cl <= a + len) {
                    int nl = b[c + 0x40], ns = b[c + 0x41];
                    if (ns != 2 && c + 0x42 + nl * 2 <= a + len) {
                        if (nNames == nmOff.Length) { Array.Resize(ref nmOff, nNames * 2); Array.Resize(ref nmLen, nNames * 2); Array.Resize(ref nmPar, nNames * 2); }
                        nmOff[nNames] = c + 0x42; nmLen[nNames] = nl * 2; nmPar[nNames] = U64(b, c); nNames++;
                    }
                }
            } else if (type == 0x80) {
                if (attrNameLen == 0) {
                    if (nonRes) { if (len >= 0x40 && I64(b, a + 0x10) == 0) { size = I64(b, a + 0x30); hasData = true; } }
                    else { size = U32(b, a + 0x10); hasData = true; }
                }
                disk += AttrDisk(b, a, len, attrNameLen, nonRes);
            } else if (type == 0xC0) {
                // 只有目录联接、符号链接这类「代替名字」的重解析点才是链接；OneDrive 等云端文件夹也带重解析点，但里面的东西在这块盘上，要算
                uint tag = 0; bool known = false;
                if (!nonRes) { int c = a + U16(b, a + 0x14); if (c + 4 <= a + len) { tag = U32(b, c); known = true; } }
                // 数据太长放在盘上别处（很长的链接目标、云端文件夹的数据）：只有文件夹才去盘上读它的类型，文件用不着（读多了很慢）
                else if ((ext ? (ix.Flag[owner] & 2) : (flags & 2)) != 0) known = ReparseTag(ix, b, a, len, out tag);
                if (known && (tag & 0x20000000) != 0) ix.Flag[owner] |= 4; else ix.Flag[owner] |= 16;
                // 系统压缩（WOF）、重复数据删除（Dedup）的文件对程序来说就是普通文件（列举时看不到重解析点）：记下来，查重复文件时和逐个列举一样对待
                if (known && (tag == 0x80000017 || tag == 0x80000013)) ix.Flag[owner] |= 32;
            }
            a += len;
        }
        if (hasData) ix.Size[owner] = size;
        ix.Disk[frn] = disk;
        bool keep = ext || (ix.Flag[owner] & (2 | 8)) != 0 || ix.Size[owner] >= BigMin;
        if (nNames > 0 && (ix.Flag[owner] & 2) == 0 && ix.Parent[owner] < 0) ix.Cat[owner] = FileCats.Of(b, nmOff[0], nmLen[0]);
        for (int i = 0; i < nNames; i++) {
            string nm = keep ? Encoding.Unicode.GetString(b, nmOff[i], nmLen[i]) : null;
            int p = (int)(nmPar[i] & 0xFFFFFFFFFFFF); ushort ps = (ushort)(nmPar[i] >> 48);
            if (ix.Parent[owner] < 0) { ix.Parent[owner] = p; ix.ParentSeq[owner] = ps; ix.Name[owner] = nm; }
            else {
                List<MftLink> l;
                if (!ix.Extra.TryGetValue(owner, out l)) { l = new List<MftLink>(1); ix.Extra[owner] = l; }
                MftLink k = new MftLink(); k.Parent = p; k.ParentSeq = ps; k.Name = nm; l.Add(k);
            }
        }
    }

    // 一个数据属性实际占的盘：没有名字的数据流，加上系统压缩（CompactOS）放压缩后数据的 WofCompressedData 流。
    // 大小只记在第一段（起始 VCN 为 0）里；压缩或稀疏的按真正分配了的簇算，其他按分配的大小算；放在记录里的（很小的文件）不另占
    static long AttrDisk(byte[] b, int a, int len, int attrNameLen, bool nonRes) {
        if (!nonRes || len < 0x40 || I64(b, a + 0x10) != 0 || (attrNameLen != 0 && !IsWof(b, a, attrNameLen, len))) return 0;
        int af = U16(b, a + 0x0C);
        long d = ((af & 0x8001) != 0 && len >= 0x48) ? I64(b, a + 0x40) : I64(b, a + 0x28);
        return d > 0 ? d : 0;
    }
    // 一条记录里所有数据属性实际占的盘（只看这一条记录，不动别的）
    static long RecordDisk(byte[] b, int off, int rs) {
        long disk = 0;
        int a = off + U16(b, off + 0x14), end = off + Math.Min(rs, (int)U32(b, off + 0x18));
        while (a + 16 <= end) {
            uint type = U32(b, a);
            if (type == 0xFFFFFFFF) break;
            int len = (int)U32(b, a + 4);
            if (len < 16 || a + len > end) break;
            if (type == 0x80) disk += AttrDisk(b, a, len, b[a + 9], b[a + 8] != 0);
            a += len;
        }
        return disk;
    }
    static readonly string Wof = "WofCompressedData";
    static bool IsWof(byte[] b, int a, int nl, int len) {
        if (nl != Wof.Length) return false;
        int o = a + U16(b, a + 0x0A);
        if (o + nl * 2 > a + len) return false;
        for (int i = 0; i < nl; i++) if (U16(b, o + i * 2) != Wof[i]) return false;
        return true;
    }

    static bool ReparseTag(MftIndex ix, byte[] b, int a, int len, out uint tag) {
        tag = 0;
        if (ix.Vol == null || len < 0x40) return false;
        try {
            List<long[]> runs = DecodeRuns(b, a + U16(b, a + 0x20), a + len, ix.ClusterSize);
            if (runs.Count == 0) return false;
            byte[] t = new byte[4];
            ReadAt(ix.Vol, runs[0][0], t, 0, 4);
            tag = U32(t, 0); return true;
        } catch { return false; }
    }

    // 重新读几条记录（变更日志里列出的），用来在上次读的基础上更新
    // Windows 上经文件系统读（FSCTL_GET_NTFS_FILE_RECORD，走缓存）：直接读盘的话，刚改过的记录可能还没写到盘上。
    // 文件太碎、硬链接太多时有续页：属性列表在主记录里的，续页一起重读。返回 false：有读不了、校验不过的，要整份重读
    // 每条记录要么整条（主记录加全部续页）都读好再换上，要么不动、留到下次再读。返回 false：要整份重读
    public static bool Reread(IVolume v, MftIndex ix, ICollection<int> frns) {
        int rs = ix.RecordSize;
        byte[] rec = new byte[rs];
        WinVolume wv = v as WinVolume;
        ix.Vol = v;
        List<int> all = new List<int>(frns);
        foreach (int f in ix.Failed) if (!frns.Contains(f)) all.Add(f);
        foreach (int f in all) {
            if (f < 16) continue;
            if (f >= ix.Count) return false;
            bool ok = false;
            try { ok = RereadOne(v, wv, ix, f, rec); } catch { ok = false; }
            if (ok) ix.Failed.Remove(f);
            else { ix.Failed.Add(f); if (ix.Failed.Count > 200) return false; }
        }
        return true;
    }
    static bool RereadOne(IVolume v, WinVolume wv, MftIndex ix, int f, byte[] rec) {
        int rs = ix.RecordSize;
        int r = ReadOne(v, wv, ix, f, rec);
        if (r < 0) return false;
        if (r == 0) { ix.Clear(f); return true; }                                                // 删掉了
        ulong bref = U64(rec, 0x20);
        if ((bref & 0xFFFFFFFFFFFF) != 0) {
            // 这个号现在是别的文件的续页：它原来作为主记录的内容清掉，只留它自己那份实际占用（名字和大小记在主记录上，主记录改了会整条重读）
            ix.Clear(f);
            ix.ExtClaim[f] = (ushort)(bref >> 48);
            ix.Disk[f] = RecordDisk(rec, 0, rs);
            return true;
        }
        List<int> segs; bool fromDisk;
        if (!ExtSegs(v, ix, rec, f, out segs, out fromDisk)) return false;
        // 属性列表列出的续页，加上以前读到过的续页（属性列表是从盘上读的话可能没写进最新的）
        List<int> known;
        if (ix.ExtOf.TryGetValue(f, out known)) { if (segs == null) segs = new List<int>(); foreach (int s in known) if (!segs.Contains(s)) segs.Add(s); }
        ushort seq = U16(rec, 0x10);
        List<byte[]> exts = new List<byte[]>(); List<int> extNo = new List<int>();
        if (segs != null) foreach (int s in segs) {
            if (s < 16 || s >= ix.Count) return false;
            byte[] x = new byte[rs];
            int rr = ReadOne(v, wv, ix, s, x);
            if (rr < 0) return false;
            ulong br = U64(x, 0x20);
            if (rr == 0 || (int)(br & 0xFFFFFFFFFFFF) != f || (ushort)(br >> 48) != seq) continue;   // 已经不是它的续页了
            exts.Add(x); extNo.Add(s);
        }
        // 都读好了，才换上
        ix.Clear(f);
        ParseFixed(ix, rec, 0, f);
        for (int i = 0; i < exts.Count; i++) ParseFixed(ix, exts[i], 0, extNo[i]);
        if (fromDisk) ix.Recent[f] = DateTime.UtcNow.Ticks; else ix.Recent.Remove(f);
        return true;
    }
    // 读一条记录并校验：1 在用且读好了  0 没在用  -1 读不了或校验不过
    static int ReadOne(IVolume v, WinVolume wv, MftIndex ix, int f, byte[] rec) {
        int rs = ix.RecordSize;
        if (wv != null) return FreshRecord(wv, f, rec, rs);
        ReadVirtual(v, ix, (long)f * rs, rec, rs);
        uint sig = U32(rec, 0);
        if (sig == 0x44414142) return -1;                   // "BAAD"
        if (sig != 0x454C4946) return 0;                    // 从没用过的空记录
        if (!Fixup(rec, 0, rs)) return -1;
        return (U16(rec, 0x16) & 1) != 0 ? 1 : 0;
    }
    // 经文件系统读一条记录。文件系统给的一般是已经换回原值的样子；扇区末尾还都是校验号的（盘上的样子）才按校验号换回
    static int FreshRecord(WinVolume wv, int f, byte[] rec, int rs) {
        int r = wv.GetRecord(f, rec, rs);
        if (r <= 0) return r;
        uint sig = U32(rec, 0);
        if (sig == 0x44414142) return -1;
        if (sig != 0x454C4946) return 0;
        int usaOfs = U16(rec, 4), usaCnt = U16(rec, 6);
        if (usaCnt != rs / 512 + 1 || usaOfs < 0x28 || usaOfs + usaCnt * 2 > rs) return -1;
        bool raw = true;
        for (int i = 1; i < usaCnt; i++) { int p = i * 512 - 2; if (rec[p] != rec[usaOfs] || rec[p + 1] != rec[usaOfs + 1]) { raw = false; break; } }
        if (raw && !Fixup(rec, 0, rs)) return -1;
        return (U16(rec, 0x16) & 1) != 0 ? 1 : 0;
    }
    // 主记录的属性列表指到的续页。没有属性列表：segs = null。属性列表太长、放在盘上别处时从盘上读（fromDisk = true）
    static bool ExtSegs(IVolume v, MftIndex ix, byte[] r, int frn, out List<int> segs, out bool fromDisk) {
        segs = null; fromDisk = false;
        int rs = ix.RecordSize;
        int a = U16(r, 0x14), end = Math.Min(rs, (int)U32(r, 0x18));
        while (a + 16 <= end) {
            uint type = U32(r, a);
            if (type == 0xFFFFFFFF || type > 0x20) break;
            int len = (int)U32(r, a + 4);
            if (len < 16 || a + len > end) return false;
            if (type == 0x20) {
                byte[] list; int c, cl;
                if (r[a + 8] == 0) { list = r; c = a + U16(r, a + 0x14); cl = (int)U32(r, a + 0x10); if (c + cl > a + len) return false; }
                else {
                    if (len < 0x40) return false;
                    long sz = I64(r, a + 0x30);
                    if (sz <= 0 || sz > 4 * 1024 * 1024) return false;
                    List<long[]> runs = DecodeRuns(r, a + U16(r, a + 0x20), a + len, ix.ClusterSize);
                    list = new byte[sz]; long got = 0;
                    foreach (long[] run in runs) { if (got >= sz) break; int take = (int)Math.Min(run[1], sz - got); ReadAt(v, run[0], list, (int)got, take); got += take; }
                    if (got < sz) return false;
                    c = 0; cl = (int)sz; fromDisk = true;
                }
                segs = new List<int>();
                for (int o = c; o + 26 <= c + cl; ) {
                    int el = U16(list, o + 4);
                    if (el < 26 || o + el > c + cl) return false;
                    int seg = (int)(U64(list, o + 16) & 0xFFFFFFFFFFFF);
                    if (seg != frn && !segs.Contains(seg)) segs.Add(seg);
                    o += el;
                }
                return true;
            }
            a += len;
        }
        return true;
    }
    // 整份读完后，校验不过的记录再读一次（多半是读的那一刻正在写）
    public static void RetryBad(IVolume v, MftIndex ix) {
        if (ix.BadList.Count == 0 || ix.BadList.Count > 20000) return;
        List<int> list = ix.BadList; ix.BadList = new List<int>();
        int rs = ix.RecordSize; byte[] rec = new byte[rs];
        WinVolume wv = v as WinVolume;
        ix.Vol = v;
        foreach (int f in list) {
            try {
                int r = ReadOne(v, wv, ix, f, rec);
                if (r < 0) { ix.BadList.Add(f); continue; }
                ix.Bad--;
                if (r == 1) ParseFixed(ix, rec, 0, f);      // 0：现在已经没在用了
            } catch { ix.BadList.Add(f); }
        }
    }
    // 续页记着的主记录序号对不上（过时的续页，主记录比它后读到时没拦住）：这些文件整条重读
    public static void FixStaleExt(IVolume v, MftIndex ix) {
        List<int> owners = new List<int>();
        foreach (KeyValuePair<int, List<int>> kv in ix.ExtOf) {
            foreach (int s in kv.Value) { ushort c; if (ix.ExtClaim.TryGetValue(s, out c) && (ix.Flag[kv.Key] & 1) != 0 && c != ix.Seq[kv.Key]) { owners.Add(kv.Key); break; } }
        }
        if (owners.Count == 0) return;
        foreach (int o in owners) { List<int> l = ix.ExtOf[o]; l.RemoveAll(s => { ushort c; return ix.ExtClaim.TryGetValue(s, out c) && c != ix.Seq[o]; }); }
        Reread(v, ix, owners);
    }


    // 用读出来的文件表搭出和逐个文件夹扫描一样的文件夹树
    public static DmNode BuildTree(MftIndex ix, out List<DmFile> big, out long files, out long dirs) { long o; return BuildTree(ix, out big, out files, out dirs, out o); }
    // orphans：所在文件夹的记录不在（或序号对不上）的文件个数。很多的话说明读出来的表有问题
    public static DmNode BuildTree(MftIndex ix, out List<DmFile> big, out long files, out long dirs, out long orphans) {
        int n = ix.Count;
        DmNode[] nodes = new DmNode[n];
        DmNode root = new DmNode(); root.Name = ix.Root;
        nodes[5] = root;
        for (int i = 16; i < n; i++) {
            if ((ix.Flag[i] & 3) != 3) continue;
            DmNode d = new DmNode(); d.Name = ix.Name[i] ?? ("#" + i); d.IsLink = (ix.Flag[i] & 4) != 0; d.Cloud = !d.IsLink && (ix.Flag[i] & 16) != 0; d.LastWrite = 0;
            nodes[i] = d;
        }
        for (int i = 16; i < n; i++) {
            DmNode d = nodes[i]; if (d == null) continue;
            int p = ix.Parent[i];
            if (p < 0 || p >= n || p == i || nodes[p] == null || ix.Seq[p] != ix.ParentSeq[i]) continue;
            d.Parent = nodes[p]; nodes[p].Kids.Add(d);
        }
        // 只要从根能走到的；链接目录不往里走（和逐个扫描一样）
        bool[] reach = new bool[n];
        Stack<int> st = new Stack<int>();
        reach[5] = true; st.Push(5);
        Dictionary<DmNode, int> idOf = new Dictionary<DmNode, int>();
        for (int i = 16; i < n; i++) if (nodes[i] != null) idOf[nodes[i]] = i;
        dirs = 0;
        while (st.Count > 0) {
            DmNode d = nodes[st.Pop()];
            if (d.IsLink) { d.Kids.Clear(); continue; }
            foreach (DmNode k in d.Kids) { int id = idOf[k]; if (!reach[id]) { reach[id] = true; dirs++; st.Push(id); } }
        }
        big = new List<DmFile>();
        files = 0; orphans = 0;
        long uniq = 0, uniqDisk = 0, linked = 0;
        long[] tc = new long[FileCats.N], tb = new long[FileCats.N], td = new long[FileCats.N];
        for (int i = 16; i < n; i++) {
            byte f = ix.Flag[i];
            if ((f & 1) == 0 || (f & 2) != 0) continue;
            int pp = ix.Parent[i];
            if (pp >= 16 && (pp >= n || nodes[pp] == null || ix.Seq[pp] != ix.ParentSeq[i])) orphans++;
            long size = ix.Size[i], wt = ix.Write[i], disk = FileDisk(ix, i);
            List<MftLink> l;
            bool multi = ix.Extra.TryGetValue(i, out l) && l.Count > 0;   // 有不止一个名字（硬链接）：每个名字下都算，但盘上只有一份
            uint at = ix.Attr != null && i < ix.Attr.Length ? ix.Attr[i] : 0; bool ha = ix.Attr != null;
            if ((f & 32) != 0) at &= ~0x400u;          // 系统压缩、重复数据删除：程序看到的是普通文件
            bool any = AddFile(ix, nodes, reach, ix.Parent[i], ix.ParentSeq[i], ix.Name[i], size, disk, multi, wt, at, ha, big, ref files);
            if (multi) foreach (MftLink k in l) any |= AddFile(ix, nodes, reach, k.Parent, k.ParentSeq, k.Name, size, disk, true, wt, at, ha, big, ref files);
            if (any) { uniq += size; uniqDisk += disk; if (multi) linked += size; byte c = ix.Cat[i]; tc[c]++; tb[c] += size; td[c] += disk; }
        }
        root.TypeCount = tc; root.TypeBytes = tb; root.TypeDisk = td;
        root.HasDisk = true; root.UniqueSize = uniq; root.UniqueDisk = uniqDisk; root.Linked = linked; root.MftBytes = ix.MftBytes;
        return root;
    }
    // 一个文件实际占的盘：主记录加上它的续页（续页记着的主记录序号要对得上）
    static long FileDisk(MftIndex ix, int i) {
        long d = ix.Disk[i];
        List<int> el;
        if (ix.ExtOf.TryGetValue(i, out el)) foreach (int s in el) { ushort c; if (s < ix.Count && (!ix.ExtClaim.TryGetValue(s, out c) || c == ix.Seq[i])) d += ix.Disk[s]; }
        return d;
    }
    static bool AddFile(MftIndex ix, DmNode[] nodes, bool[] reach, int p, ushort ps, string name, long size, long disk, bool shared, long wt, List<DmFile> big, ref long files) { return AddFile(ix, nodes, reach, p, ps, name, size, disk, shared, wt, 0, false, big, ref files); }
    static bool AddFile(MftIndex ix, DmNode[] nodes, bool[] reach, int p, ushort ps, string name, long size, long disk, bool shared, long wt, uint attr, bool hasAttr, List<DmFile> big, ref long files) {
        if (p < 0 || p >= nodes.Length || nodes[p] == null || !reach[p] || ix.Seq[p] != ps) return false;
        DmNode d = nodes[p];
        if (d.IsLink) return false;
        d.Own += size; d.OwnFiles++; files++;
        d.OwnDisk += disk; if (shared) d.OwnShared += size;
        if (wt > d.LastWrite) d.LastWrite = wt;
        if (size >= BigMin && name != null) {
            DmFile x = new DmFile(); x.Dir = d; x.Name = name; x.Size = size; x.Disk = disk; x.Shared = shared; x.Attr = attr; x.HasAttr = hasAttr;
            try { x.Modified = DateTime.FromFileTime(wt); } catch { }
            big.Add(x);
        }
        return true;
    }

    // ---------- 变更日志（USN）：同一次打开程序里再扫描时，只重读改动过的记录 ----------
    const uint FSCTL_QUERY_USN_JOURNAL = 0x000900F4, FSCTL_READ_USN_JOURNAL = 0x000900BB;
    public static bool QueryJournal(WinVolume v, out ulong id, out long first, out long next) {
        id = 0; first = 0; next = 0;
        byte[] o = new byte[80]; int got, err;
        if (!v.Ioctl(FSCTL_QUERY_USN_JOURNAL, null, o, out got, out err) || got < 24) return false;
        id = U64(o, 0); first = I64(o, 8); next = I64(o, 16);
        return true;
    }
    // 从 start 读到 until：改动过的记录号；返回 false 表示日志断了（被清理、换了一个），要整份重读
    // minTime：只要这个时间（UTC FILETIME）以后的改动；open：顺便记下还开着（没有「关闭」记录）的文件
    public static bool ReadJournal(WinVolume v, ulong id, long start, long until, HashSet<int> frns, int max, long minTime, HashSet<int> open) {
        byte[] inb = new byte[40], outb = new byte[256 * 1024];
        long usn = start;
        for (int loop = 0; loop < 100000 && usn < until; loop++) {
            Array.Clear(inb, 0, inb.Length);
            Buffer.BlockCopy(BitConverter.GetBytes(usn), 0, inb, 0, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(0xFFFFFFFFu), 0, inb, 8, 4);
            Buffer.BlockCopy(BitConverter.GetBytes(id), 0, inb, 32, 8);
            int got, err;
            if (!v.Ioctl(FSCTL_READ_USN_JOURNAL, inb, outb, out got, out err)) return false;
            if (got < 8) return false;
            long nextUsn = I64(outb, 0);
            bool done = false;
            for (int o = 8; o + 60 <= got; ) {
                int rl = (int)U32(outb, o);
                if (rl < 60 || o + rl > got) return false;
                if (U16(outb, o + 4) != 2) return false;          // 128 位记录号（ReFS 那种）不认
                if (I64(outb, o + 24) >= until) { done = true; break; }
                int frn = (int)(U64(outb, o + 8) & 0xFFFFFFFFFFFF);
                if (open != null) {
                    if ((U32(outb, o + 40) & 0x80000000u) != 0) open.Remove(frn);   // USN_REASON_CLOSE
                    else if (open.Count < 50000) open.Add(frn);
                }
                if (I64(outb, o + 32) >= minTime) frns.Add(frn);   // 改名、移动都记在文件自己的记录上，不用重读父文件夹
                if (frns.Count > max) return false;
                o += rl;
            }
            if (done || got <= 8 || nextUsn <= usn) break;
            usn = nextUsn;
        }
        return true;
    }
}

