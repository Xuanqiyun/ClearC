using System;
using System.ComponentModel;
// 深色模式换颜色：真正的换法在另一段 C#（Theme），启动时把它接到这里
public static class RowTheme {
    public static Func<string, char, string> Map;
    public static string M(string c, char role) { Func<string, char, string> f = Map; return f == null ? c : f(c, role); }
}
public class RowItem : INotifyPropertyChanged {
    public int Idx { get; set; }
    public string Group { get; set; }
    public string GroupTitle { get; set; }
    public string GroupNote { get; set; }
    public bool First { get; set; }
    public string Name { get; set; }
    public string SizeText { get; set; }
    public double Bytes { get; set; }      // 表头按大小排序用（-1 = 运行后才知道）
    public string Note { get; set; }
    public string[] Actions { get; set; }
    private string _action;
    public string Action { get { return _action; } set { _action = value; Raise("Action"); } }
    private string _status = "";
    public string Status { get { return _status; } set { _status = value; Raise("Status"); } }
    private string _statusBrush = "#667085";
    public string StatusBrush { get { return RowTheme.M(_statusBrush, 'f'); } set { _statusBrush = value; Raise("StatusBrush"); } }
    void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public event PropertyChangedEventHandler PropertyChanged;
}
