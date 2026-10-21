import os, shutil, struct, sys
R = sys.argv[1]
def w(p, n):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(b'z' * n)
for j in range(2500): w(os.path.join(R, 'New', 'k%02d' % (j % 25), 'n%05d.bin' % j), (j * 37) % 3000)   # MFT 要变长
w(os.path.join(R, 'New', 'huge.bin'), 3 * 1024 * 1024)
for j in range(0, 5000, 3): os.remove(os.path.join(R, 'Many', 'n%05d.txt' % j))                         # 删掉一些
shutil.rmtree(os.path.join(R, 'Users', 'u1', 'AppData', 'App01'))                                         # 删掉一整个文件夹
os.rename(os.path.join(R, '文档 备份'), os.path.join(R, 'Docs 改名'))                                      # 改名
os.rename(os.path.join(R, 'Moved'), os.path.join(R, 'Users', 'u2', 'MovedHere'))                           # 换位置
with open(os.path.join(R, 'Tmp', 'new.txt'), 'ab') as f: f.write(b'g' * 2 * 1024 * 1024)                  # 变大
os.link(os.path.join(R, 'Big', 'real.bin'), os.path.join(R, 'Users', 'u3', 'hard.bin'))                     # 新的硬链接
os.remove(os.path.join(R, 'Links', 'copy.bin'))                                                            # 少一个硬链接
# 真正的目录挂载点（和 Windows 的 mklink /J 一样：文件夹记录上带重解析点）
j = os.path.join(R, 'Junc'); os.makedirs(j)
tgt = '\\??\\C:\\Big'.encode('utf-16-le'); prn = 'C:\\Big'.encode('utf-16-le')
body = struct.pack('<HHHH', 0, len(tgt), len(tgt) + 2, len(prn)) + tgt + b'\0\0' + prn + b'\0\0'
os.setxattr(j, 'system.ntfs_reparse_data', struct.pack('<IHH', 0xA0000003, len(body), 0) + body)
print('changed')
