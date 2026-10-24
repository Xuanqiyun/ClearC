# 改 src/CleanC-UI.ps1（CRLF、带 BOM）：old/new 里写 \n，自动换成 \r\n；匹配次数不对就停下，什么都不写
#   from ed import Ed; e = Ed(); e.rep(旧, 新, 次数=1); e.save()
# 改完跑 python3 build/split.py，把 src/parts 同步过去
import os, re
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'CleanC-UI.ps1')
class Ed:
    def __init__(self, path=P):
        self.p = path
        self.s = open(path, encoding='utf-8-sig', newline='').read()
    def rep(self, a, b, n=1):
        a = a.replace('\r\n', '\n').replace('\n', '\r\n'); b = b.replace('\r\n', '\n').replace('\n', '\r\n')
        c = self.s.count(a)
        if c != n: raise SystemExit('count %d (want %d) for: %s' % (c, n, a[:150]))
        self.s = self.s.replace(a, b)
    def save(self):
        self.s = re.sub(r'(?<!\r)\n', '\r\n', self.s)
        open(self.p, 'w', encoding='utf-8-sig', newline='').write(self.s)
