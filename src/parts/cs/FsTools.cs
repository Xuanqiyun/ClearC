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

