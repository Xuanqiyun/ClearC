# 把单文件的 src/CleanC-UI.ps1 按内容拆成 src/parts/ 下的多个文件（C#、核心逻辑、翻译表、界面 XAML、各页面的界面逻辑），
# 并写出 src/parts/order.txt。build/merge.ps1 按 order.txt 原样拼回去，拼出来的和原文件逐字节相同。
# 一般只在整理结构时用一次；平时直接改 src/parts/ 里的文件，再运行 merge.ps1。
import os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'src', 'CleanC-UI.ps1')
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, 'src', 'parts')
data = open(src, 'rb').read()
lines = data.splitlines(keepends=True)
text = [l.decode('utf-8-sig' if i == 0 else 'utf-8').rstrip('\r\n') for i, l in enumerate(lines)]
def find(pred, start=0, what=''):
    for i in range(start, len(text)):
        if pred(text[i]): return i
    raise SystemExit('split.py: marker %r not found after line %d; the script layout changed, update split.py' % (what, start + 1))
def line_eq(s): return lambda t: t == s
def starts(s): return lambda t: t.startswith(s)
cuts = []   # (start index, part name)
def here(decl, name, glue_after, quote):
    i = find(line_eq(decl), 0, decl)
    cuts.append((i + 1, name))
    j = find(line_eq(quote + '@'), i + 1, quote + '@ after ' + decl)
    cuts.append((j, glue_after))
    return j
cuts.append((0, 'glue/00-start.ps1'))
here('$rowCode = @"', 'cs/RowTypes.cs', 'glue/01-load-types.ps1', '"')
d = here("$dupCode = @'", 'cs/DupFinder.cs', 'glue/02-engine.ps1', "'")
for banner, name in [('// ==================== 读一个文件夹里的条目', 'cs/DirReader.cs'), ('// ==================== 直接读 NTFS 的文件表', 'cs/Mft.cs'),
                     ('// ==================== 空间地图：', 'cs/DiskMap.cs'), ('// ==================== 深色模式', 'cs/Theme.cs'),
                     ('// ==================== 文件系统小工具', 'cs/FsTools.cs'), ('// ==================== 界面文字翻译', 'cs/Rows.cs')]:
    i = find(starts(banner), 0, banner)
    if i >= d: raise SystemExit('split.py: %r is not inside $dupCode' % banner)
    cuts.append((i, name))
here("$engine = @'", 'engine/Engine.ps1', 'glue/03-translations.ps1', "'")
here("$script:l10nData = @'", 'i18n/en.tsv', 'glue/04-help.ps1', "'")
here("$script:helpEnXaml = @'", 'ui/help-en.xaml', 'glue/05-scheduled-modes.ps1', "'")
m = here('[xml]$xaml = @"', 'ui/main.xaml', 'ui/10-window.ps1', '"')
for title, name in [('# 第一页：清理 C 盘', 'ui/20-clean.ps1'), ('# 第二页：重复文件', 'ui/30-duplicates.ps1'), ('# 公用：打开位置、选磁盘', 'ui/40-common.ps1'),
                    ('# 空间地图', 'ui/50-space-map.ps1'), ('# 搬家管理', 'ui/60-moves.ps1'), ('# 省空间', 'ui/70-save-space.ps1'),
                    ('# 软件管理', 'ui/80-apps.ps1'), ('# 自动提醒', 'ui/90-reminders.ps1'), ('# 操作日志', 'ui/91-activity-log.ps1'),
                    ('# 重复文件：合并为一份', 'ui/92-merge.ps1'), ('# 定时器', 'ui/99-timer-and-start.ps1')]:
    i = m
    while True:                                           # 标题行：上面一行是横线
        i = find(lambda t, s=title: t.startswith(s), i + 1, title)
        if text[i - 1].startswith('# ----'): break
    i -= 1                                                # 标题上面那条横线跟着标题走
    cuts.append((i, name))
cuts.sort()
starts_ = [c[0] for c in cuts]
if starts_ != sorted(set(starts_)): raise SystemExit('split.py: two parts start on the same line')
os.makedirs(out, exist_ok=True)
order = []
for k, (i, name) in enumerate(cuts):
    j = cuts[k + 1][0] if k + 1 < len(cuts) else len(lines)
    p = os.path.join(out, name); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(b''.join(lines[i:j]))
    order.append(name)
    print('%-34s lines %5d-%5d' % (name, i + 1, j))
open(os.path.join(out, 'order.txt'), 'w', encoding='utf-8', newline='\r\n').write('# build/merge.ps1 按这个顺序把各部分原样拼成 src/CleanC-UI.ps1\n' + '\n'.join(order) + '\n')
