import json, sys
t = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2], encoding='utf-8-sig'))
bad = 0
# 每个文件只算一次的合计（硬链接只算一次）
if '#unique' in t and '#unique' in m:
    for f in ('size', 'disk'):
        if t['#unique'][f] != m['#unique'][f]: print('UNIQUE', f, t['#unique'][f], m['#unique'][f]); bad += 1
t.pop('#unique', None); m.pop('#unique', None)
for k in sorted(set(t) | set(m)):
    a = t.get(k); b = m.get(k)
    if a is None or b is None: print('MISSING', 'in truth' if a is None else 'in mft', repr(k)); bad += 1; continue
    for f in ('files', 'bytes', 'disk', 'shared'):
        if f in a and f in b and a[f] != b[f]: print('DIFF', f, repr(k), a[f], b[f]); bad += 1
    if sorted(a['dirs']) != sorted(b['dirs']): print('DIRS', repr(k), set(a['dirs']) ^ set(b['dirs'])); bad += 1
    if sorted(a['links']) != sorted(b['links']): print('LINKS', repr(k), a['links'], b['links']); bad += 1
print('compared', len(t), 'dirs; problems', bad)
