#!/usr/bin/env python3
"""
patch-static-ip.py —— 直接对 emb3531-bloader-armbian.img 做"字节级"三处修改（无需 sudo/挂载）：

  1) 静态 IP：把 /usr/lib/systemd/network/80-wifi-adhoc.network 的内容改写成 eth0 静态配置
     * 为什么寄生这个文件：新增文件需要分配 inode/数据块（必须挂载），而它只匹配
       Type=wlan + ad-hoc，有线板子永远不会命中；等以后能进系统了，
       在 /etc/systemd/network/ 里放一个正确的 .network 就能覆盖它并还原。
  2) /etc/shadow：root 密码字段清空（原版 A 里 root 仍有密码哈希）
  3) /etc/ssh/sshd_config：#PermitEmptyPasswords no → PermitEmptyPasswords yes

所有写入都保持"同一数据块内"（inode extent/位图/块计数不变），只更新 i_size 并重算
inode 校验和（ext4 metadata_csum + csum_seed）。
"""
import struct, sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "/home/homodeluna/test-img/emb3531-bloader-armbian.img"
P4  = 557056 * 512

# ---------- CRC32C ----------
_T = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (0x82F63B78 if _c & 1 else 0)
    _T.append(_c)
def crc32c(crc, data):
    for b in data:
        crc = _T[(crc ^ b) & 0xff] ^ (crc >> 8)
    return crc

f = open(IMG, "r+b")
def rd(o, n):
    f.seek(o); return f.read(n)

sb = rd(P4 + 1024, 1024)
bs   = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
ipg  = struct.unpack_from("<I", sb, 0x28)[0]
isz  = struct.unpack_from("<H", sb, 0x58)[0]
first= struct.unpack_from("<I", sb, 0x14)[0]
inc  = struct.unpack_from("<I", sb, 0x60)[0]
dsz  = struct.unpack_from("<H", sb, 0xFE)[0] if inc & 0x80 else 32
seed = struct.unpack_from("<I", sb, 0x270)[0] if inc & 0x2000 else crc32c(0xFFFFFFFF, sb[0x68:0x78])

_tabs = {}
def itab(g):
    if g not in _tabs:
        bgd = rd(P4 + (first + 1) * bs + g * dsz, dsz)
        _tabs[g] = struct.unpack_from("<I", bgd, 8)[0] | (
            (struct.unpack_from("<I", bgd, 40)[0] << 32) if inc & 0x80 and dsz >= 64 else 0)
    return _tabs[g]

def ino_off(n):
    g = (n - 1) // ipg
    return P4 + itab(g) * bs + ((n - 1) % ipg) * isz

def ino_raw(n): return rd(ino_off(n), isz)

def ino_csum(raw, n):
    b = bytearray(raw)
    b[0x7C:0x7E] = b"\0\0"
    if isz > 128: b[0x82:0x84] = b"\0\0"
    c = crc32c(seed, struct.pack("<I", n))
    c = crc32c(c, raw[0x64:0x68])          # i_generation
    return crc32c(c, bytes(b)) & 0xFFFFFFFF

def ino_stored(raw):
    return struct.unpack_from("<H", raw, 0x7C)[0] | (
        (struct.unpack_from("<H", raw, 0x82)[0] << 16) if isz > 128 else 0)

def info(n):
    r = ino_raw(n)
    return (struct.unpack_from("<H", r, 0)[0],
            struct.unpack_from("<I", r, 4)[0] | ((struct.unpack_from("<I", r, 108)[0] << 32) if isz >= 112 else 0),
            r[40:100])

def _walk(node):
    mag, ent, mx, depth = struct.unpack_from("<HHHH", node, 0)
    if mag != 0xf30a: return None
    if depth == 0:
        return [((h << 32) | l, e & 0x7fff, e > 0x8000)
                for _, e, h, l in [struct.unpack_from("<IHHI", node, 12 + k * 12) for k in range(ent)]]
    out = []
    for k in range(ent):
        off = 12 + k * 12
        lo = struct.unpack_from("<I", node, off + 4)[0]
        hi = struct.unpack_from("<H", node, off + 8)[0]
        r = _walk(rd(P4 + ((hi << 32) | lo) * bs, bs))
        if r: out += r
    return out

def extents(n):
    _, _, ib = info(n)
    return _walk(ib)

def data(n):
    m, sz, ib = info(n)
    if (m & 0xF000) == 0xA000: return ib[:sz]
    r = extents(n); out = []
    for st, L, un in r:
        out.append(bytes(L * bs) if un else rd(P4 + st * bs, L * bs))
    return b"".join(out)[:sz]

def ls(n):
    d = data(n); o = {}; p = 0
    while p < len(d):
        ino, rl, nl, ft = struct.unpack_from("<IHBB", d, p)
        if rl == 0: break
        nm = d[p + 8:p + 8 + nl].decode("utf8", "replace")
        if nm not in (".", "..") and ino: o[nm] = (ino, ft)
        p += rl
    return o

def path(p):
    cur = 2
    for part in [x for x in p.split("/") if x]:
        e = ls(cur)
        if part not in e: return None
        cur = e[part][0]
    return cur

def write_inplace(n, new: bytes, label: str):
    """在已分配的块内原地改写文件内容（不分配/不释放块），更新 i_size 并重算 inode 校验和"""
    r = extents(n)
    cap = sum(L for _, L, _ in r) * bs
    assert len(new) <= cap, f"{label}: 新内容 {len(new)}B 超出已分配 {cap}B"
    # 写入数据块（末块补零，抹掉旧内容残留）
    off = 0
    for st, L, un in r:
        chunk = new[off:off + L * bs]
        if not chunk and off >= len(new):
            break
        f.seek(P4 + st * bs)
        f.write(chunk.ljust(L * bs, b"\0"))
        off += L * bs
    # 更新 i_size 与 inode 校验和
    o = ino_off(n); raw = bytearray(rd(o, isz))
    struct.pack_into("<I", raw, 4, len(new) & 0xFFFFFFFF)
    struct.pack_into("<I", raw, 0x6C, (len(new) >> 32) & 0xFFFFFFFF)
    c = ino_csum(bytes(raw), n)
    struct.pack_into("<H", raw, 0x7C, c & 0xFFFF)
    if isz > 128: struct.pack_into("<H", raw, 0x82, (c >> 16) & 0xFFFF)
    f.seek(o); f.write(bytes(raw)); f.flush()
    # 复核
    got = data(n); raw2 = ino_raw(n)
    ok = got == new and ino_csum(raw2, n) == ino_stored(raw2)
    print(f"   {label}: inode={n} 新大小={len(new)}B(容量{cap}B) 内容一致={got == new} "
          f"inode校验={'PASS' if ino_csum(raw2, n) == ino_stored(raw2) else 'FAIL'}")
    assert ok, f"{label} 写入校验失败"

# ---------------- 1) 静态 IP ----------------
NET = b"""# static IPv4 for eth0 (patched in place; original file was systemd's 80-wifi-adhoc.network)
[Match]
Name=eth0
Name=en*

[Network]
Address=192.168.0.123/24
Gateway=192.168.0.1
DNS=192.168.0.1
DNS=8.8.8.8
IPv6AcceptRA=no
LinkLocalAddressing=no
"""
print("== 1) 静态 IP（192.168.0.123/24, gw .1, dns .1） ==")
n = path("/usr/lib/systemd/network/80-wifi-adhoc.network")
assert n, "找不到 80-wifi-adhoc.network"
print("   原内容前两行:", data(n).decode("utf8", "replace").splitlines()[6:8])
write_inplace(n, NET, "80-wifi-adhoc.network → eth0 static")

# ---------------- 2) root 空密码 ----------------
print("\n== 2) root 密码清空 ==")
n = path("/etc/shadow")
old = data(n)
lines = old.decode().splitlines()
new_lines = []
for l in lines:
    if l.startswith("root:"):
        fl = l.split(":"); print("   改前 root 密码字段长度 =", len(fl[1])); fl[1] = ""; l = ":".join(fl)
    new_lines.append(l)
write_inplace(n, ("\n".join(new_lines) + "\n").encode(), "/etc/shadow")
print("   改后:", [l for l in data(n).decode().splitlines() if l.startswith("root:")][0])

# ---------------- 3) SSH 允许空密码 ----------------
print("\n== 3) sshd_config ==")
n = path("/etc/ssh/sshd_config")
old = data(n)
new = old.replace(b"#PermitEmptyPasswords no", b"PermitEmptyPasswords yes")
assert new != old, "未找到 #PermitEmptyPasswords no"
write_inplace(n, new, "sshd_config")

print("\n全部完成。")
f.close()