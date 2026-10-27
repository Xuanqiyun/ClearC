// ==================== 核心规则：路径规则、搬家进度的状态机（往 C# 迁的第一步） ====================
// 不碰磁盘、不依赖 PowerShell 的纯函数：PowerShell 的引擎调用它们，以后的 C# 代码也用同一份；测试把所有组合都试一遍。
// 比较一律不分大小写，和 PowerShell 的 -eq 一样
namespace ClearCCore {
    public static class PathRules {
        // 交给 cmd 的路径不能带 % 和引号：cmd 会展开 %名字%，引号会把参数截断（和以前一样，空的算可以）
        public static bool CmdPathOk(string p) {
            if (p == null) return true;
            return p.IndexOf('%') < 0 && p.IndexOf('"') < 0;
        }
        // full 是不是 root 本身，或者在 root 下面。C:\WindowsApps 不在 C:\Windows 下面；末尾的 \ 不算
        public static bool IsUnder(string full, string root) {
            if (string.IsNullOrEmpty(full) || string.IsNullOrEmpty(root)) return false;
            string f = full.TrimEnd('\\'), r = root.TrimEnd('\\');
            if (r.Length == 0 || f.Length == 0) return false;
            if (string.Equals(f, r, StringComparison.OrdinalIgnoreCase)) return true;
            return f.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase);
        }
        // 任何一块盘根下的这些文件夹：回收站（所有用户的）、还原点、恢复分区的东西、启动文件
        static readonly string[] driveSys = { "$Recycle.Bin", "System Volume Information", "Recovery", "EFI", "Boot", "Config.Msi", "$WinREAgent" };
        public static bool IsDriveSystemFolder(string full) {
            if (full == null || full.Length < 4 || full[1] != ':' || full[2] != '\\') return false;
            char c = full[0];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
            string rest = full.Substring(3);
            int k = rest.IndexOf('\\');
            string first = k < 0 ? rest : rest.Substring(0, k);
            foreach (string s in driveSys) if (string.Equals(first, s, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }
    // 规范化完整路径后做摘要；不同层级的下划线不能造成记录名碰撞。
    public static class JournalIdentity {
        public static string Normalize(string path) {
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("Missing journal source");
            return System.IO.Path.GetFullPath(path).Replace('/', '\\').TrimEnd('\\').ToUpperInvariant();
        }
        public static string Key(string path) {
            using (var hash = System.Security.Cryptography.SHA256.Create()) {
                return BitConverter.ToString(hash.ComputeHash(System.Text.Encoding.UTF8.GetBytes(Normalize(path)))).Replace("-", "").ToLowerInvariant();
            }
        }
    }
    // 搬家进度记录里写的那一步，和磁盘上实际的样子对一下：写记录前一刻断电时，实际可能已经多做了一步。
    // kind：move 搬走 / back 搬回；place：C 盘那个位置现在是 none 不在、link 链接、empty 空文件夹、data 有内容的真文件夹；
    // bakThere：C 盘上改了名的旧文件夹（搬回时是复制回来的临时文件夹）在不在；dstThere：目标盘上那份在不在
    public static class MoveSteps {
        static bool Is(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
        public static string Reconcile(string kind, string step, string place, bool bakThere, bool dstThere) {
            string s = step ?? "";
            bool gone = Is(place, "none") || Is(place, "empty");
            if (Is(kind, "move")) {
                if (Is(s, "copying") && bakThere && gone) s = "renamed";
                if (Is(s, "renamed") && Is(place, "link")) s = "linked";
                if ((Is(s, "linked") || Is(s, "cleanup")) && !bakThere && Is(place, "link")) s = "done";
            } else {
                if (Is(s, "copying") && bakThere && gone) s = "unlinked";
                if (Is(s, "unlinked") && !bakThere && Is(place, "data")) s = "swapped";
                if ((Is(s, "swapped") || Is(s, "cleanup")) && !dstThere) s = "done";
            }
            return s;
        }
    }
}
