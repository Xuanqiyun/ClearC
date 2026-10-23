'@
if (-not ('DupFinder' -as [type])) { Add-Type -TypeDefinition $dupCode }
# 相似照片：把每张图缩成 9×8 灰度，相邻像素谁亮谁暗记成 64 位（dHash）；两张图的 64 位相差几位就是相似度。
# 不同分辨率、重新压缩、轻微裁剪的照片也认得出来；用 WPF 的解码器，只在 Windows 上编译
$script:photoCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
public class PhotoItem { public string Path; public long Size; public DateTime Modified; public ulong Hash; public int W, H; public bool Bad; public int Group = -1; public int Dist; }
public static class PhotoHash {
    public static volatile bool Cancel;
    public static long Seen, Hashed, Failed;
    public static volatile string Current = "";
    static readonly HashSet<string> skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "$Recycle.Bin", "System Volume Information", "Program Files", "Program Files (x86)", "ProgramData", "Windows", "AppData", "WindowsApps", "Windows.old",
        "$WINDOWS.~BT", "$WINDOWS.~WS", "Recovery", "node_modules", ".git", ".svn", "site-packages", "__pycache__", ".venv", "venv", ".conda", "anaconda3", "miniconda3",
        ".cache", ".cargo", ".gradle", ".m2", ".nuget", ".npm", "steamapps", "SteamLibrary", "Thumbnails", ".thumbnails" };
    public static readonly HashSet<string> Exts = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".webp", ".heic", ".heif", ".jfif" };
    // 列出要看的照片（跳过系统和程序目录、链接）
    public static List<PhotoItem> Scan(string[] roots, long min, long max, int limit) {
        List<PhotoItem> list = new List<PhotoItem>();
        Seen = 0; Hashed = 0; Failed = 0; Cancel = false;
        Stack<string> st = new Stack<string>();
        HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string r in roots) {
            string rr; try { rr = Path.GetFullPath(r).TrimEnd('\\'); if ((File.GetAttributes(rr) & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; }
            st.Push(rr);
        }
        while (st.Count > 0 && !Cancel) {
            string d = st.Pop(); Current = d;
            if (!seen.Add(d)) continue;   // 同一个文件夹只看一次（一个根在另一个根里面时）
            IEnumerable<string> dirs = null, files = null;
            try { dirs = Directory.EnumerateDirectories(d); files = Directory.EnumerateFiles(d); } catch { continue; }
            try { foreach (string s in dirs) { string n = Path.GetFileName(s); if (skip.Contains(n)) continue; try { if ((File.GetAttributes(s) & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; } st.Push(s); } } catch { }
            try {
                foreach (string f in files) {
                    if (!Exts.Contains(Path.GetExtension(f))) continue;
                    FileInfo fi; try { fi = new FileInfo(f); } catch { continue; }
                    if (fi.Length < min || (max > 0 && fi.Length > max)) continue;
                    // 只在云端的占位文件（OneDrive 等）：读它会触发下载，跳过
                    if ((((int)fi.Attributes) & (0x1000 | 0x40000 | 0x400000)) != 0) continue;
                    Seen++;
                    PhotoItem p = new PhotoItem(); p.Path = f; p.Size = fi.Length; p.Modified = fi.LastWriteTime; list.Add(p);
                    if (list.Count >= limit) { Cancel = true; break; }
                }
            } catch { }
        }
        return list;
    }
    public static void HashAll(List<PhotoItem> list) {
        foreach (PhotoItem p in list) {
            if (Cancel) break;
            Current = p.Path;
            try { int w, h; p.Hash = Hash(p.Path, out w, out h); p.W = w; p.H = h; Hashed++; } catch { p.Bad = true; Failed++; }
        }
    }
    public static ulong Hash(string path, out int w, out int h) {
        w = 0; h = 0;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
            BitmapDecoder dec = BitmapDecoder.Create(fs, BitmapCreateOptions.IgnoreColorProfile | BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            BitmapFrame fr = dec.Frames[0]; w = fr.PixelWidth; h = fr.PixelHeight;
        }
        // JPEG 解码时就按 1/8 缩小，大照片快很多；再缩到 9×8 取灰度
        BitmapImage bi = new BitmapImage();
        bi.BeginInit(); bi.UriSource = new Uri(path); bi.DecodePixelWidth = 36; bi.CacheOption = BitmapCacheOption.OnLoad; bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile; bi.EndInit(); bi.Freeze();
        TransformedBitmap tb = new TransformedBitmap(bi, new ScaleTransform(9.0 / bi.PixelWidth, 8.0 / bi.PixelHeight)); tb.Freeze();
        FormatConvertedBitmap g = new FormatConvertedBitmap(tb, PixelFormats.Gray8, null, 0); g.Freeze();
        int gw = g.PixelWidth, gh = g.PixelHeight;
        byte[] px = new byte[gw * gh]; g.CopyPixels(px, gw, 0);
        ulong hash = 0;
        for (int y = 0; y < 8; y++) {
            int yy = Math.Min(gh - 1, y * gh / 8);
            for (int x = 0; x < 8; x++) {
                int x0 = Math.Min(gw - 1, x * gw / 9), x1 = Math.Min(gw - 1, (x + 1) * gw / 9);
                hash = (hash << 1) | (px[yy * gw + x0] < px[yy * gw + x1] ? 1UL : 0UL);
            }
        }
        return hash;
    }
    public static int Dist(ulong a, ulong b) { ulong x = a ^ b; int n = 0; while (x != 0) { x &= x - 1; n++; } return n; }
    // 分组：相差不超过 maxDist 位的放一组。先按哈希的 k 段分桶（相差 d 位的两个哈希，k > d 时至少有一段完全相同），只比同桶的
    public static int Group(List<PhotoItem> list, int maxDist) {
        int n = list.Count; int[] parent = new int[n]; for (int i = 0; i < n; i++) parent[i] = i;
        int k = maxDist + 1; if (k > 16) k = 16;
        int bits = 64 / k;
        for (int c = 0; c < k; c++) {
            Dictionary<ulong, List<int>> bucket = new Dictionary<ulong, List<int>>();
            int shift = c * bits; int width = (c == k - 1) ? 64 - shift : bits;
            ulong mask = width >= 64 ? ulong.MaxValue : ((1UL << width) - 1);
            for (int i = 0; i < n; i++) {
                if (list[i].Bad) continue;
                ulong key = (list[i].Hash >> shift) & mask;
                List<int> l; if (!bucket.TryGetValue(key, out l)) { l = new List<int>(); bucket[key] = l; }
                l.Add(i);
            }
            foreach (List<int> l in bucket.Values) {
                if (l.Count < 2 || l.Count > 5000) continue;
                for (int a = 0; a < l.Count; a++) for (int b = a + 1; b < l.Count; b++) {
                    if (Dist(list[l[a]].Hash, list[l[b]].Hash) <= maxDist) Union(parent, l[a], l[b]);
                }
            }
        }
        Dictionary<int, int> id = new Dictionary<int, int>(); int groups = 0;
        for (int i = 0; i < n; i++) { if (list[i].Bad) continue; int r = Find(parent, i); int g; if (!id.TryGetValue(r, out g)) { g = groups++; id[r] = g; } list[i].Group = g; }
        return groups;
    }
    static int Find(int[] p, int i) { while (p[i] != i) { p[i] = p[p[i]]; i = p[i]; } return i; }
    static void Union(int[] p, int a, int b) { a = Find(p, a); b = Find(p, b); if (a != b) p[b] = a; }
}
'@
if (-not ('PhotoHash' -as [type])) { try { Add-Type -TypeDefinition $script:photoCode -ReferencedAssemblies PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop } catch { Write-LogFile ('photo hash: ' + $_.Exception.Message) } }

$script:tPrep = $script:startClock.Elapsed.TotalSeconds

# ============================================================
# 引擎：清理项目录、测量、删除、搬家。主线程和后台线程都会加载这一段。
# ============================================================
$engine = @'
