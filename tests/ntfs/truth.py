import os, sys, json, stat
R = sys.argv[1]; out = {}
CL = os.statvfs(R).f_bsize   # 簇大小
seen = {}                    # inode → (大小, 实际占用)：每个文件只算一次的合计
def ondisk(st):
    # ntfs-3g 的 st_blocks：压缩、稀疏的按真正分配的簇；很小的文件放在 MFT 记录里，报的不到一个簇，按 0 算
    b = st.st_blocks * 512
    return b if b >= min(CL, 4096) else 0
def walk(d, rel):
    files = 0; size = 0; kids = []; links = []; disk = 0; shared = 0
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
            else:
                files += 1; size += st.st_size; disk += ondisk(st)
                if st.st_nlink > 1: shared += st.st_size
                seen[st.st_ino] = (st.st_size, ondisk(st))
    out[rel] = {'files': files, 'bytes': size, 'dirs': sorted(kids + links), 'links': sorted(links), 'disk': disk, 'shared': shared}
walk(R, '')
out['#unique'] = {'size': sum(v[0] for v in seen.values()), 'disk': sum(v[1] for v in seen.values())}
json.dump(out, open(sys.argv[2], 'w'), ensure_ascii=False)
print('dirs', len(out) - 1, 'files', sum(v.get('files', 0) for v in out.values()), 'bytes', sum(v.get('bytes', 0) for v in out.values()))
