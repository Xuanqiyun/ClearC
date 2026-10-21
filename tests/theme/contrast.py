# 静态检查：每段文字的颜色和它所在底色的对比度（WCAG），找出深色模式下看不清的地方
import sys, re, xml.etree.ElementTree as ET
from collections import defaultdict
NS = '{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
XK = '{http://schemas.microsoft.com/winfx/2006/xaml}Key'
def col(v):
    if v is None: return None
    v = v.strip()
    if v == 'White': return (255, 255, 255, 255)
    if v == 'Black': return (0, 0, 0, 255)
    if v == 'Transparent': return (0, 0, 0, 0)
    m = re.fullmatch(r'#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})', v)
    if not m: return None
    h = m.group(1)
    if len(h) == 6: return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)
    return (int(h[2:4], 16), int(h[4:6], 16), int(h[6:8], 16), int(h[0:2], 16))
def lum(c):
    def ch(x):
        x /= 255
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])
def ratio(a, b):
    la, lb = lum(a), lum(b)
    if la < lb: la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)
def local(t): return t.split('}')[-1]
def analyze(path, winbg, winfg):
    tree = ET.parse(path); root = tree.getroot()
    parent = {c: p for p in root.iter() for c in p}
    # styles: key -> {prop: value}
    styles = {}
    for st in root.iter(NS + 'Style'):
        k = st.get(XK); d = {}
        based = st.get('BasedOn')
        for se in st:
            if local(se.tag) == 'Setter' and se.get('Property') in ('Foreground', 'Background'): d[se.get('Property')] = se.get('Value')
        if k: styles[k] = (d, based)
    def style_val(el, prop):
        s = el.get('Style')
        seen = 0
        while s and seen < 5:
            m = re.match(r'\{StaticResource (\w+)\}', s)
            if not m or m.group(1) not in styles: return None
            d, based = styles[m.group(1)]
            if prop in d: return d[prop]
            s = based; seen += 1
        return None
    def prop_elem(el, prop):
        for c in el:
            if local(c.tag).endswith('.' + prop):
                for b in c:
                    if local(b.tag) == 'SolidColorBrush': return b.get('Color')
                    if local(b.tag) == 'LinearGradientBrush':
                        for g in b.iter(NS + 'GradientStop'): return g.get('Color')
        return None
    def eff(el, prop, default):
        e = el
        while e is not None:
            v = e.get(prop) or prop_elem(e, prop) or style_val(e, prop)
            if v and '{' not in v:
                c = col(v)
                if c and (prop != 'Background' or c[3] == 255): return c, e
            if local(e.tag) in ('ControlTemplate', 'DataTemplate') and prop == 'Foreground': pass
            e = parent.get(e)
        return default, None
    bad = defaultdict(list)
    n = 0
    for el in root.iter():
        t = local(el.tag)
        if t not in ('TextBlock', 'Run', 'TextBox', 'Button', 'CheckBox', 'RadioButton', 'ComboBox', 'Label', 'ToggleButton'): continue
        fgv = el.get('Foreground') or style_val(el, 'Foreground')
        if fgv and '{' in fgv: continue
        fg, _ = eff(el, 'Foreground', winfg)
        bg, bgel = eff(el, 'Background', winbg)
        if fg is None or bg is None: continue
        if fg[3] < 255: continue
        n += 1
        r = ratio(fg, bg)
        if r < 3.0:
            txt = (el.get('Text') or el.get('Content') or '')[:30]
            bad[('#%02X%02X%02X' % fg[:3], '#%02X%02X%02X' % bg[:3])].append((r, t, txt))
    return n, bad
worse = 0
for name in sys.argv[1:]:
    counts = {}
    for mode in ('light', 'dark'):
        p = name.replace('.dark.', '.light.') if mode == 'light' else name
        r = ET.parse(p).getroot()
        wb = col(r.get('Background')) if r.get('Background') else None
        wf = col(r.get('Foreground')) if r.get('Foreground') else None
        if wb is None: wb = (255, 255, 255, 255) if mode == 'light' else col('#2C2C2E')
        if wf is None: wf = (0, 0, 0, 255) if mode == 'light' else col('#F0F0F2')
        n, bad = analyze(p, wb, wf)
        counts[mode] = sum(len(v) for v in bad.values())
        print('== %s %s: %d text elements, %d low-contrast pairs' % (p.split('/')[-1], mode, n, len(bad)))
        for (f, b), lst in sorted(bad.items(), key=lambda kv: min(x[0] for x in kv[1])):
            print('   fg %s on bg %s  ratio %.2f  x%d  e.g. %s "%s"' % (f, b, min(x[0] for x in lst), len(lst), lst[0][1], lst[0][2]))
    # 浅色里本来就淡的（装饰性的箭头、占位文字）深色里也淡，这不算问题；深色比浅色多出来的才算
    if counts.get('dark', 0) > counts.get('light', 0):
        print('   FAIL: dark mode has more low-contrast text than light mode'); worse += 1
sys.exit(1 if worse else 0)
