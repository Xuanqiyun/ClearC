// ==================== 界面文字翻译（PowerShell 启动时按语言设置填入；没有就原样返回中文） ====================
public static class L10n {
    public static System.Collections.Generic.Dictionary<string, string> Map;
    public static string T(string s) { string v; if (Map != null && s != null && Map.TryGetValue(s, out v)) return v; return s; }
}

// ==================== 各页面列表的一行 ====================
public class MapRow {
    public string Name { get; set; }
    public string Path { get; set; }
    public string SizeText { get; set; }
    public long Size { get; set; }
    public double Bar { get; set; }
    public string Pct { get; set; }
    public string Glyph { get; set; }
    string _glyph; public string GlyphBrush { get { return Theme.F(_glyph); } set { _glyph = value; } }
    public string Meta { get; set; }
    public bool IsDir { get; set; }
    public bool Locked { get; set; }
    public string LockTip { get; set; }
    public object Node { get; set; }
    public string When { get; set; }    // 导出用：最近修改时间
    public long FileCount { get; set; } // 导出用：文件夹里的文件个数
    public bool IsSummary { get; set; } // 「其余 N 项」那一行：不是真的文件或文件夹
    public long Disk { get; set; }      // 实际占用（-1 不知道）
    public bool Shared { get; set; }    // 有不止一个名字（硬链接）：删了这个名字不腾空间
    public string Kind { get; set; }    // dir / file / link / more / type（按类型统计的一行）
    public string Owner { get; set; }   // 找文件：所有者
}
public class AppRow : INotifyPropertyChanged {
    public string Name { get; set; }
    public string Publisher { get; set; }
    public string Version { get; set; }
    public string Date { get; set; }
    public string Location { get; set; }
    public string Uninstall { get; set; }
    public string Kind { get; set; }
    public string PackageName { get; set; }
    public string Icon { get; set; }
    private string _meta = ""; public string Meta { get { return _meta; } set { _meta = value; Raise("Meta"); } }
    private string _size = L10n.T("计算中…"); public string SizeText { get { return _size; } set { _size = value; Raise("SizeText"); } }
    public long Size { get; set; }
    public bool OnC { get; set; }
    public bool LocReg { get; set; }
    public bool CanMove { get; set; }
    // winget 查到的新版本（空 = 没有或还没查）
    private string _upg = ""; public string Upgrade { get { return _upg; } set { _upg = value; Raise("Upgrade"); Raise("HasUpgrade"); } }
    public string UpgradeId { get; set; }
    public bool HasUpgrade { get { return !string.IsNullOrEmpty(_upg); } }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
// 启动项、计划任务、右键菜单扩展：一行一个，能启用 / 禁用
public class StartRow : INotifyPropertyChanged {
    public string Kind { get; set; }        // startup / task / shellex
    public string Name { get; set; }
    public string Meta { get; set; }
    public string Detail { get; set; }      // 命令、文件或 dll 的路径
    public string Open { get; set; }        // 「打开位置」要打开的路径（空 = 不显示按钮）
    public string Key1 { get; set; }        // startup: StartupApproved 的键   task: 任务路径   shellex: CLSID
    public string Key2 { get; set; }        // startup: 值名   task: 任务名
    public bool Ours { get; set; }          // 本工具自己建的任务
    private bool _on = true;
    public bool Enabled { get { return _on; } set { _on = value; Raise("Enabled"); Raise("StatusText"); Raise("StatusBrush"); Raise("ToggleText"); } }
    public string Size { get; set; }
    public string StatusText { get { if (Kind == "leftover") return Size ?? ""; return _on ? L10n.T("已启用") : L10n.T("已禁用"); } }
    public string StatusBrush { get { return Theme.F(Kind == "leftover" ? "#1D1D1F" : (_on ? "#248A3D" : "#86868B")); } }
    public string ToggleText { get { if (Kind == "leftover") return L10n.T("移到回收站"); return _on ? L10n.T("禁用") : L10n.T("启用"); } }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
public class MoveRow : INotifyPropertyChanged {
    public string Name { get; set; }
    public string Src { get; set; }
    public string Dst { get; set; }
    public string State { get; set; }
    private string _status = ""; public string Status { get { return _status; } set { _status = value; Raise("Status"); } }
    private string _brush = "#86868B"; public string StatusBrush { get { return Theme.F(_brush); } set { _brush = value; Raise("StatusBrush"); } }
    private string _size = L10n.T("计算中…"); public string SizeText { get { return _size; } set { _size = value; Raise("SizeText"); } }
    public long Size { get; set; }
    public bool CanBack { get; set; }
    public bool CanFix { get; set; }
    public bool CanDrop { get; set; }
    public string FixTarget { get; set; }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
// 搬家管理：C 盘上还能搬的一项（聊天记录、软件、其他文件夹）
public class CandRow : INotifyPropertyChanged {
    public static volatile bool Dirty;   // 勾选变了，界面要重算「已选几项」
    public string Key { get; set; }
    public string Type { get; set; }     // cat = 清理目录里的项目；app = 装在 C 盘的软件
    public string Group { get; set; }
    public int GroupOrder { get; set; }  // 组的先后：聊天记录、软件、其他文件夹、不适合搬的（表头排序只在组里面排）
    public string GroupTitle { get; set; }
    public string GroupNote { get; set; }
    public bool First { get; set; }
    public string Name { get; set; }
    public string PathText { get; set; }
    public string Note { get; set; }
    public long Size { get; set; }
    public string SizeText { get; set; }
    public int Idx { get; set; }
    public string Location { get; set; }
    public string[] Apps { get; set; }
    public bool CanMove { get; set; }
    public bool Partial { get; set; }    // 目标盘上已经有上次复制的一部分
    private bool _chk; public bool Checked { get { return _chk; } set { if (_chk != value) { _chk = value; Dirty = true; Raise("Checked"); } } }
    private string _status = ""; public string Status { get { return _status; } set { _status = value; Raise("Status"); } }
    private string _brush = "#86868B"; public string StatusBrush { get { return Theme.F(_brush); } set { _brush = value; Raise("StatusBrush"); } }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
public class LogRow {
    public string Time { get; set; }
    public DateTime When { get; set; }
    public string Cat { get; set; }
    public string CatText { get; set; }
    string _catBg, _catFg;
    public string CatBg { get { return Theme.B(_catBg); } set { _catBg = value; } }
    public string CatFg { get { return Theme.F(_catFg); } set { _catFg = value; } }
    public string What { get; set; }
    public string Target { get; set; }
    public string Detail { get; set; }
}
public class VdiskRow : INotifyPropertyChanged {
    public string Name { get; set; }
    public string Path { get; set; }
    public string Kind { get; set; }
    public string Distro { get; set; }
    public string Note { get; set; }
    public bool CanCompact { get; set; }
    public bool CanMove { get; set; }
    private string _size = L10n.T("计算中…"); public string SizeText { get { return _size; } set { _size = value; Raise("SizeText"); } }
    public long Size { get; set; }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
// 空间地图顶部的磁盘卡片：用量条、温度、磨损、健康状态，颜色按档位
public class DiskCard {
    public string Letter { get; set; }
    public bool Sel { get; set; }
    public string Model { get; set; }
    public string UsedText { get; set; }
    public double UsedPct { get; set; }
    public double BarW { get; set; }        // 用量条已用部分的宽度（像素）
    public string TempText { get; set; }
    public string WearText { get; set; }
    public string HealthText { get; set; }
    public string HoursText { get; set; }
    public string Tip { get; set; }
    public bool HasTemp { get { return !string.IsNullOrEmpty(TempText); } }
    public bool HasWear { get { return !string.IsNullOrEmpty(WearText); } }
    public bool HasHours { get { return !string.IsNullOrEmpty(HoursText); } }
    string _bar = "#0071E3"; public string BarBrush { get { return Theme.B(_bar); } set { _bar = value; } }
    string _tf = "#248A3D", _tb = "#E5F4E9"; public string TempFg { get { return Theme.F(_tf); } set { _tf = value; } } public string TempBg { get { return Theme.B(_tb); } set { _tb = value; } }
    string _wf = "#248A3D", _wb = "#E5F4E9"; public string WearFg { get { return Theme.F(_wf); } set { _wf = value; } } public string WearBg { get { return Theme.B(_wb); } set { _wb = value; } }
    string _hf = "#248A3D", _hb = "#E5F4E9"; public string HealthFg { get { return Theme.F(_hf); } set { _hf = value; } } public string HealthBg { get { return Theme.B(_hb); } set { _hb = value; } }
    string _stripe = "#248A3D"; public string Stripe { get { return Theme.B(_stripe); } set { _stripe = value; } }
}
public class HistBar {
    public double H { get; set; }
    public string Label { get; set; }
    public string Tip { get; set; }
    string _fill; public string Fill { get { return Theme.B(_fill); } set { _fill = value; } }
}
public class GrowRow {
    public string Path { get; set; }
    public string Before { get; set; }
    public string Now { get; set; }
    public string Change { get; set; }
    string _change; public string ChangeBrush { get { return Theme.F(_change); } set { _change = value; } }
    public double BeforeBytes { get; set; }
    public double NowBytes { get; set; }
    public double Delta { get { return NowBytes - BeforeBytes; } }
}
