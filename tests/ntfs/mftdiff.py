# 两个镜像的 MFT 逐条比较，打印改动过的记录号（模拟变更日志给出的记录号）
import struct, sys
def mft(path):
    f = open(path, 'rb'); boot = f.read(512)
    bps = struct.unpack_from('<H', boot, 11)[0]; spc = boot[13]; cl = bps * spc
    lcn = struct.unpack_from('<q', boot, 0x30)[0]; cpr = struct.unpack_from('<b', boot, 0x40)[0]
    rs = cpr * cl if cpr > 0 else 1 << -cpr
    f.seek(lcn * cl); r0 = bytearray(f.read(rs))
    a = struct.unpack_from('<H', r0, 0x14)[0]; runs = []; size = 0
    while True:
        t, ln = struct.unpack_from('<II', r0, a)
        if t == 0xFFFFFFFF: break
        if t == 0x80 and r0[a + 9] == 0:
            size = struct.unpack_from('<q', r0, a + 0x30)[0]
            o = a + struct.unpack_from('<H', r0, a + 0x20)[0]; cur = 0
            while r0[o]:
                h = r0[o]; lb = h & 15; ob = h >> 4; o += 1
                l = int.from_bytes(r0[o:o + lb], 'little'); o += lb
                d = int.from_bytes(r0[o:o + ob], 'little', signed=True); o += ob
                cur += d; runs.append((cur * cl, l * cl))
        a += ln
    data = b''
    for off, l in runs: f.seek(off); data += f.read(l)
    return rs, data[:size]
rs, a = mft(sys.argv[1]); _, b = mft(sys.argv[2])
n = max(len(a), len(b)) // rs
import struct as st
def base(buf, i):
    r = buf[i * rs:(i + 1) * rs]
    if len(r) < 0x28 or r[:4] != b'FILE': return i
    return (st.unpack_from('<Q', r, 0x20)[0] & 0xFFFFFFFFFFFF) or i
ch = sorted({base(b, i) if i * rs < len(b) else i for i in range(n) if a[i * rs:(i + 1) * rs] != b[i * rs:(i + 1) * rs]} | {base(a, i) for i in range(n) if i * rs < len(a) and a[i * rs:(i + 1) * rs] != b[i * rs:(i + 1) * rs]})
print(' '.join(map(str, ch)))
