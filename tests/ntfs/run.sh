#!/bin/bash
# 在 Linux 上用真的 NTFS 镜像测试「直接读文件表」和「按改动增量更新」。
# 需要：root、ntfs-3g（mkntfs、ntfs-3g、FUSE）、python3、PowerShell 7（pwsh）。
# 用法：sudo bash tests/ntfs/run.sh [工作目录，默认 /tmp/clearc-ntfs]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${1:-/tmp/clearc-ntfs}"; mkdir -p "$W/mnt"; cd "$W"
PWSH="${PWSH:-pwsh}"
fail=0
check() { # 期望值 实际值 说明
  local out; out=$(python3 "$HERE/cmp.py" "$1" "$2" | tail -1)
  local n; n=$(echo "$out" | sed 's/.*problems //')
  # ntfs-3g 建的符号链接是 Interix 格式的普通文件（Windows 上也是文件），最多差 5 处，见 README
  if [ "$n" -le "$3" ]; then echo "ok   $4 ($out)"; else echo "FAIL $4 ($out)"; python3 "$HERE/cmp.py" "$1" "$2" | head -20; fail=1; fi
}
mk() { rm -f "$1"; truncate -s "$2" "$1"; mkntfs -F -Q -q $3 "$1" >/dev/null 2>&1; }
# 1. 各种文件：硬链接（含 300 个名字的）、稀疏、碎片、备用数据流、很深的路径、中文和表情名字、链接
mk img1.ntfs 2G ""
ntfs-3g img1.ntfs mnt -o rw,compression,streams_interface=xattr; python3 "$HERE/populate.py" mnt; python3 "$HERE/truth.py" mnt truth1.json; fusermount -u mnt
"$PWSH" -NoProfile -File "$HERE/scan.ps1" img1.ntfs mft1.json
check truth1.json mft1.json 5 "full read"
# 2. 改动以后：增量更新要和整份重读一样
cp --sparse=always img1.ntfs img2.ntfs
ntfs-3g img2.ntfs mnt -o rw,streams_interface=xattr; python3 "$HERE/change.py" mnt; python3 "$HERE/truth.py" mnt truth2.json; fusermount -u mnt
python3 "$HERE/mftdiff.py" img1.ntfs img2.ntfs > frns2.txt
"$PWSH" -NoProfile -File "$HERE/scan.ps1" img2.ntfs full2.json
"$PWSH" -NoProfile -File "$HERE/scan.ps1" img1.ntfs inc2.json -Then img2.ntfs -Frns frns2.txt
check truth2.json full2.json 5 "full read after changes"
check full2.json inc2.json 0 "incremental = full"
# 3. 不同的簇和记录大小
for v in "a:-c 4096" "b:-c 65536" "c:-s 4096 -c 4096"; do
  n=${v%%:*}; o=${v#*:}; mk geo$n.ntfs 400M "$o"
  ntfs-3g geo$n.ntfs mnt -o rw; python3 - mnt <<'PY'
import os, sys
R = sys.argv[1]
for r in range(6):
    d = os.path.join(R, 'round%02d' % r); os.makedirs(d)
    for j in range(300): open(os.path.join(d, 'f%04d' % j), 'wb').write(b'q' * (j % 1500))
    open(os.path.join(R, 'filler%02d.bin' % r), 'wb').write(b'F' * 6 * 1024 * 1024)
PY
  python3 "$HERE/truth.py" mnt tgeo$n.json; fusermount -u mnt
  "$PWSH" -NoProfile -File "$HERE/scan.ps1" geo$n.ntfs mgeo$n.json
  check tgeo$n.json mgeo$n.json 0 "geometry $o"
done
[ $fail -eq 0 ] && echo "all NTFS image tests passed" || { echo "some NTFS image tests FAILED"; exit 1; }
