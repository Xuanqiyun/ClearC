import json, sys
t = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2], encoding='utf-8-sig'))
bad = 0
for k in sorted(set(t) | set(m)):
    a = t.get(k); b = m.get(k)
    if a is None or b is None: print('MISSING', 'in truth' if a is None else 'in mft', repr(k)); bad += 1; continue
    for f in ('files', 'bytes'):
        if a[f] != b[f]: print('DIFF', f, repr(k), a[f], b[f]); bad += 1
    if sorted(a['dirs']) != sorted(b['dirs']): print('DIRS', repr(k), set(a['dirs']) ^ set(b['dirs'])); bad += 1
    if sorted(a['links']) != sorted(b['links']): print('LINKS', repr(k), a['links'], b['links']); bad += 1
print('compared', len(t), 'dirs; problems', bad)
