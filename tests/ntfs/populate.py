import os, random, sys
R = sys.argv[1]; random.seed(7)
def w(p, n, sparse=False):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        if sparse: f.truncate(n)
        else: f.write(os.urandom(n) if n < 200000 else b'x' * n)
# 普通树：多层、很多小文件（常驻在 MFT 记录里）和大一点的文件
for i in range(40):
    d = os.path.join(R, 'Users', 'u%d' % (i % 4), 'AppData', 'App%02d' % i)
    for j in range(random.randint(5, 60)): w(os.path.join(d, 'f%03d.dat' % j), random.choice([0, 10, 300, 700, 900, 5000, 70000, 300000]))
# 一个文件夹里 5000 个文件（目录索引是 B 树）
for j in range(5000): w(os.path.join(R, 'Many', 'n%05d.txt' % j), random.randint(0, 2000))
# 大文件（稀疏，逻辑大小大）
w(os.path.join(R, 'Big', 'disk.vhdx'), 3 * 1024 * 1024 * 1024, sparse=True)
w(os.path.join(R, 'Big', 'movie.mkv'), 150 * 1024 * 1024, sparse=True)
w(os.path.join(R, 'Big', 'real.bin'), 5 * 1024 * 1024)
# 中文、表情、很长的名字、深层目录
w(os.path.join(R, '文档 备份', '照片 2024', '😀 笑脸.jpg'), 2 * 1024 * 1024)
w(os.path.join(R, '文档 备份', 'x' * 200 + '.txt'), 1234)
p = R
for k in range(30): p = os.path.join(p, 'deep%02d' % k)
w(os.path.join(p, 'bottom.bin'), 1500000)
# 硬链接：少量，以及一个有 300 个名字的文件（名字放不下一条记录，会用到属性列表和续页）
w(os.path.join(R, 'Links', 'orig.bin'), 2 * 1024 * 1024)
os.link(os.path.join(R, 'Links', 'orig.bin'), os.path.join(R, 'Links', 'copy.bin'))
os.makedirs(os.path.join(R, 'Links2'), exist_ok=True)
os.link(os.path.join(R, 'Links', 'orig.bin'), os.path.join(R, 'Links2', 'other.bin'))
w(os.path.join(R, 'ManyLinks', 'base.dat'), 4096)
for k in range(300): os.link(os.path.join(R, 'ManyLinks', 'base.dat'), os.path.join(R, 'ManyLinks', 'link_with_a_long_name_%03d.dat' % k))
# 碎片很多的大文件：交替追加，逼出很多段（也可能用到属性列表）
fa = open(os.path.join(R, 'Frag', 'a.bin'), 'wb') if os.makedirs(os.path.join(R, 'Frag'), exist_ok=True) is None else None
for k in range(1500):
    fa.write(b'a' * 4096); fa.flush()
    with open(os.path.join(R, 'Frag', 'pad%04d' % k), 'wb') as g: g.write(b'p' * 4096)
fa.close()
for k in range(0, 1500, 2): os.remove(os.path.join(R, 'Frag', 'pad%04d' % k))
# 链接：文件和文件夹的符号链接（NTFS 上是重解析点）
os.symlink(os.path.join(R, 'Big'), os.path.join(R, 'LinkToBig'))
os.symlink(os.path.join(R, 'Big', 'real.bin'), os.path.join(R, 'Users', 'u0', 'linkfile'))
# 备用数据流（不算大小）
w(os.path.join(R, 'ADS', 'host.txt'), 100)
os.setxattr(os.path.join(R, 'ADS', 'host.txt'), 'user.secret', b's' * 50000)
# 删掉、改名、移动
w(os.path.join(R, 'Tmp', 'gone.bin'), 1000000); os.remove(os.path.join(R, 'Tmp', 'gone.bin'))
w(os.path.join(R, 'Tmp', 'old.txt'), 77); os.rename(os.path.join(R, 'Tmp', 'old.txt'), os.path.join(R, 'Tmp', 'new.txt'))
os.makedirs(os.path.join(R, 'Tmp', 'dirA', 'sub'), exist_ok=True); w(os.path.join(R, 'Tmp', 'dirA', 'sub', 'm.bin'), 3000)
os.rename(os.path.join(R, 'Tmp', 'dirA'), os.path.join(R, 'Moved'))
os.makedirs(os.path.join(R, 'Empty'), exist_ok=True)
print('populated')
