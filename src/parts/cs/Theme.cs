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
        double h, s, l; ToHsl(r, g, b, out h, out s, out l);
        double chroma = (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b))) / 255.0;
        bool gray = l >= 0.9 ? chroma < 0.025 : chroma < 0.08;
        double L, S = s;
        if (gray) {
            S = Math.Min(s, 0.06);
            if (role == 'f') {
                if (r == 255 && g == 255 && b == 255) return c;      // 彩色按钮、色块上的白字
                L = Clamp(1.06 - l, 0.30, 0.95);
            } else if (role == 'd') L = Clamp(0.19 + (0.96 - l) * 0.9, 0.17, 0.62);
            else {
                if (l >= 0.985) L = 0.17;                            // 白：卡片
                else if (l >= 0.94) L = 0.105 + (0.985 - l) * 0.5;   // 页面底色、卡片里的浅灰块
                else if (l >= 0.80) L = 0.13 + (0.94 - l) * 0.15;    // 侧边栏、分段按钮的底槽、按下的浅灰：比卡片暗一点（和浅色时一样，白色的选中块浮在上面）
                else L = Clamp(0.30 + l * 0.25, 0.30, 0.45);         // 本来就深的底（提示条等）
            }
        } else if (l >= 0.85) {                                      // 浅的彩色底（提示框、标签）
            if (role == 'f') { L = 0.80; S = Math.Min(s, 0.7); }
            else if (role == 'd') { L = 0.34; S = Math.Min(s, 0.45); }
            else { L = 0.19; S = Math.Min(s, 0.40); }
        } else if (l >= 0.65) {                                      // 偏浅的彩色（浅边框、焦点环）
            if (role == 'b') { L = 0.28; S = Math.Min(s, 0.5); }
            else if (role == 'd') { L = 0.42; S = Math.Min(s, 0.55); }
            else L = l;
        } else {                                                     // 鲜艳的颜色
            if (role == 'f') L = Math.Max(l, 0.62);
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

    // 整段 XAML 里的颜色按所在的属性换掉
    static readonly System.Text.RegularExpressions.Regex TagRx = new System.Text.RegularExpressions.Regex(
        "<(/?)([A-Za-z_][\\w.:]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>", System.Text.RegularExpressions.RegexOptions.Compiled);
    static readonly System.Text.RegularExpressions.Regex AttrRx = new System.Text.RegularExpressions.Regex(
        "([\\w.:]+)(\\s*=\\s*)\"([^\"]*)\"", System.Text.RegularExpressions.RegexOptions.Compiled);
    public static string Xaml(string x) {
        if (!Dark || string.IsNullOrEmpty(x)) return x;
        List<string> stack = new List<string>();
        return TagRx.Replace(x, delegate (System.Text.RegularExpressions.Match m) {
            string close = m.Groups[1].Value, name = m.Groups[2].Value, attrs = m.Groups[3].Value, self = m.Groups[4].Value;
            if (close.Length > 0) { int i = stack.LastIndexOf(name); if (i >= 0) stack.RemoveRange(i, stack.Count - i); return m.Value; }
            string prop = null, key = null;
            foreach (System.Text.RegularExpressions.Match a in AttrRx.Matches(attrs)) {
                if (a.Groups[1].Value == "Property") prop = a.Groups[3].Value;
                else if (a.Groups[1].Value == "x:Key") key = a.Groups[3].Value;
            }
            string local = name.Contains(":") ? name.Substring(name.IndexOf(':') + 1) : name;
            string newAttrs = AttrRx.Replace(attrs, delegate (System.Text.RegularExpressions.Match a) {
                string an = a.Groups[1].Value, v = a.Groups[3].Value;
                char role = '\0';
                if (an == "Foreground" || an == "CaretBrush") role = 'f';
                else if (an == "Background") role = 'b';
                else if (an == "BorderBrush" || an == "Stroke") role = 'd';
                else if (an == "Fill") role = Lightish(v) ? 'b' : 'f';
                else if (an == "Value" && prop != null) role = RoleOf(prop, v);
                else if (an == "Color" && local != "DropShadowEffect") {
                    for (int i = stack.Count - 1; i >= 0 && role == '\0'; i--) { int dot = stack[i].LastIndexOf('.'); if (dot > 0) role = RoleOf(stack[i].Substring(dot + 1), v); }
                    if (role == '\0') {
                        string k = key ?? "";
                        role = (k.IndexOf("Fg", StringComparison.OrdinalIgnoreCase) >= 0 || k.IndexOf("Text", StringComparison.OrdinalIgnoreCase) >= 0) ? 'f'
                             : (k.IndexOf("Line", StringComparison.OrdinalIgnoreCase) >= 0 || k.IndexOf("Border", StringComparison.OrdinalIgnoreCase) >= 0) ? 'd' : 'b';
                    }
                }
                if (role == '\0' || (v.Length == 0) || (v[0] != '#' && v != "White" && v != "Black")) return a.Value;
                return an + a.Groups[2].Value + "\"" + Map(v, role) + "\"";
            });
            if (self.Length == 0) stack.Add(name);
            return "<" + name + newAttrs + self + ">";
        });
    }
    static char RoleOf(string prop, string v) {
        if (prop == "Foreground" || prop == "CaretBrush") return 'f';
        if (prop == "Background") return 'b';
        if (prop == "BorderBrush" || prop == "Stroke") return 'd';
        if (prop == "Fill") return Lightish(v) ? 'b' : 'f';
        return '\0';
    }
    static bool Lightish(string v) {
        uint argb; if (!TryParse(v, out argb)) return false;
        int r = (int)((argb >> 16) & 255), g = (int)((argb >> 8) & 255), b = (int)(argb & 255);
        return (r + g + b) / 3 > 200;
    }
}

