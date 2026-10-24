# 往英文翻译表里加条目（已经有的跳过）：from i18n_add import add; add([('中文', 'English'), ...])
# 也可以命令行：python3 tools/i18n-add.py '中文' 'English'
import os, sys
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'CleanC-UI.ps1')
def add(rows, path=P):
    b = open(path, 'rb').read(); s = b.decode('utf-8-sig')
    anchor = '全部类型\tAll types\r\n'; assert s.count(anchor) == 1, 'anchor not found'
    have = set(l.split('\t')[0] for l in s.split('\r\n') if '\t' in l)
    # 代码里的 `n `t（PowerShell 双引号字符串里的换行、制表）在表里写成 \n \t
    esc = lambda x: x.replace('`n', '\\n').replace('`t', '\\t')
    rows = [(esc(a), esc(c)) for a, c in rows]
    new = [(a, c) for a, c in rows if a not in have]
    s = s.replace(anchor, anchor + ''.join(a + '\t' + c + '\r\n' for a, c in new))
    open(path, 'wb').write(b'\xef\xbb\xbf' + s.encode('utf-8')); print('added', len(new), 'of', len(rows))
if __name__ == '__main__' and len(sys.argv) == 3: add([(sys.argv[1], sys.argv[2])])
