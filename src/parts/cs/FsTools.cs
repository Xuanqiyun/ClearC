// ==================== 文件系统小工具：实际占用、硬链接合并、放进回收站 ====================
public static class FsTools {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool MoveFileExW(string lpExistingFileName, string lpNewFileName, int dwFlags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT {
        public IntPtr hwnd; public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags; public int fAnyOperationsAborted; public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperationW(ref SHFILEOPSTRUCT lpFileOp);

    static bool Win { get { return System.IO.Path.DirectorySeparatorChar == '\\'; } }

    // 一个文件实际占用的磁盘空间（压缩、稀疏文件会比文件大小小）
    public static long OnDisk(string file) {
        if (!Win) { try { return new FileInfo(file).Length; } catch { return 0; } }
        uint hi; uint lo = GetCompressedFileSizeW("\\\\?\\" + file, out hi);
        if (lo == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) { try { return new FileInfo(file).Length; } catch { return 0; } }
        return ((long)hi << 32) | lo;
    }
    // 整个文件夹实际占用的磁盘空间
    public static long OnDiskTree(string dir) {
        long sum = 0;
        Stack<string> st = new Stack<string>(); st.Push(dir);
        while (st.Count > 0) {
            string d = st.Pop();
            try {
                foreach (FileSystemInfo e in new DirectoryInfo(d).EnumerateFileSystemInfos()) {
                    if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    if ((e.Attributes & FileAttributes.Directory) != 0) st.Push(e.FullName); else sum += OnDisk(e.FullName);
                }
            } catch { }
        }
        return sum;
    }
    // 是否被系统压缩（CompactOS）过：实际占用明显小于文件大小
    public static bool LooksCompressed(string file) {
        try { long len = new FileInfo(file).Length; return len > 0 && OnDisk(file) < len * 0.9; } catch { return false; }
    }
    // 把 dup 换成指向 keep 的硬链接：两个位置都还在，只占一份空间。返回空字符串表示成功
    static readonly Dictionary<string, string> ownerOfSid = new Dictionary<string, string>();
    // 文件的所有者（「DOMAIN\名字」；读不到就空）。同一个账户只翻译一次
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetNamedSecurityInfoW(string name, int type, uint info, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LookupAccountSidW(string system, IntPtr sid, StringBuilder name, ref int nameLen, StringBuilder domain, ref int domLen, out int use);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    public static string Owner(string path) {
        if (System.IO.Path.DirectorySeparatorChar != '\\') return "";
        IntPtr owner, g, d, s, sd;
        if (GetNamedSecurityInfoW(path, 1, 1, out owner, out g, out d, out s, out sd) != 0 || owner == IntPtr.Zero) return "";
        try {
            IntPtr ps; string sidText = "";
            if (ConvertSidToStringSidW(owner, out ps)) { sidText = Marshal.PtrToStringUni(ps); LocalFree(ps); }
            string name;
            lock (ownerOfSid) { if (sidText.Length > 0 && ownerOfSid.TryGetValue(sidText, out name)) return name; }
            StringBuilder nm = new StringBuilder(256), dm = new StringBuilder(256); int nl = 256, dl = 256, use;
            name = LookupAccountSidW(null, owner, nm, ref nl, dm, ref dl, out use) ? (dm.Length > 0 ? dm + "\\" + nm : nm.ToString()) : sidText;
            lock (ownerOfSid) { if (sidText.Length > 0) ownerOfSid[sidText] = name; }
            return name;
        } catch { return ""; } finally { if (sd != IntPtr.Zero) LocalFree(sd); }
    }
    public static bool IsCompressed(string path) { try { return (System.IO.File.GetAttributes(path) & System.IO.FileAttributes.Compressed) != 0; } catch { return false; } }
    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION { public uint FileAttributes; public long CreationTime, LastAccessTime, LastWriteTime; public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    static bool FileId(string p, out BY_HANDLE_FILE_INFORMATION info) {
        info = new BY_HANDLE_FILE_INFORMATION();
        // 不要读写权限（只看属性），别的程序独占打开着也能看；BACKUP_SEMANTICS 让文件夹也能打开
        using (Microsoft.Win32.SafeHandles.SafeFileHandle h = CreateFileW("\\\\?\\" + p, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            return GetFileInformationByHandle(h, out info);
        }
    }
    // 两个路径是不是同一个文件（同一块卷、同一个文件记录）：硬链接的两个名字、经过目录链接的两条路径都算同一个。
    // 读不到就当是同一个：调用的地方都是「是同一个就不删」，宁可不删
    public static bool SameFile(string a, string b) {
        if (!Win) { try { return new FileInfo(a).FullName == new FileInfo(b).FullName; } catch { return true; } }
        try {
            BY_HANDLE_FILE_INFORMATION x, y;
            if (!FileId(a, out x) || !FileId(b, out y)) return true;
            return x.VolumeSerialNumber == y.VolumeSerialNumber && x.FileIndexHigh == y.FileIndexHigh && x.FileIndexLow == y.FileIndexLow;
        } catch { return true; }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint QueryDosDeviceW(string device, StringBuilder target, int max);
    // 盘符是不是用 subst 映射出来的（其实是另一块盘上的一个文件夹）：拿来查重复文件会把同一个文件当成两份
    public static bool IsSubst(string drive) {
        if (!Win || string.IsNullOrEmpty(drive)) return false;
        try { StringBuilder sb = new StringBuilder(1024); if (QueryDosDeviceW(drive.Substring(0, 2), sb, sb.Capacity) == 0) return false; return sb.ToString().StartsWith("\\??\\"); } catch { return false; }
    }
    // 回收站一共多大：系统直接给出合计，不用一项一项问（回收站里东西多时一项一项问要很久）。读不到返回 -1
    [StructLayout(LayoutKind.Sequential)] struct RbInfo { public int cbSize; public long Size; public long Items; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct RbInfoPacked { public int cbSize; public long Size; public long Items; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")] static extern int QueryRb(string root, ref RbInfo info);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")] static extern int QueryRbPacked(string root, ref RbInfoPacked info);
    public static long RecycleBinBytes() {
        if (!Win) return -1;
        try { RbInfo q = new RbInfo(); q.cbSize = Marshal.SizeOf(typeof(RbInfo)); if (QueryRb(null, ref q) == 0 && q.Size >= 0) return q.Size; } catch { }
        try { RbInfoPacked p = new RbInfoPacked(); p.cbSize = Marshal.SizeOf(typeof(RbInfoPacked)); if (QueryRbPacked(null, ref p) == 0 && p.Size >= 0) return p.Size; } catch { }
        return -1;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, int len);
    // 8.3 短路径换成长路径（路径不存在就原样返回）
    public static string LongPath(string p) {
        if (!Win || string.IsNullOrEmpty(p)) return p;
        try { StringBuilder sb = new StringBuilder(1024); uint n = GetLongPathNameW(p, sb, sb.Capacity); return (n > 0 && n < sb.Capacity) ? sb.ToString() : p; } catch { return p; }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WIN32_FIND_DATAW {
        public uint dwFileAttributes; public uint ftC1, ftC2, ftA1, ftA2, ftW1, ftW2; public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr FindFirstFileW(string name, out WIN32_FIND_DATAW data);
    [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
    // 重解析点的类型（没有重解析点返回 0）：目录联接 0xA0000003、符号链接 0xA000000C、OneDrive 这类云端文件 0x9000xx1A
    public static uint ReparseTag(string path) {
        if (!Win || string.IsNullOrEmpty(path)) return 0;
        WIN32_FIND_DATAW d;
        IntPtr h = FindFirstFileW("\\\\?\\" + path, out d);
        if (h == new IntPtr(-1)) return 0;
        FindClose(h);
        return (d.dwFileAttributes & 0x400) != 0 ? d.dwReserved0 : 0;
    }
    public static bool IsCloudTag(uint tag) { return (tag & 0xFFFF0FFF) == 0x9000001A; }
    // 文件夹里（含子文件夹，不进链接）最近一次写入的时间；最多看 200000 项
    public static DateTime NewestWrite(string dir) {
        DateTime best = DateTime.MinValue; int n = 0;
        Stack<string> st = new Stack<string>(); st.Push(dir);
        while (st.Count > 0 && n < 200000) {
            string d = st.Pop();
            try {
                DirectoryInfo di = new DirectoryInfo(d);
                if (di.LastWriteTime > best) best = di.LastWriteTime;
                foreach (FileSystemInfo x in di.EnumerateFileSystemInfos()) {
                    n++;
                    if (x.LastWriteTime > best) best = x.LastWriteTime;
                    if ((x.Attributes & FileAttributes.Directory) != 0 && (x.Attributes & FileAttributes.ReparsePoint) == 0) st.Push(x.FullName);
                }
            } catch { }
        }
        return best;
    }
    public static string MergeHardLink(string keep, string dup) {
        try {
            if (!string.Equals(System.IO.Path.GetPathRoot(keep), System.IO.Path.GetPathRoot(dup), StringComparison.OrdinalIgnoreCase)) return L10n.T("不在同一块盘上");
            if (Win) {
                DriveInfo di = new DriveInfo(System.IO.Path.GetPathRoot(keep));
                if (!string.Equals(di.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase)) return L10n.T("这块盘不是 NTFS 格式");
            }
            FileInfo fd = new FileInfo(dup);
            if ((fd.Attributes & FileAttributes.ReadOnly) != 0) fd.Attributes &= ~FileAttributes.ReadOnly;
            string tmp = dup + ".cleanc_link";
            if (File.Exists(tmp)) File.Delete(tmp);
            if (!Win) return L10n.T("只支持 Windows");
            if (!CreateHardLinkW("\\\\?\\" + tmp, "\\\\?\\" + keep, IntPtr.Zero)) return string.Format(L10n.T("建硬链接失败（错误 {0}）"), Marshal.GetLastWin32Error());
            if (!MoveFileExW("\\\\?\\" + tmp, "\\\\?\\" + dup, 1)) { int e = Marshal.GetLastWin32Error(); try { File.Delete(tmp); } catch { } return string.Format(L10n.T("替换原文件失败（错误 {0}，文件可能正被打开）"), e); }
            return "";
        } catch (Exception ex) { return ex.Message; }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumePathNameW(string path, StringBuilder root, int len);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder name, int len);
    // 路径所在卷的 GUID（形如 {xxxxxxxx-...}）；读不到返回空
    public static string VolumeGuid(string path) {
        if (!Win) return "";
        try {
            StringBuilder root = new StringBuilder(1024);
            if (!GetVolumePathNameW(path, root, root.Capacity)) return "";
            StringBuilder vn = new StringBuilder(128);
            if (!GetVolumeNameForVolumeMountPointW(root.ToString(), vn, vn.Capacity)) return "";
            string s = vn.ToString(); int a = s.IndexOf('{'), b = s.IndexOf('}');
            return (a >= 0 && b > a) ? s.Substring(a, b - a + 1) : "";
        } catch { return ""; }
    }
    // 一批文件、文件夹一起放进回收站（可恢复删除）。太大放不进回收站的由系统弹窗问，不会悄悄永久删除
    public static int RecycleMany(string[] paths) {
        if (paths == null || paths.Length == 0) return 0;
        StringBuilder sb = new StringBuilder();
        foreach (string p in paths) { sb.Append(p); sb.Append('\0'); }
        sb.Append('\0');
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.wFunc = 3; op.pFrom = sb.ToString();
        op.fFlags = 0x40 | 0x10 | 0x4000 | 0x400 | 0x4;   // ALLOWUNDO | NOCONFIRMATION | WANTNUKEWARNING | NOERRORUI | SILENT
        int r = SHFileOperationW(ref op);
        if (r == 0 && op.fAnyOperationsAborted != 0) return -1;
        return r;
    }
    // 放进回收站；太大放不进回收站时由系统弹窗询问，不会悄悄永久删除。返回 0 表示成功
    public static int Recycle(string path, long hwnd) {
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.hwnd = new IntPtr(hwnd);
        op.wFunc = 3;                        // FO_DELETE
        op.pFrom = path + "\0\0";
        op.fFlags = 0x40 | 0x10 | 0x4000;     // ALLOWUNDO | NOCONFIRMATION | WANTNUKEWARNING
        int r = SHFileOperationW(ref op);
        if (r == 0 && op.fAnyOperationsAborted != 0) return -1;
        return r;
    }
}

// ==================== 蓝屏转储（C:\Windows\Minidump\*.dmp）：不用调试器也能读出错误码、参数、出事时加载的驱动和栈上出现的驱动 ====================
// 64 位内核小转储：开头是 DUMP_HEADER64（0x2000 字节），接着 TRIAGE_DUMP64，里面记着驱动列表、异常记录和调用栈在文件里的位置
public class DumpDriver { public string Name, Path; public ulong Base; public uint Size; public bool Hit; }   // Name 是文件名，Path 是转储里记的完整路径
public class DumpInfo {
    public string File, Error = "";
    public bool Ok, Is64;
    public uint BugCheck; public ulong[] Params = new ulong[4];
    public DateTime Time; public uint Build, ServicePackBuild;
    public ulong ExceptionAddress; public uint ExceptionCode;
    public List<DumpDriver> Drivers = new List<DumpDriver>();
    public List<string> StackDrivers = new List<string>();   // 调用栈上出现的驱动（按出现顺序，去重），ntoskrnl 排除
    public string Suspect = "";                             // 最可能的：异常地址或出事参数落在哪个驱动里；没有就取栈上第一个非系统驱动
    public string SuspectFrom = "";                         // address = 出事地址落在它里面（证据强）；stack = 只是栈上第一个（证据弱）
    public uint Status;                                     // 读写失败类（0x7A、0x77）和异常类（0x1E、0x3B…）里记着的状态码 / 异常码
    public string PageOwner = "";                           // 0x7A：没读进来的那一页属于哪个驱动（它是受害者，不是原因）
    public string Process = "";                             // 出事时的当前进程（EPROCESS.ImageFileName）
    public bool ProcessIsParam1;                            // 0xEF：当前进程就是参数 1 里那个死掉的关键进程
    public static DumpInfo Parse(string path) { return Parse(path, 4 * 1024 * 1024); }
    public static DumpInfo Parse(string path, int maxBytes) {
        DumpInfo d = new DumpInfo(); d.File = path;
        byte[] b;
        try {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                int n = (int)Math.Min(fs.Length, (long)maxBytes); b = new byte[n]; int got = 0;
                while (got < n) { int r = fs.Read(b, got, n - got); if (r <= 0) break; got += r; }
            }
        } catch (Exception e) { d.Error = e.Message; return d; }
        return Parse(b, d);
    }
    public static DumpInfo Parse(byte[] b, DumpInfo d) {
        if (d == null) d = new DumpInfo();
        if (b.Length < 0x60 || b[0] != 'P' || b[1] != 'A' || b[2] != 'G' || b[3] != 'E') { d.Error = "not a kernel dump"; return d; }
        string valid = Encoding.ASCII.GetString(b, 4, 4);
        if (valid == "DU64") d.Is64 = true; else if (valid == "DUMP") d.Is64 = false; else { d.Error = "unknown dump format " + valid; return d; }
        try {
            if (d.Is64) {
                d.Build = BitConverter.ToUInt32(b, 0x0C);
                d.BugCheck = BitConverter.ToUInt32(b, 0x38);
                for (int i = 0; i < 4; i++) d.Params[i] = BitConverter.ToUInt64(b, 0x40 + i * 8);
                if (b.Length >= 0xFB0) { try { d.Time = DateTime.FromFileTime(BitConverter.ToInt64(b, 0xFA8)); } catch { } }
                int tri = 0x2000;
                if (b.Length >= tri + 0x50) {
                    d.ServicePackBuild = BitConverter.ToUInt32(b, tri);
                    uint exOff = BitConverter.ToUInt32(b, tri + 0x10), csOff = BitConverter.ToUInt32(b, tri + 0x28), csSize = BitConverter.ToUInt32(b, tri + 0x2C);
                    uint prOff = BitConverter.ToUInt32(b, tri + 0x20), thOff = BitConverter.ToUInt32(b, tri + 0x24);
                    uint drvOff = BitConverter.ToUInt32(b, tri + 0x30), drvCount = BitConverter.ToUInt32(b, tri + 0x34);
                    if (exOff > 0 && exOff + 0x18 <= b.Length) { d.ExceptionCode = BitConverter.ToUInt32(b, (int)exOff); d.ExceptionAddress = BitConverter.ToUInt64(b, (int)exOff + 0x10); }
                    const int entry = 0x90;   // DUMP_DRIVER_ENTRY64：名字的位置（4 字节，补齐到 8）+ KLDR_DATA_TABLE_ENTRY64（0x88）
                    for (uint i = 0; i < drvCount && i < 4096; i++) {
                        long o = (long)drvOff + (long)i * entry;
                        if (o + entry > b.Length) break;
                        DumpDriver dr = new DumpDriver();
                        uint nameOff = BitConverter.ToUInt32(b, (int)o);
                        dr.Base = BitConverter.ToUInt64(b, (int)o + 8 + 0x30);
                        dr.Size = BitConverter.ToUInt32(b, (int)o + 8 + 0x40);
                        dr.Path = ReadString(b, nameOff);
                        dr.Name = Leaf(dr.Path);
                        if (dr.Name.Length > 0) d.Drivers.Add(dr);
                    }
                    if (csOff > 0 && csSize > 0 && csOff + csSize <= b.Length) {
                        for (uint p = 0; p + 8 <= csSize; p += 8) {
                            ulong a = BitConverter.ToUInt64(b, (int)(csOff + p));
                            DumpDriver hit = Find(d, a);
                            if (hit != null && !IsKernel(hit.Name) && !d.StackDrivers.Contains(hit.Name)) { d.StackDrivers.Add(hit.Name); hit.Hit = true; }
                        }
                    }
                    if (prOff > 0) d.Process = ImageName(b, prOff);
                    // KTHREAD.ApcState.Process（0xB8）和 KTHREAD.Process（0x220）：Win10、Win11 x64 一直是这两个位置
                    if (thOff > 0 && d.Params[0] != 0) {
                        foreach (int k in new int[] { 0xB8, 0x220 }) if (thOff + k + 8 <= b.Length && BitConverter.ToUInt64(b, (int)thOff + k) == d.Params[0]) d.ProcessIsParam1 = true;
                    }
                }
            } else {
                d.Build = BitConverter.ToUInt32(b, 0x0C);
                d.BugCheck = BitConverter.ToUInt32(b, 0x28);
                for (int i = 0; i < 4; i++) d.Params[i] = BitConverter.ToUInt32(b, 0x2C + i * 4);
                d.Error = "32-bit dump: only the bug check code is read";
            }
            d.Status = StatusParam(d);
            if (d.BugCheck == 0x7A || d.BugCheck == 0x77) {
                // 读盘失败：出事地址是「没读进来的那一页」，它属于哪个驱动只说明那个驱动倒霉，原因在硬盘或硬盘的连接上，不点名驱动
                DumpDriver pg = Find(d, d.Params[3]); if (pg != null) d.PageOwner = pg.Name;
            } else {
                // 最可能的驱动：异常地址，或者这类错误码里记着出事地址的那个参数
                ulong[] addrs = AddrParams(d);
                foreach (ulong a in addrs) { DumpDriver hit = Find(d, a); if (hit != null && !IsKernel(hit.Name)) { d.Suspect = hit.Name; d.SuspectFrom = "address"; hit.Hit = true; break; } }
                if (d.Suspect.Length == 0 && d.StackDrivers.Count > 0 && d.BugCheck != 0xEF && d.BugCheck != 0x124) { d.Suspect = d.StackDrivers[0]; d.SuspectFrom = "stack"; }
            }
            d.Ok = true;
        } catch (Exception e) { d.Error = e.Message; }
        return d;
    }
    static ulong[] AddrParams(DumpInfo d) {
        List<ulong> a = new List<ulong>();
        if (d.ExceptionAddress != 0) a.Add(d.ExceptionAddress);
        switch (d.BugCheck) {
            case 0x0A: case 0xD1: a.Add(d.Params[3]); break;                    // IRQL_NOT_LESS_OR_EQUAL, DRIVER_IRQL…：参数 4 是出事地址
            case 0x1E: case 0x7E: case 0x8E: case 0x3B: case 0x1000007E: case 0x1000008E: a.Add(d.Params[1]); break;   // 异常类：参数 2 是出事地址
            case 0x50: case 0xD5: case 0xD6: a.Add(d.Params[2]); break;        // 页错误类：参数 3 是访问内存的那条指令
            case 0xC5: a.Add(d.Params[3]); break;                               // DRIVER_CORRUPTED_EXPOOL：参数 4
            case 0x116: a.Add(d.Params[1]); break;                              // VIDEO_TDR_FAILURE：参数 2 指向出问题的显卡驱动
        }
        return a.ToArray();
    }
    // 状态码：0x7A 的参数 2；0x77 参数 1 是 0/1/2 时在参数 2，否则就是参数 1；异常类的参数 1 是异常码
    static uint StatusParam(DumpInfo d) {
        switch (d.BugCheck) {
            case 0x7A: return (uint)d.Params[1];
            case 0x77: return d.Params[0] <= 2 ? (uint)d.Params[1] : (uint)d.Params[0];
            case 0x1E: case 0x7E: case 0x8E: case 0x3B: case 0x1000007E: case 0x1000008E: return (uint)d.Params[0];
        }
        return 0;
    }
    static string Leaf(string p) { if (p == null) return ""; int i = p.LastIndexOfAny(new char[] { '\\', '/' }); return i >= 0 ? p.Substring(i + 1) : p; }
    // EPROCESS.ImageFileName：15 个字节的 ASCII，后面一个字节是 PriorityClass（0–6）。先试各版本已知的位置，再按这个特征找
    static string ImageName(byte[] b, uint pr) {
        foreach (int k in new int[] { 0x450, 0x5A8, 0x338, 0x448, 0x2E0 }) { string s = ImageAt(b, pr + (uint)k); if (s.Length > 0) return s; }
        for (int k = 0x200; k <= 0x800; k += 8) { string s = ImageAt(b, pr + (uint)k); if (s.Length > 0 && (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || s == "System" || s == "Registry" || s == "MemCompression")) return s; }
        return "";
    }
    static string ImageAt(byte[] b, uint o) {
        if (o + 16 > b.Length) return "";
        int n = 0; while (n < 15 && b[o + n] >= 0x20 && b[o + n] < 0x7F) n++;
        if (n < 2) return "";
        for (int i = n; i < 15; i++) if (b[o + i] != 0) return "";
        if (b[o + 15] > 6) return "";
        string s = Encoding.ASCII.GetString(b, (int)o, n);
        foreach (char c in s) if (!(char.IsLetterOrDigit(c) || c == '.' || c == '_' || c == '-' || c == ' ')) return "";
        return s;
    }
    // 常见状态码 / 异常码的名字
    public static string StatusName(uint s) {
        switch (s) {
            case 0xC000000E: return "STATUS_NO_SUCH_DEVICE"; case 0xC000009C: return "STATUS_DEVICE_DATA_ERROR"; case 0xC000009D: return "STATUS_DEVICE_NOT_CONNECTED";
            case 0xC0000185: return "STATUS_IO_DEVICE_ERROR"; case 0xC000016A: return "STATUS_DISK_OPERATION_FAILED"; case 0xC0000483: return "STATUS_DEVICE_HARDWARE_ERROR";
            case 0xC00000B5: return "STATUS_IO_TIMEOUT"; case 0xC000009A: return "STATUS_INSUFFICIENT_RESOURCES"; case 0xC0000006: return "STATUS_IN_PAGE_ERROR";
            case 0xC000003F: return "STATUS_CRC_ERROR"; case 0xC0000102: return "STATUS_FILE_CORRUPT_ERROR"; case 0xC0000221: return "STATUS_IMAGE_CHECKSUM_MISMATCH";
            case 0xC0000010: return "STATUS_INVALID_DEVICE_REQUEST"; case 0xC0000005: return "STATUS_ACCESS_VIOLATION"; case 0x80000003: return "STATUS_BREAKPOINT";
            case 0xC0000420: return "STATUS_ASSERTION_FAILURE"; case 0xC0000409: return "STATUS_STACK_BUFFER_OVERRUN"; case 0xC000001D: return "STATUS_ILLEGAL_INSTRUCTION";
            case 0xC0000096: return "STATUS_PRIVILEGED_INSTRUCTION"; case 0x80000002: return "STATUS_DATATYPE_MISALIGNMENT"; case 0xC0000094: return "STATUS_INTEGER_DIVIDE_BY_ZERO";
            default: return "";
        }
    }
    // 读盘失败类的状态码：硬盘掉线、坏道、线缆、超时
    public static bool IsStorageStatus(uint s) { return s == 0xC000000E || s == 0xC000009C || s == 0xC000009D || s == 0xC0000185 || s == 0xC000016A || s == 0xC0000483 || s == 0xC00000B5 || s == 0xC000003F; }
    static bool IsKernel(string n) { n = n.ToLowerInvariant(); return n.StartsWith("ntoskrnl") || n.StartsWith("ntkrnl") || n == "hal.dll" || n.StartsWith("hal") || n == "kd.dll" || n.StartsWith("kdcom") || n == "pshed.dll" || n == "bootvid.dll" || n == "clfs.sys" || n == "ci.dll" || n.StartsWith("mcupdate"); }
    static DumpDriver Find(DumpInfo d, ulong a) {
        if (a == 0) return null;
        foreach (DumpDriver dr in d.Drivers) if (a >= dr.Base && dr.Size > 0 && a < dr.Base + dr.Size) return dr;
        return null;
    }
    static string ReadString(byte[] b, uint off) {
        if (off == 0 || off + 4 > b.Length) return "";
        uint len = BitConverter.ToUInt32(b, (int)off);
        if (len == 0 || len > 1024 || off + 4 + len * 2 > b.Length) return "";
        return Encoding.Unicode.GetString(b, (int)off + 4, (int)len * 2).TrimEnd('\0');
    }
    // 常见错误码的名字（Windows 自己的名字）
    public static string CodeName(uint c) {
        switch (c) {
            case 0x0A: return "IRQL_NOT_LESS_OR_EQUAL"; case 0x1A: return "MEMORY_MANAGEMENT"; case 0x1E: return "KMODE_EXCEPTION_NOT_HANDLED"; case 0x24: return "NTFS_FILE_SYSTEM";
            case 0x3B: return "SYSTEM_SERVICE_EXCEPTION"; case 0x3D: return "INTERRUPT_EXCEPTION_NOT_HANDLED"; case 0x44: return "MULTIPLE_IRP_COMPLETE_REQUESTS"; case 0x4E: return "PFN_LIST_CORRUPT";
            case 0x50: return "PAGE_FAULT_IN_NONPAGED_AREA"; case 0x7A: return "KERNEL_DATA_INPAGE_ERROR"; case 0x7E: return "SYSTEM_THREAD_EXCEPTION_NOT_HANDLED"; case 0x7F: return "UNEXPECTED_KERNEL_MODE_TRAP";
            case 0x8E: return "KERNEL_MODE_EXCEPTION_NOT_HANDLED"; case 0x9F: return "DRIVER_POWER_STATE_FAILURE"; case 0xA0: return "INTERNAL_POWER_ERROR"; case 0xBE: return "ATTEMPTED_WRITE_TO_READONLY_MEMORY";
            case 0xC2: return "BAD_POOL_CALLER"; case 0xC4: return "DRIVER_VERIFIER_DETECTED_VIOLATION"; case 0xC5: return "DRIVER_CORRUPTED_EXPOOL"; case 0xD1: return "DRIVER_IRQL_NOT_LESS_OR_EQUAL";
            case 0xD5: return "DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL"; case 0xDE: return "POOL_CORRUPTION_IN_FILE_AREA"; case 0xEF: return "CRITICAL_PROCESS_DIED"; case 0xF4: return "CRITICAL_OBJECT_TERMINATION";
            case 0xF5: return "FLTMGR_FILE_SYSTEM"; case 0xFC: return "ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY"; case 0x109: return "CRITICAL_STRUCTURE_CORRUPTION"; case 0x116: return "VIDEO_TDR_FAILURE";
            case 0x117: return "VIDEO_TDR_TIMEOUT_DETECTED"; case 0x119: return "VIDEO_SCHEDULER_INTERNAL_ERROR"; case 0x124: return "WHEA_UNCORRECTABLE_ERROR"; case 0x133: return "DPC_WATCHDOG_VIOLATION";
            case 0x139: return "KERNEL_SECURITY_CHECK_FAILURE"; case 0x13A: return "KERNEL_MODE_HEAP_CORRUPTION"; case 0x141: return "VIDEO_ENGINE_TIMEOUT_DETECTED"; case 0x154: return "UNEXPECTED_STORE_EXCEPTION";
            case 0x15F: return "CONNECTED_STANDBY_WATCHDOG_TIMEOUT"; case 0x1A8: return "ACPI_DRIVER_INTERNAL"; case 0x1CA: return "SYNTHETIC_WATCHDOG_TIMEOUT"; case 0x1000007E: return "SYSTEM_THREAD_EXCEPTION_NOT_HANDLED_M";
            case 0x1000008E: return "KERNEL_MODE_EXCEPTION_NOT_HANDLED_M"; case 0x100000EA: return "THREAD_STUCK_IN_DEVICE_DRIVER_M"; case 0xEA: return "THREAD_STUCK_IN_DEVICE_DRIVER"; case 0xC000021A: return "STATUS_SYSTEM_PROCESS_TERMINATED";
            default: return "";
        }
    }
}
// ==================== 系统健康页的卡片和进程行 ====================
public class HealthChip { string _f, _b; public string Text { get; set; } public string Fg { get { return Theme.F(_f); } set { _f = value; } } public string Bg { get { return Theme.B(_b); } set { _b = value; } } }
public class HealthCard {
    public string Title { get; set; }
    public string Sub { get; set; }
    public string Tip { get; set; }
    string _stripe; public string Stripe { get { return Theme.B(_stripe); } set { _stripe = value; } }
    public List<HealthChip> Chips { get; set; }
    public List<string> Lines { get; set; }
    public double BarW { get; set; }
    public bool HasBar { get; set; }
    string _bar; public string BarBrush { get { return Theme.B(_bar); } set { _bar = value; } }
    public HealthCard() { Chips = new List<HealthChip>(); Lines = new List<string>(); }
}
public class ProcRow {
    public string Name { get; set; }
    public string Meta { get; set; }
    public string CpuText { get; set; }
    public string WsText { get; set; }
    public string RateText { get; set; }
    public string SinceText { get; set; }
    public string TotalText { get; set; }
    public double Bar { get; set; }
    public double Sort { get; set; }
    // 表头排序用的数字（文字列显示用，排序按这些）
    public double Cpu { get; set; }
    public double Ws { get; set; }
    public double Rate { get; set; }
    public double Since { get; set; }
    public double Total { get; set; }
}
public class DumpRow {
    public string When { get; set; }
    public string Code { get; set; }
    public string Plain { get; set; }
    public string Suspect { get; set; }
    public string Detail { get; set; }
    public string File { get; set; }
    string _fg; public string SuspectBrush { get { return Theme.F(_fg); } set { _fg = value; } }
}
public class NoteRow { public string Head { get; set; } public string Sub { get; set; } public string Body { get; set; } public string Path { get; set; } public bool HasPath { get; set; } }
// 诊断结论和「常见问题修复」：按钮的 Tag 是修复步骤的编号
public class FixBtn { public string Id { get; set; } public string Name { get; set; } public string Tip { get; set; } public bool Enabled { get; set; } }
public class VerdictRow {
    public string Title { get; set; }
    public string Body { get; set; }
    string _fg, _bg; public string Fg { get { return Theme.F(_fg); } set { _fg = value; } } public string Bg { get { return Theme.B(_bg); } set { _bg = value; } }
    public List<FixBtn> Fixes { get; set; }
    public bool HasFixes { get; set; }
    public string PlanTag { get; set; }      // 「按建议处理」按钮的 Tag：plan:<结论编号>
    public string PlanName { get; set; }
    public string PlanTip { get; set; }
    public bool HasPlan { get; set; }
    public string Todo { get; set; }         // 本工具做不了、要你自己做的，编好号
    public bool HasTodo { get; set; }
    public VerdictRow() { Fixes = new List<FixBtn>(); }
}
public class FixStepRow {
    public string Id { get; set; }
    public string Name { get; set; }
    public string Desc { get; set; }
    public string Tag { get; set; }
    public bool Enabled { get; set; }
    string _f, _b; public string TagFg { get { return Theme.F(_f); } set { _f = value; } } public string TagBg { get { return Theme.B(_b); } set { _b = value; } }
}
public class FixGroupRow {
    public string Id { get; set; }
    public string Title { get; set; }
    public string Desc { get; set; }
    public List<FixStepRow> Steps { get; set; }
    public FixGroupRow() { Steps = new List<FixStepRow>(); }
}

