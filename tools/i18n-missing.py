# 列出代码里 T '…' 用到、翻译表里没有的中文：python3 tools/i18n-missing.py <i18n-keys.ps1 的输出>
import os, re, sys
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'CleanC-UI.ps1')
s = open(P, encoding='utf-8-sig').read().replace('\r\n', '\n')
tsv = re.search(r"\$script:l10nData = @'\n(.*?)\n'@", s, re.S).group(1)
have = {}
for line in tsv.split('\n'):
    if not line.strip() or line.startswith('#'): continue
    k, _, v = line.partition('\t'); have[k] = v
keys = [l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
miss = [k for k in keys if k not in have]
print('dict entries', len(have), 'code keys', len(keys), 'missing', len(miss))
for k in miss: print(k)
sys.exit(1 if miss else 0)
