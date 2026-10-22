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
    public string Note { get; set; }
    public bool CanCompact { get; set; }
    public bool CanMove { get; set; }
    private string _size = L10n.T("计算中…"); public string SizeText { get { return _size; } set { _size = value; Raise("SizeText"); } }
    public long Size { get; set; }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
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
}
