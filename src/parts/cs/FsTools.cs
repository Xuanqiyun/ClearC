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
    // 两个路径是不是同一个文件（同一块卷、同一个文件记录）：硬链接的两个名字、经过目录链接的两条路径都算同一个。读不到就当不是
    public static bool SameFile(string a, string b) {
        if (!Win) { try { return new FileInfo(a).FullName == new FileInfo(b).FullName; } catch { return false; } }
        try {
            BY_HANDLE_FILE_INFORMATION x, y;
            using (FileStream fa = new FileStream(a, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (FileStream fb = new FileStream(b, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (!GetFileInformationByHandle(fa.SafeFileHandle, out x) || !GetFileInformationByHandle(fb.SafeFileHandle, out y)) return false;
            }
            return x.VolumeSerialNumber == y.VolumeSerialNumber && x.FileIndexHigh == y.FileIndexHigh && x.FileIndexLow == y.FileIndexLow;
        } catch { return false; }
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
public class DumpDriver { public string Name; public ulong Base; public uint Size; public bool Hit; }
public class DumpInfo {
    public string File, Error = "";
    public bool Ok, Is64;
    public uint BugCheck; public ulong[] Params = new ulong[4];
    public DateTime Time; public uint Build, ServicePackBuild;
    public ulong ExceptionAddress; public uint ExceptionCode;
    public List<DumpDriver> Drivers = new List<DumpDriver>();
    public List<string> StackDrivers = new List<string>();   // 调用栈上出现的驱动（按出现顺序，去重），ntoskrnl 排除
    public string Suspect = "";                             // 最可能的：异常地址或出事参数落在哪个驱动里；没有就取栈上第一个非系统驱动
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
                    uint drvOff = BitConverter.ToUInt32(b, tri + 0x30), drvCount = BitConverter.ToUInt32(b, tri + 0x34);
                    if (exOff > 0 && exOff + 0x18 <= b.Length) { d.ExceptionCode = BitConverter.ToUInt32(b, (int)exOff); d.ExceptionAddress = BitConverter.ToUInt64(b, (int)exOff + 0x10); }
                    const int entry = 0x98;   // DUMP_DRIVER_ENTRY64：名字的位置 + KLDR_DATA_TABLE_ENTRY64
                    for (uint i = 0; i < drvCount && i < 4096; i++) {
                        long o = (long)drvOff + (long)i * entry;
                        if (o + entry > b.Length) break;
                        DumpDriver dr = new DumpDriver();
                        uint nameOff = BitConverter.ToUInt32(b, (int)o);
                        dr.Base = BitConverter.ToUInt64(b, (int)o + 8 + 0x30);
                        dr.Size = BitConverter.ToUInt32(b, (int)o + 8 + 0x40);
                        dr.Name = ReadString(b, nameOff);
                        if (dr.Name.Length > 0) d.Drivers.Add(dr);
                    }
                    if (csOff > 0 && csSize > 0 && csOff + csSize <= b.Length) {
                        for (uint p = 0; p + 8 <= csSize; p += 8) {
                            ulong a = BitConverter.ToUInt64(b, (int)(csOff + p));
                            DumpDriver hit = Find(d, a);
                            if (hit != null && !IsKernel(hit.Name) && !d.StackDrivers.Contains(hit.Name)) { d.StackDrivers.Add(hit.Name); hit.Hit = true; }
                        }
                    }
                }
            } else {
                d.Build = BitConverter.ToUInt32(b, 0x0C);
                d.BugCheck = BitConverter.ToUInt32(b, 0x28);
                for (int i = 0; i < 4; i++) d.Params[i] = BitConverter.ToUInt32(b, 0x2C + i * 4);
                d.Error = "32-bit dump: only the bug check code is read";
            }
            // 最可能的驱动：异常地址，或者这类错误码里记着出事地址的那个参数
            ulong[] addrs = AddrParams(d);
            foreach (ulong a in addrs) { DumpDriver hit = Find(d, a); if (hit != null && !IsKernel(hit.Name)) { d.Suspect = hit.Name; hit.Hit = true; break; } }
            if (d.Suspect.Length == 0 && d.StackDrivers.Count > 0) d.Suspect = d.StackDrivers[0];
            d.Ok = true;
        } catch (Exception e) { d.Error = e.Message; }
        return d;
    }
    static ulong[] AddrParams(DumpInfo d) {
        List<ulong> a = new List<ulong>();
        if (d.ExceptionAddress != 0) a.Add(d.ExceptionAddress);
        switch (d.BugCheck) {
            case 0x0A: case 0xD1: a.Add(d.Params[3]); break;                    // IRQL_NOT_LESS_OR_EQUAL, DRIVER_IRQL…：参数 4 是出事地址
            case 0x1E: case 0x7E: case 0x8E: case 0x3B: a.Add(d.Params[1]); break;   // 异常类：参数 2 是出事地址
            case 0x50: case 0xC5: a.Add(d.Params[3]); break;                    // PAGE_FAULT_IN_NONPAGED_AREA：参数 4
            case 0xC4: a.Add(d.Params[1]); break;
            case 0x139: a.Add(d.Params[1]); break;
            case 0xC2: a.Add(d.Params[2]); break;
        }
        return a.ToArray();
    }
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
}
public class DumpRow {
    public string When { get; set; }
    public string Code { get; set; }
    public string Suspect { get; set; }
    public string Detail { get; set; }
    public string File { get; set; }
    string _fg; public string SuspectBrush { get { return Theme.F(_fg); } set { _fg = value; } }
}
public class NoteRow { public string Head { get; set; } public string Body { get; set; } public string Path { get; set; } public bool HasPath { get; set; } }

