import os, sys, json, stat
R = sys.argv[1]; out = {}
def walk(d, rel):
    files = 0; size = 0; kids = []; links = []
    with os.scandir(d) as it:
        for e in it:
            try: st = e.stat(follow_symlinks=False)
            except OSError: links.append(e.name); continue
            if stat.S_ISLNK(st.st_mode):
                # NTFS 的符号链接：ntfs-3g 建的是带重解析点的记录；指向文件夹的当成链接文件夹，指向文件的当成大小为 0 的文件
                if os.path.isdir(e.path): links.append(e.name)
                else: files += 1
                continue
            if stat.S_ISDIR(st.st_mode): kids.append(e.name); walk(e.path, rel + '/' + e.name)
            else: files += 1; size += st.st_size
    out[rel] = {'files': files, 'bytes': size, 'dirs': sorted(kids + links), 'links': sorted(links)}
walk(R, '')
json.dump(out, open(sys.argv[2], 'w'), ensure_ascii=False)
print('dirs', len(out), 'files', sum(v['files'] for v in out.values()), 'bytes', sum(v['bytes'] for v in out.values()))
