// ==================== 深色模式：把为浅色界面写的颜色换成深色界面用的 ====================
// 按用途换：f 文字和图标  b 底色  d 边框和分隔线。灰色系按明暗翻过来（浅底变深底、深字变浅字），
// 彩色保留色相：文字和图标提亮一点，浅的彩色底变成同色调的深底。透明色和阴影不动。
public static class Theme {
    public static bool Dark;

    public static string Map(string c, char role) {
        if (!Dark || string.IsNullOrEmpty(c)) return c;
        uint argb;
        if (!TryParse(c.Trim(), out argb)) return c;
        int a = (int)(argb >> 24), r = (int)((argb >> 16) & 255), g = (int)((argb >> 8) & 255), b = (int)(argb & 255);
        if (a == 0) return c;                                        // 透明
        if (a < 255 && r < 48 && g < 48 && b < 48) return c;         // 阴影、半透明遮罩
        if (role == 'b' && a == 255 && (argb & 0xFFFFFF) == 0xFEFEFE) return "#3A3A3E";   // 浮起来的选中块（分段按钮）：比卡片亮一点，红色、蓝色的字照样看得清
        if (role == 'b' && a == 255 && (argb & 0xFFFFFF) == 0) return "#FFFFFF";          // 按钮上的黑色遮罩（按下变暗）：深色时改成变亮
        double h, s, l; ToHsl(r, g, b, out h, out s, out l);
        double chroma = (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b))) / 255.0;
        bool gray = l >= 0.9 ? chroma < 0.025 : chroma < 0.08;
        double L, S = s;
        if (role == 's') role = gray ? 's' : 'b';
        if (gray) {
            S = Math.Min(s, 0.06);
            if (role == 's') L = Clamp(0.25 + (0.9 - l) * 0.4, 0.22, 0.34);   // 进度条的底槽、灰色小圆点（形状的填充色）
            else if (role == 'f') {
                if (r == 255 && g == 255 && b == 255) return c;      // 彩色按钮、色块上的白字
                L = Clamp(1.06 - l, 0.30, 0.95);
            } else if (role == 'd') L = Clamp(0.19 + (0.96 - l) * 0.9, 0.17, 0.62);
            else {
                if (l >= 0.985) L = 0.17;                            // 白：卡片
                else if (l >= 0.94) L = 0.105 + (0.985 - l) * 0.5;   // 页面底色、卡片里的浅灰块
                else if (l >= 0.80) L = Clamp(0.13 + (0.94 - l) * 1.0, 0.13, 0.30);   // 侧边栏、底槽、悬停和按下的浅灰：越深的浅灰换成越亮的深灰，悬停能看出来
                else L = Clamp(0.30 + l * 0.25, 0.30, 0.45);         // 本来就深的底（提示条等）
            }
        } else if (l >= 0.85) {                                      // 浅的彩色底（提示框、标签）
            if (role == 'f') { L = 0.80; S = Math.Min(s, 0.7); }
            else if (role == 'd') { L = 0.34; S = Math.Min(s, 0.45); }
            else { L = 0.21; S = Math.Min(s, 0.45); }   // 深色时标签、提示框的底再暗一点，上面的彩色字才够清楚（4.5:1）
        } else if (l >= 0.65) {                                      // 偏浅的彩色（浅边框、焦点环）
            if (role == 'b') { L = 0.28; S = Math.Min(s, 0.5); }
            else if (role == 'd') { L = 0.42; S = Math.Min(s, 0.55); }
            else L = l;
        } else {                                                     // 鲜艳的颜色
            if (role == 'f') L = Math.Max(l, 0.68);
            else if (role == 'd') L = Math.Max(l, 0.50);
            else L = Math.Min(Math.Max(l, 0.42), 0.55);
        }
        int R, G, B; FromHsl(h, S, L, out R, out G, out B);
        return a == 255 ? string.Format("#{0:X2}{1:X2}{2:X2}", R, G, B) : string.Format("#{0:X2}{1:X2}{2:X2}{3:X2}", a, R, G, B);
    }
    public static string F(string c) { return Map(c, 'f'); }
    public static string B(string c) { return Map(c, 'b'); }
    public static string D(string c) { return Map(c, 'd'); }

    static bool TryParse(string s, out uint argb) {
        argb = 0;
        if (string.Equals(s, "White", StringComparison.OrdinalIgnoreCase)) { argb = 0xFFFFFFFF; return true; }
        if (string.Equals(s, "Black", StringComparison.OrdinalIgnoreCase)) { argb = 0xFF000000; return true; }
        if (s.Length < 7 || s[0] != '#') return false;
        uint v;
        if (!uint.TryParse(s.Substring(1), System.Globalization.NumberStyles.HexNumber, null, out v)) return false;
        if (s.Length == 7) { argb = 0xFF000000 | v; return true; }
        if (s.Length == 9) { argb = v; return true; }
        return false;
    }
    static double Clamp(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }
    static void ToHsl(int r, int g, int b, out double h, out double s, out double l) {
        double R = r / 255.0, G = g / 255.0, B = b / 255.0;
        double mx = Math.Max(R, Math.Max(G, B)), mn = Math.Min(R, Math.Min(G, B));
        l = (mx + mn) / 2; h = 0; s = 0;
        if (mx == mn) return;
        double d = mx - mn;
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        if (mx == R) h = (G - B) / d + (G < B ? 6 : 0); else if (mx == G) h = (B - R) / d + 2; else h = (R - G) / d + 4;
        h /= 6;
    }
    static void FromHsl(double h, double s, double l, out int r, out int g, out int b) {
        double R, G, B;
        if (s <= 0) R = G = B = l;
        else {
            double q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
            R = Hue(p, q, h + 1.0 / 3); G = Hue(p, q, h); B = Hue(p, q, h - 1.0 / 3);
        }
        r = (int)Math.Round(Clamp(R, 0, 1) * 255); g = (int)Math.Round(Clamp(G, 0, 1) * 255); b = (int)Math.Round(Clamp(B, 0, 1) * 255);
    }
    static double Hue(double p, double q, double t) {
        if (t < 0) t += 1; if (t > 1) t -= 1;
        if (t < 1.0 / 6) return p + (q - p) * 6 * t;
        if (t < 0.5) return q;
        if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
        return p;
    }
    // 浅色时把颜色和白色按比例混合；深色时和卡片底色混合（选中状态用的淡底色）
    public static string Tint(string c, double k) {
        uint argb; if (!TryParse(c, out argb)) return c;
        int r = (int)((argb >> 16) & 255), g = (int)((argb >> 8) & 255), b = (int)(argb & 255);
        if (Dark) { string m = Map(c, 'f'); TryParse(m, out argb); r = (int)((argb >> 16) & 255); g = (int)((argb >> 8) & 255); b = (int)(argb & 255); }
        int br = Dark ? 0x2C : 255, bg = Dark ? 0x2C : 255, bb = Dark ? 0x2E : 255;
        return string.Format("#{0:X2}{1:X2}{2:X2}", (int)(br + (r - br) * k), (int)(bg + (g - bg) * k), (int)(bb + (b - bb) * k));
    }

    // 整段 XAML 里的颜色按所在的属性换掉（注释原样留着）
    static System.Text.RegularExpressions.Regex tagRx, attrRx;
    public static string Xaml(string x) {
        if (!Dark || string.IsNullOrEmpty(x)) return x;
        if (tagRx == null) {
            attrRx = new System.Text.RegularExpressions.Regex("([\\w.:]+)(\\s*=\\s*)(?:\"([^\"]*)\"|'([^']*)')");
            tagRx = new System.Text.RegularExpressions.Regex("<!--.*?-->|<!\\[CDATA\\[.*?\\]\\]>|<(/?)([A-Za-z_][\\w.:]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>", System.Text.RegularExpressions.RegexOptions.Singleline);
        }
        List<string> stack = new List<string>();
        return tagRx.Replace(x, delegate (System.Text.RegularExpressions.Match m) {
            if (!m.Groups[2].Success) return m.Value;                  // 注释、CDATA
            string close = m.Groups[1].Value, name = m.Groups[2].Value, attrs = m.Groups[3].Value, self = m.Groups[4].Value;
            if (close.Length > 0) { for (int i = stack.Count - 1; i >= 0; i--) if (stack[i] == name || stack[i].StartsWith(name + "|")) { stack.RemoveRange(i, stack.Count - i); break; } return m.Value; }
            string prop = null, key = null;
            foreach (System.Text.RegularExpressions.Match a in attrRx.Matches(attrs)) {
                string av = a.Groups[3].Success ? a.Groups[3].Value : a.Groups[4].Value;
                if (a.Groups[1].Value == "Property") prop = av;
                else if (a.Groups[1].Value == "x:Key") key = av;
            }
            string local = name.Contains(":") ? name.Substring(name.IndexOf(':') + 1) : name;
            string newAttrs = attrRx.Replace(attrs, delegate (System.Text.RegularExpressions.Match a) {
                string an = a.Groups[1].Value; bool dq = a.Groups[3].Success; string v = dq ? a.Groups[3].Value : a.Groups[4].Value;
                string bare = an.Contains(".") ? an.Substring(an.LastIndexOf('.') + 1) : an;   // TextElement.Foreground 之类
                char role = '\0';
                if (bare == "Foreground" || bare == "CaretBrush") role = 'f';
                else if (bare == "Background") role = 'b';
                else if (bare == "BorderBrush") role = 'd';
                else if (bare == "Stroke") role = IsWhite(v) ? '\0' : 'd';           // 勾选框里的白色对勾不动
                else if (bare == "Fill") role = IsWhite(v) ? '\0' : (Lightish(v) ? 's' : 'f');   // 开关的白色圆钮不动
                else if (an == "Value" && prop != null) role = RoleOf(prop, v);
                else if (an == "Color" && local != "DropShadowEffect") {
                    for (int i = stack.Count - 1; i >= 0 && role == '\0'; i--) {
                        string st = stack[i];
                        if (st == "Setter.Value" && i > 0 && stack[i - 1].StartsWith("Setter|")) { role = RoleOf(stack[i - 1].Substring(7), v); break; }
                        int dot = st.LastIndexOf('.'); if (dot > 0 && st.IndexOf('|') < 0) role = RoleOf(st.Substring(dot + 1), v);
                    }
                    if (role == '\0') {
                        string k = key ?? "";
                        role = (k.IndexOf("Fg", StringComparison.OrdinalIgnoreCase) >= 0 || k.IndexOf("Text", StringComparison.OrdinalIgnoreCase) >= 0) ? 'f'
                             : (k.IndexOf("Line", StringComparison.OrdinalIgnoreCase) >= 0 || k.IndexOf("Border", StringComparison.OrdinalIgnoreCase) >= 0) ? 'd' : 'b';
                    }
                }
                if (role == '\0' || (v.Length == 0) || (v[0] != '#' && v != "White" && v != "Black")) return a.Value;
                string q = dq ? "\"" : "'";
                return an + a.Groups[2].Value + q + Map(v, role) + q;
            });
            if (self.Length == 0) stack.Add(local == "Setter" && prop != null ? "Setter|" + prop : name);
            return "<" + name + newAttrs + self + ">";
        });
    }
    static bool IsWhite(string v) { return v == "White" || string.Equals(v, "#FFFFFF", StringComparison.OrdinalIgnoreCase) || string.Equals(v, "#FFFFFFFF", StringComparison.OrdinalIgnoreCase); }
    // 深色的窗口标题栏（Windows 10 2004 以后、Windows 11）
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void DarkTitle(IntPtr hwnd) {
        if (!Dark || hwnd == IntPtr.Zero) return;
        try { int on = 1; if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4); } catch { }
    }
    static char RoleOf(string prop, string v) {
        if (prop.Contains(".")) prop = prop.Substring(prop.LastIndexOf('.') + 1);
        if (prop == "Foreground" || prop == "CaretBrush") return 'f';
        if (prop == "Background") return 'b';
        if (prop == "BorderBrush") return 'd';
        if (prop == "Stroke") return IsWhite(v) ? '\0' : 'd';
        if (prop == "Fill") return IsWhite(v) ? '\0' : (Lightish(v) ? 's' : 'f');
        return '\0';
    }
    static bool Lightish(string v) {
        uint argb; if (!TryParse(v, out argb)) return false;
        int r = (int)((argb >> 16) & 255), g = (int)((argb >> 8) & 255), b = (int)(argb & 255);
        return (r + g + b) / 3 > 200;
    }
}

