// ==================== 空间地图：一棵按大小汇总的文件夹树 ====================
// NTFS 上直接读文件表（快），读不了就多线程逐个文件夹扫描
public class DmNode {
    public string Name;
    public DmNode Parent;
    public long Size, Own, Files, OwnFiles, LastWrite;
    // 读文件表时才有：实际占的盘、其中有不止一个名字的文件（硬链接，盘上只有一份，删掉这一个名字不腾空间）
    public long Disk, OwnDisk, Shared, OwnShared;
    public bool HasDisk;                              // 只在根上：这棵树是读文件表得来的，上面几项有数
    public long UniqueSize, UniqueDisk, Linked, MftBytes;   // 只在根上：每个文件只算一次的合计、有硬链接的文件、文件表（$MFT）本身多大
    public bool IsLink, Denied, Gone;
    public bool Cloud;                                // 带重解析点但不是链接的文件夹（OneDrive 等云端文件夹）
    public List<DmNode> Kids = new List<DmNode>();
    public List<DmFile> Big;                          // 只在根上：扫描时记下的 1 MB 以上的文件
    public string FullPath() {
        List<string> parts = new List<string>();
        for (DmNode n = this; n != null; n = n.Parent) parts.Add(n.Name);
        parts.Reverse();
        string p = parts[0];
        for (int i = 1; i < parts.Count; i++) p = (p.EndsWith("\\") || p.EndsWith("/")) ? p + parts[i] : p + System.IO.Path.DirectorySeparatorChar + parts[i];
        return p;
    }
    public int Depth() { int d = 0; for (DmNode n = Parent; n != null; n = n.Parent) d++; return d; }
}
// 扫描时记下的文件（1 MB 以上）。只存所在文件夹和文件名，完整路径用到时再拼，省内存
public class DmFile {
    public DmNode Dir; public string Name; public long Size; public DateTime Modified;
    public long Disk = -1; public bool Shared;        // 实际占用（-1 不知道）；有不止一个名字（硬链接）
    public string Path { get { string d = Dir.FullPath(); return (d.EndsWith("\\") || d.EndsWith("/")) ? d + Name : d + System.IO.Path.DirectorySeparatorChar + Name; } }
}
public class DmFind { public List<DmFile> Files = new List<DmFile>(); public long Count, Bytes; }
public class DmEntry { public string Name, Path; public long Size; public DateTime Modified; public long Disk = -1; }

public static class DiskMap {
    public static volatile bool Cancel;
    public static long FilesSeen, DirsSeen, BytesSeen;
    public static volatile string Current = "";
    public static List<DmFile> BigFiles = new List<DmFile>();   // 空间地图现在显示的那棵树的大文件
    public static string LastMethod = "", LastNote = "";        // mft / mft-usn / mft-partial / walk；没能读文件表的原因
    public static long LastMs, LastChanged, LastFailed;
    static int pending;

    public const long BigMin = 1L * 1024 * 1024;   // 「找文件」只在这些文件里找
    static bool Win { get { return System.IO.Path.DirectorySeparatorChar == '\\'; } }

    static readonly object cacheLock = new object(), mftGate = new object();
    static readonly Dictionary<string, MftIndex> mftIdx = new Dictionary<string, MftIndex>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, string> mftBroken = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, DmNode> walkTree = new Dictionary<string, DmNode>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, DateTime> walkAt = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);

    public static void Use(DmNode root) { BigFiles = (root != null && root.Big != null) ? root.Big : new List<DmFile>(); }
    // 本工具删过、搬过东西以后，逐个扫描得到的旧结果不再拿来用（读文件表的结果靠变更日志自己更新）
    public static void Invalidate() { lock (cacheLock) { walkTree.Clear(); walkAt.Clear(); } }

    // 拿到一块盘的文件夹树。
    // allowWalk：读不了文件表时，要不要逐个文件夹扫一遍（慢）；fresh：逐个扫描的结果要不要重新扫（不用 10 分钟内的旧结果）
    public static DmNode GetTree(string root, int threads, bool allowWalk, bool fresh) {
        Stopwatch sw = Stopwatch.StartNew();
        LastNote = ""; LastChanged = 0; LastFailed = 0; Mft.RecordsDone = 0; Mft.RecordsTotal = 0;
        string key = root.Substring(0, 1);
        try { return GetTree2(root, key, threads, allowWalk, fresh, sw); } finally { Phase = ""; }
    }
    public static volatile string Phase = "";            // 正在做什么：mft 读文件表  walk 逐个文件夹扫描
    static DmNode GetTree2(string root, string key, int threads, bool allowWalk, bool fresh, Stopwatch sw) {
        if (MftAllowed(root)) {
            Phase = "mft";
            try {
                DmNode t; lock (mftGate) t = TreeFromMft(root, key);   // 同一时间只有一处在读/更新文件表
                if (t != null) { LastMs = sw.ElapsedMilliseconds; return t; }
            } catch (Exception e) {
                string why = e.GetType().Name + ": " + e.Message;
                lock (cacheLock) { mftBroken[key] = why; mftIdx.Remove(key); }
                LastNote = why;
            }
            if (Cancel) { LastMs = sw.ElapsedMilliseconds; return null; }
        } else {
            string b; lock (cacheLock) { if (mftBroken.TryGetValue(key, out b)) LastNote = b; }
        }
        if (!fresh) {
            lock (cacheLock) {
                DmNode w; DateTime at;
                if (walkTree.TryGetValue(key, out w) && walkAt.TryGetValue(key, out at) && (DateTime.Now - at).TotalMinutes < 10) { LastMethod = "walk-cache"; LastMs = sw.ElapsedMilliseconds; return w; }
            }
        }
        if (!allowWalk) { LastMs = sw.ElapsedMilliseconds; return null; }
        Phase = "walk";
        DmNode r = Scan(root, threads);
        LastMethod = "walk";
        if (!Cancel) lock (cacheLock) { walkTree[key] = r; walkAt[key] = DateTime.Now; }
        LastMs = sw.ElapsedMilliseconds;
        return r;
    }

    public static volatile bool MftOff;              // 用户在设置里关掉了「直接读文件表」
    static bool MftAllowed(string root) {
        if (MftOff || !Win || root == null || root.Length < 2 || root[1] != ':' || root.TrimEnd('\\').Length != 2) return false;   // 只认整块盘
        lock (cacheLock) { if (mftBroken.ContainsKey(root.Substring(0, 1))) return false; }
        try { return new DriveInfo(root.Substring(0, 2) + "\\").DriveFormat == "NTFS"; } catch { return false; }
    }

    static DmNode TreeFromMft(string root, string key) {
        string r0 = root.Substring(0, 2) + "\\";
        WinVolume v = new WinVolume(r0);
        try {
            int fullReads = 0;
            bool noCache = false;
            for (int attempt = 0; attempt < 3; attempt++) {
                MftIndex ix = null;
                lock (cacheLock) { mftIdx.TryGetValue(key, out ix); }
                bool inc = false;
                // 同一次打开程序里扫过：按变更日志只重读改动过的记录（还开着的文件每次都重读）
                if (ix != null && ix.HasJournal && attempt == 0) try {
                    ulong id; long first, next;
                    if (Mft.QueryJournal(v, out id, out first, out next) && id == ix.JournalId && ix.NextUsn >= first) {
                        HashSet<int> frns = new HashSet<int>();
                        if (Mft.ReadJournal(v, id, ix.NextUsn, next, frns, 300000, 0, ix.OpenFiles)) {
                            foreach (int f in ix.OpenFiles) frns.Add(f);
                            long now = DateTime.UtcNow.Ticks;
                            foreach (KeyValuePair<int, long> kv in new List<KeyValuePair<int, long>>(ix.Recent)) {
                                if (now - kv.Value < 120L * 10000000) frns.Add(kv.Key); else ix.Recent.Remove(kv.Key);
                            }
                            MftIndex head = Mft.Open(v, r0);
                            if (head.RecordSize == ix.RecordSize) {
                                ix.Runs = head.Runs; ix.MftBytes = head.MftBytes; ix.Grow(head.Count);
                                if (Mft.Reread(v, ix, frns)) { ix.NextUsn = next; ix.At = DateTime.Now; inc = true; LastChanged = frns.Count; }
                            }
                        }
                    }
                } catch { inc = false; }                      // 按日志更新出了问题：整份重读
                if (!inc) {
                    if (fullReads >= 2) break;
                    fullReads++;
                    Current = r0;
                    ulong id; long first, next;
                    bool hj = Mft.QueryJournal(v, out id, out first, out next);   // 读之前先记下日志位置，读的过程中的改动下次会补上
                    long t0 = DateTime.UtcNow.ToFileTimeUtc();
                    try { ix = Mft.Open(v, r0); }
                    catch (InvalidDataException) { Thread.Sleep(300); ix = Mft.Open(v, r0); }   // 可能正好赶上 MFT 变长，再试一次
                    Mft.ReadAll(v, ix, delegate { return Cancel; });
                    if (!ix.Partial) { Mft.RetryBad(v, ix); Mft.FixStaleExt(v, ix); }
                    if (ix.Bad > ix.Count / 100 + 100) throw new InvalidDataException("bad records: " + ix.Bad);
                    ix.HasJournal = hj; ix.JournalId = id; ix.NextUsn = next; ix.At = DateTime.Now;
                    if (hj && !ix.Partial && !CatchUp(v, ix, t0)) noCache = true;
                }
                List<DmFile> big; long files, dirs, orphans;
                DmNode t = Mft.BuildTree(ix, out big, out files, out dirs, out orphans);
                Finish(t, big);
                FilesSeen = files; DirsSeen = dirs; BytesSeen = t.Size; LastFailed = ix.Failed.Count;
                if (ix.Partial) { lock (cacheLock) mftIdx.Remove(key); LastMethod = "mft-partial"; return t; }
                string bad = orphans > Math.Max(500, files / 200) ? "files without a folder: " + orphans : Verify(t);
                if (bad != null) {
                    lock (cacheLock) mftIdx.Remove(key);
                    if (inc || fullReads < 2) continue;        // 对不上：整份重读一次再核对（可能只是核对的那一刻正好在变）
                    throw new InvalidDataException("check: " + bad);
                }
                if (noCache) { lock (cacheLock) mftIdx.Remove(key); LastMethod = "mft"; return t; }      // 补读最近改动时出了问题：这次的结果照用，下次整份重读
                lock (cacheLock) {
                    // 留着系统盘和最近一块别的盘的文件表（下次按变更日志更新），再多就太占内存
                    string sys = (Environment.GetEnvironmentVariable("SystemDrive") ?? "C:").Substring(0, 1);
                    if (!string.Equals(key, sys, StringComparison.OrdinalIgnoreCase))
                        foreach (string k in new List<string>(mftIdx.Keys)) if (!string.Equals(k, sys, StringComparison.OrdinalIgnoreCase)) mftIdx.Remove(k);
                    mftIdx[key] = ix;
                }
                LastMethod = inc ? "mft-usn" : "mft";
                return t;
            }
            return null;
        } finally { v.Close(); }
    }

    // 盘上的文件表可能还没写进刚才几十秒的改动（还在内存里）：读完后按变更日志，把这段时间改过的记录经文件系统重读一遍。
    // 顺便从日志里找出还开着的文件
    // 返回 false：出了问题，这份表不留着用
    static bool CatchUp(WinVolume v, MftIndex ix, long t0) {
        try {
            ulong id; long first, now;
            if (!Mft.QueryJournal(v, out id, out first, out now) || id != ix.JournalId) return true;
            if (now - first > (64L << 20)) return true;   // 日志太长，整份读一遍不划算；最近的改动下次扫描时补上
            HashSet<int> frns = new HashSet<int>();
            HashSet<int> open = new HashSet<int>();
            if (!Mft.ReadJournal(v, id, first, now, frns, 300000, t0 - 120L * 10000000, open)) return true;
            ix.OpenFiles = open;
            foreach (int f in open) frns.Add(f);
            MftIndex head = Mft.Open(v, ix.Root);
            if (head.RecordSize != ix.RecordSize) return false;
            ix.Runs = head.Runs; ix.MftBytes = head.MftBytes; ix.Grow(head.Count);
            if (!Mft.Reread(v, ix, frns)) return false;
            if (now > ix.NextUsn) ix.NextUsn = now;
            return true;
        } catch { return false; }
    }

    // 和直接列目录比一比：根目录下的文件夹和根目录自己的文件个数，再抽查 20 个深一点的文件夹自己的文件个数和大小
    static string Verify(DmNode root) {
        if (!Win) return null;
        string err = CompareDir(root, root.Name, true);
        if (err != null && err.Length > 0) return err;
        List<DmNode> pool = new List<DmNode>();
        Queue<KeyValuePair<DmNode, int>> q = new Queue<KeyValuePair<DmNode, int>>();
        q.Enqueue(new KeyValuePair<DmNode, int>(root, 0));
        while (q.Count > 0 && pool.Count < 20000) {
            KeyValuePair<DmNode, int> kv = q.Dequeue();
            if (kv.Value > 0) pool.Add(kv.Key);
            // 云端文件夹不抽查：列它的内容会去问 OneDrive，没开的话可能卡住
            if (kv.Value < 6) foreach (DmNode k in kv.Key.Kids) if (!k.IsLink && !k.Cloud) q.Enqueue(new KeyValuePair<DmNode, int>(k, kv.Value + 1));
        }
        int step = Math.Max(1, pool.Count / 20), done = 0, bad = 0; string firstBad = null;
        for (int i = 0; i < pool.Count && done < 20; i += step) {
            err = CompareDir(pool[i], pool[i].FullPath(), false);
            if (err == null) { done++; continue; }
            if (err.Length == 0) continue;                // 打不开：没法核对，不算
            done++; bad++; if (firstBad == null) firstBad = err;
        }
        return bad > 3 ? firstBad + " (" + bad + "/" + done + ")" : null;
    }
    // null 对得上  "" 打不开、没法核对  其他：哪里对不上
    static string CompareDir(DmNode node, string path, bool isRoot) {
        DirReader r = new DirReader();
        try {
            if (!r.Open(path)) return "";
            long files = 0, bytes = 0;
            HashSet<string> dirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (r.Next()) { if (r.IsDir) dirs.Add(r.Name); else { files++; bytes += r.Size; } }
            if (Math.Abs(files - node.OwnFiles) > Math.Max(5, files / 50)) return "files in " + path + ": " + files + " / " + node.OwnFiles;
            if (!isRoot && Math.Abs(bytes - node.Own) > Math.Max(256L << 20, bytes / 20)) return "bytes in " + path + ": " + bytes + " / " + node.Own;
            HashSet<string> mine = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (DmNode k in node.Kids) mine.Add(k.Name);
            int miss = 0;
            foreach (string d in dirs) if (!mine.Contains(d)) miss++;
            foreach (string d in mine) if (!dirs.Contains(d)) miss++;
            if (miss > Math.Max(3, dirs.Count / 50)) return "folders in " + path + ": " + miss + " differ";
            return null;
        } finally { r.Free(); }
    }

    // 测试用：读一个 NTFS 镜像文件
    public static MftIndex TestIndex;
    public static DmNode ScanImage(string image, string rootName) {
        FileVolume v = new FileVolume(image);
        try {
            MftIndex ix = Mft.Open(v, rootName);
            Mft.ReadAll(v, ix, null);
            Mft.RetryBad(v, ix); Mft.FixStaleExt(v, ix);
            TestIndex = ix;
            List<DmFile> big; long f, d;
            DmNode t = Mft.BuildTree(ix, out big, out f, out d);
            Finish(t, big);
            return t;
        } finally { v.Close(); }
    }
    public static DmNode RereadImage(string image, MftIndex ix, int[] frns) {
        FileVolume v = new FileVolume(image);
        try {
            MftIndex head = Mft.Open(v, ix.Root);
            ix.Runs = head.Runs; ix.MftBytes = head.MftBytes; ix.Grow(head.Count);
            if (!Mft.Reread(v, ix, frns)) return null;
            List<DmFile> big; long f, d;
            DmNode t = Mft.BuildTree(ix, out big, out f, out d);
            Finish(t, big);
            return t;
        } finally { v.Close(); }
    }

    // ---------- 逐个文件夹扫描（多线程） ----------
    public static DmNode Scan(string root, int threads) {
        FilesSeen = 0; DirsSeen = 0; BytesSeen = 0; Current = "";
        string r = root;
        if (Win) { r = root.TrimEnd('\\') + "\\"; } else if (r.Length > 1) { r = r.TrimEnd('/'); }
        DmNode top = new DmNode(); top.Name = r;
        ConcurrentStack<DmNode> work = new ConcurrentStack<DmNode>();
        List<DmFile> big = new List<DmFile>();
        object bigLock = new object();
        pending = 1; work.Push(top);
        if (threads < 1) threads = 1;
        Thread[] ts = new Thread[threads];
        for (int t = 0; t < threads; t++) {
            ts[t] = new Thread(() => {
                List<DmFile> mine = new List<DmFile>();
                DirReader rd = new DirReader();
                try {
                    while (true) {
                        DmNode n;
                        if (work.TryPop(out n)) {
                            try { if (!Cancel) Enumerate(n, work, mine, rd); } catch { n.Denied = true; }
                            if (Interlocked.Decrement(ref pending) == 0) break;
                        } else {
                            if (Volatile.Read(ref pending) == 0) break;
                            Thread.Sleep(1);
                        }
                    }
                } finally { rd.Free(); }
                lock (bigLock) { big.AddRange(mine); }
            });
            ts[t].IsBackground = true; ts[t].Start();
        }
        foreach (Thread th in ts) th.Join();
        Finish(top, big);
        return top;
    }

    static void Enumerate(DmNode n, ConcurrentStack<DmNode> work, List<DmFile> big, DirReader r) {
        string dir = n.FullPath();
        Current = dir;
        if (!r.Open(dir)) { n.Denied = true; return; }
        long files = 0, bytes = 0;
        try {
            while (!Cancel && r.Next()) {
                if (r.IsDir) {
                    DmNode c = new DmNode(); c.Name = r.Name; c.Parent = n;
                    n.Kids.Add(c);
                    if (r.IsLink) { c.IsLink = true; continue; }
                    Interlocked.Increment(ref pending); Interlocked.Increment(ref DirsSeen);
                    work.Push(c);
                } else {
                    long sz = r.Size, wt = r.Write;
                    n.Own += sz; n.OwnFiles++;
                    if (wt > n.LastWrite) n.LastWrite = wt;
                    files++; bytes += sz;
                    if (sz >= BigMin) { DmFile f = new DmFile(); f.Dir = n; f.Name = r.Name; f.Size = sz; try { f.Modified = DateTime.FromFileTime(wt); } catch { } big.Add(f); }
                }
            }
        } finally { r.Close(); Interlocked.Add(ref FilesSeen, files); Interlocked.Add(ref BytesSeen, bytes); }
    }

    // 自下而上汇总大小，每一层按大小从大到小排；大文件按大小排好挂在根上
    public static void Finish(DmNode top, List<DmFile> big) {
        List<DmNode> order = new List<DmNode>();
        Stack<DmNode> st = new Stack<DmNode>(); st.Push(top);
        while (st.Count > 0) { DmNode n = st.Pop(); order.Add(n); foreach (DmNode k in n.Kids) st.Push(k); }
        for (int i = order.Count - 1; i >= 0; i--) {
            DmNode n = order[i];
            long s = n.Own, f = n.OwnFiles, w = n.LastWrite, dk = n.OwnDisk, sh = n.OwnShared;
            foreach (DmNode k in n.Kids) { s += k.Size; f += k.Files; dk += k.Disk; sh += k.Shared; if (k.LastWrite > w) w = k.LastWrite; }
            n.Size = s; n.Files = f; n.LastWrite = w; n.Disk = dk; n.Shared = sh;
            n.Kids.Sort((a, b) => b.Size.CompareTo(a.Size));
        }
        big.Sort((a, b) => b.Size.CompareTo(a.Size));
        top.Big = big;
    }

    // 删掉一个文件夹后，从树上摘掉并把大小从上面每一层减掉
    public static void Detach(DmNode n) {
        DmNode p = n.Parent; if (p == null) return;
        p.Kids.Remove(n); n.Gone = true;
        for (DmNode a = p; a != null; a = a.Parent) { a.Size -= n.Size; a.Files -= n.Files; a.Disk -= n.Disk; a.Shared -= n.Shared; }
    }
    // 删掉某一层里的一个文件（disk：实际占用，-1 不知道时按文件大小算）
    public static void DropFile(DmNode dir, long bytes) { DropFile(dir, bytes, -1); }
    public static void DropFile(DmNode dir, long bytes, long disk) {
        if (dir == null) return;
        long dk = Math.Max(0, Math.Min(disk >= 0 ? disk : bytes, dir.OwnDisk));
        dir.Own -= bytes; dir.OwnFiles--; dir.OwnDisk -= dk;
        for (DmNode a = dir; a != null; a = a.Parent) { a.Size -= bytes; a.Files--; a.Disk -= dk; }
    }
    // 按路径找节点（大小写不敏感）
    public static DmNode Find(DmNode root, string path) {
        if (root == null || string.IsNullOrEmpty(path)) return null;
        string rp = root.FullPath().TrimEnd('\\', '/');
        string p = path.TrimEnd('\\', '/');
        if (string.Equals(rp, p, StringComparison.OrdinalIgnoreCase)) return root;
        if (!p.StartsWith(rp, StringComparison.OrdinalIgnoreCase)) return null;
        string rest = p.Substring(rp.Length).TrimStart('\\', '/');
        DmNode cur = root;
        foreach (string part in rest.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries)) {
            DmNode next = null;
            foreach (DmNode k in cur.Kids) if (string.Equals(k.Name, part, StringComparison.OrdinalIgnoreCase)) { next = k; break; }
            if (next == null) return null;
            cur = next;
        }
        return cur;
    }
    // 找文件：在扫描时记下的文件里按条件筛选。BigFiles 已按大小从大到小排好：
    // 取前 max 个（确认文件还在），并算出符合条件的一共有几个、多大
    public static DmFind FindFiles(long minSize, DateTime olderThan, string exts, string name, DmNode under, int max) {
        return FindFilesIn(minSize, olderThan, exts, name, under == null ? null : new DmNode[] { under }, max);
    }
    // unders：只在这几个文件夹里找（null 表示整块盘）
    public static DmFind FindFilesIn(long minSize, DateTime olderThan, string exts, string name, DmNode[] unders, int max) {
        HashSet<DmNode> within = unders == null ? null : new HashSet<DmNode>(unders);
        DmFind r = new DmFind();
        Dictionary<string, bool> ex = null;
        if (!string.IsNullOrEmpty(exts)) {
            ex = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (string e in exts.Split(new char[] { ' ', ';', ',' }, StringSplitOptions.RemoveEmptyEntries)) ex[e.StartsWith(".") ? e : "." + e] = true;
        }
        Regex rx = null; string sub = null;
        if (name != null) name = name.Trim();
        if (!string.IsNullOrEmpty(name)) {
            if (name.IndexOf('*') >= 0 || name.IndexOf('?') >= 0)
                rx = new Regex("^" + Regex.Escape(name).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            else sub = name;
        }
        foreach (DmFile f in BigFiles) {
            if (f.Size < minSize) break;
            if (f.Modified >= olderThan) continue;
            if (ex != null) { int dot = f.Name.LastIndexOf('.'); if (dot < 0 || !ex.ContainsKey(f.Name.Substring(dot))) continue; }
            if (sub != null && f.Name.IndexOf(sub, StringComparison.OrdinalIgnoreCase) < 0) continue;
            if (rx != null && !rx.IsMatch(f.Name)) continue;
            bool gone = false, inside = (within == null);
            for (DmNode a = f.Dir; a != null; a = a.Parent) { if (a.Gone) { gone = true; break; } if (!inside && within.Contains(a)) inside = true; }
            if (gone || !inside) continue;
            if (r.Files.Count < max) {
                if (!FileThere(f.Path)) continue;
                r.Files.Add(f);
            }
            r.Count++; r.Bytes += f.Size;
        }
        return r;
    }
    static bool FileThere(string p) {
        try {
            if (File.Exists(p)) return true;
            if (Win && p.Length >= 248 && !p.StartsWith("\\\\")) return File.Exists("\\\\?\\" + p);
        } catch { }
        return false;
    }
    // 按扩展名统计扫描时记下的文件（1 MB 以上）：扩展名 → { 个数, 字节 }
    public static Dictionary<string, long[]> ExtTotals() {
        Dictionary<string, long[]> r = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
        foreach (DmFile f in BigFiles) {
            bool gone = false;
            for (DmNode a = f.Dir; a != null; a = a.Parent) { if (a.Gone) { gone = true; break; } }
            if (gone) continue;
            int dot = f.Name.LastIndexOf('.');
            string e = dot >= 0 ? f.Name.Substring(dot) : "";
            long[] v;
            if (!r.TryGetValue(e, out v)) { v = new long[2]; r[e] = v; }
            v[0]++; v[1] += f.Size;
        }
        return r;
    }
    // 删掉一个文件后，从「找文件」的名单里去掉
    public static void ForgetFile(string path) {
        if (string.IsNullOrEmpty(path)) return;
        string nm = System.IO.Path.GetFileName(path);
        BigFiles.RemoveAll(f => string.Equals(f.Name, nm, StringComparison.OrdinalIgnoreCase) && string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase));
    }
    // 空间地图：一个文件夹里最大的几个文件（现场列，批量读目录）
    public static List<DmEntry> TopFiles(string dir, int max) {
        List<DmEntry> all = new List<DmEntry>();
        DirReader r = new DirReader();
        try {
            if (!r.Open(dir)) return all;
            string sep = (dir.EndsWith("\\") || dir.EndsWith("/")) ? "" : System.IO.Path.DirectorySeparatorChar.ToString();
            while (r.Next()) {
                if (r.IsDir) continue;
                DmEntry x = new DmEntry(); x.Name = r.Name; x.Path = dir + sep + r.Name; x.Size = r.Size; x.Disk = r.Alloc;
                try { x.Modified = DateTime.FromFileTime(r.Write); } catch { }
                all.Add(x);
            }
        } catch { } finally { r.Free(); }
        all.Sort((a, b) => b.Size.CompareTo(a.Size));
        if (all.Count > max) all.RemoveRange(max, all.Count - max);
        return all;
    }
    // 一个文件夹里最大的几个子文件夹（不改动原来的顺序）
    public static List<DmNode> TopKids(DmNode n, int max) {
        List<DmNode> k = new List<DmNode>(n.Kids);
        k.Sort((a, b) => b.Size.CompareTo(a.Size));
        if (k.Count > max) k.RemoveRange(max, k.Count - max);
        return k;
    }
    // 自检用：逐个扫描时打不开的文件夹个数
    public static long CountDenied(DmNode n) {
        long c = 0; Stack<DmNode> st = new Stack<DmNode>(); st.Push(n);
        while (st.Count > 0) { DmNode d = st.Pop(); if (d.Denied) c++; foreach (DmNode k in d.Kids) st.Push(k); }
        return c;
    }
    // 自检用：两棵树对不上的地方（按名字对应），差得最多的几处
    public static List<string> Diff(DmNode a, DmNode b, int max) {
        List<KeyValuePair<long, string>> found = new List<KeyValuePair<long, string>>();
        Stack<KeyValuePair<DmNode, DmNode>> st = new Stack<KeyValuePair<DmNode, DmNode>>();
        st.Push(new KeyValuePair<DmNode, DmNode>(a, b));
        int seen = 0;
        while (st.Count > 0 && seen < 2000000) {
            KeyValuePair<DmNode, DmNode> kv = st.Pop(); DmNode x = kv.Key, y = kv.Value; seen++;
            if (x.OwnFiles != y.OwnFiles || x.Own != y.Own)
                found.Add(new KeyValuePair<long, string>(Math.Abs(x.Own - y.Own) + Math.Abs(x.OwnFiles - y.OwnFiles), y.FullPath() + "  own files " + x.OwnFiles + " / " + y.OwnFiles + ", bytes " + x.Own + " / " + y.Own + (y.Denied ? " (walk: denied)" : "")));
            Dictionary<string, DmNode> yk = new Dictionary<string, DmNode>(StringComparer.OrdinalIgnoreCase);
            foreach (DmNode k in y.Kids) yk[k.Name] = k;
            foreach (DmNode k in x.Kids) {
                DmNode m;
                if (yk.TryGetValue(k.Name, out m)) { yk.Remove(k.Name); if (!k.IsLink && !m.IsLink) st.Push(new KeyValuePair<DmNode, DmNode>(k, m)); else if (k.IsLink != m.IsLink) found.Add(new KeyValuePair<long, string>(k.Size + m.Size + 1, m.FullPath() + "  link " + k.IsLink + " / " + m.IsLink)); }
                else found.Add(new KeyValuePair<long, string>(k.Size + 1, k.FullPath() + "  only in file table, " + k.Files + " files, " + k.Size + " bytes"));
            }
            foreach (DmNode m in yk.Values) found.Add(new KeyValuePair<long, string>(m.Size + 1, m.FullPath() + "  only in walk, " + m.Files + " files, " + m.Size + " bytes"));
        }
        found.Sort((p, q) => q.Key.CompareTo(p.Key));
        List<string> r = new List<string>();
        for (int i = 0; i < found.Count && i < max; i++) r.Add(found[i].Value);
        if (found.Count > max) r.Add("... " + (found.Count - max) + " more");
        return r;
    }
    // 快照：前几层里够大的文件夹，用来和下次扫描比较谁变大了
    public static List<string> Snapshot(DmNode root, int maxDepth, long minSize) {
        List<string> outp = new List<string>();
        Stack<KeyValuePair<DmNode, int>> st = new Stack<KeyValuePair<DmNode, int>>();
        st.Push(new KeyValuePair<DmNode, int>(root, 0));
        while (st.Count > 0) {
            KeyValuePair<DmNode, int> kv = st.Pop();
            if (kv.Key.Size < minSize) continue;
            outp.Add(kv.Key.FullPath() + "\t" + kv.Key.Size);
            if (kv.Value < maxDepth) foreach (DmNode k in kv.Key.Kids) if (!k.IsLink) st.Push(new KeyValuePair<DmNode, int>(k, kv.Value + 1));
        }
        return outp;
    }
}

