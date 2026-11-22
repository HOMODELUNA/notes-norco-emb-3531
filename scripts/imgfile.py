#!/usr/bin/env python3
"""imgfile.py —— 在镜像内部原地改写一个已有文件（不 mount、不需 root）

约束：新内容必须不超出该文件已分配的块数（不会分配/释放块），
     改写后同步更新 inode 的 i_size 与 ext4 元数据校验和（metadata_csum + csum_seed）。

用法：
    python3 imgfile.py <镜像> <分区偏移字节> <分区内路径> <新内容文件>
    python3 imgfile.py emb3531-b-with-a-kernel.img 16777216 /extlinux/extlinux.conf new.conf
"""
import struct
import sys

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


class Part:
    def __init__(s, path, off):
        s.f = open(path, "r+b")
        s.P = off
        sb = s.rd(off + 1024, 1024)
        s.bs = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
        s.ipg = struct.unpack_from("<I", sb, 0x28)[0]
        s.isz = struct.unpack_from("<H", sb, 0x58)[0]
        s.first = struct.unpack_from("<I", sb, 0x14)[0]
        s.inc = struct.unpack_from("<I", sb, 0x60)[0]
        s.dsz = struct.unpack_from("<H", sb, 0xFE)[0] if s.inc & 0x80 else 32
        s.seed = struct.unpack_from("<I", sb, 0x270)[0] if s.inc & 0x2000 else crc32c(0xFFFFFFFF, sb[0x68:0x78])
        s.tabs = {}

    def rd(s, o, n):
        s.f.seek(o)
        return s.f.read(n)

    def itab(s, g):
        if g not in s.tabs:
            b = s.rd(s.P + (s.first + 1) * s.bs + g * s.dsz, s.dsz)
            s.tabs[g] = struct.unpack_from("<I", b, 8)[0] | (
                (struct.unpack_from("<I", b, 40)[0] << 32) if s.inc & 0x80 and s.dsz >= 64 else 0)
        return s.tabs[g]

    def ino_off(s, n):
        return s.P + s.itab((n - 1) // s.ipg) * s.bs + ((n - 1) % s.ipg) * s.isz

    def info(s, n):
        r = s.rd(s.ino_off(n), s.isz)
        return (struct.unpack_from("<H", r, 0)[0],
                struct.unpack_from("<I", r, 4)[0] | ((struct.unpack_from("<I", r, 108)[0] << 32) if s.isz >= 112 else 0),
                r[40:100])

    def _walk_ext(s, node):
        mag, ent, mx, depth = struct.unpack_from("<HHHH", node, 0)
        if mag != 0xF30A:
            return None
        if depth == 0:
            return [((h << 32) | l, e & 0x7FFF, e > 0x8000)
                    for _, e, h, l in [struct.unpack_from("<IHHI", node, 12 + k * 12) for k in range(ent)]]
        out = []
        for k in range(ent):
            o = 12 + k * 12
            lo = struct.unpack_from("<I", node, o + 4)[0]
            hi = struct.unpack_from("<H", node, o + 8)[0]
            r = s._walk_ext(s.rd(s.P + ((hi << 32) | lo) * s.bs, s.bs))
            if r:
                out += r
        return out

    def extents(s, n):
        return s._walk_ext(s.info(n)[2]) or []

    def data(s, n):
        m, sz, ib = s.info(n)
        if (m & 0xF000) == 0xA000:
            return ib[:sz]
        r = s._walk_ext(ib)
        if r is None:
            out = []
            for k in range(12):
                blk = struct.unpack_from("<I", ib, k * 4)[0]
                if blk:
                    out.append(s.rd(s.P + blk * s.bs, s.bs))
        else:
            out = [bytes(L * s.bs) if un else s.rd(s.P + st * s.bs, L * s.bs) for st, L, un in r]
        return b"".join(out)[:sz]

    def ls(s, n):
        d = s.data(n)
        o = {}
        p = 0
        while p < len(d):
            ino, rl, nl, ft = struct.unpack_from("<IHBB", d, p)
            if rl == 0:
                break
            nm = d[p + 8:p + 8 + nl].decode("utf8", "replace")
            if nm not in (".", "..") and ino:
                o[nm] = (ino, ft)
            p += rl
        return o

    def path(s, p):
        cur = 2
        for part in [x for x in p.split("/") if x]:
            e = s.ls(cur)
            if part not in e:
                return None
            cur = e[part][0]
        return cur

    def ino_csum(s, raw, n):
        b = bytearray(raw)
        b[0x7C:0x7E] = b"\0\0"
        if s.isz > 128:
            b[0x82:0x84] = b"\0\0"
        c = crc32c(s.seed, struct.pack("<I", n))
        c = crc32c(c, raw[0x64:0x68])
        return crc32c(c, bytes(b)) & 0xFFFFFFFF

    def write_inplace(s, path, new):
        n = s.path(path)
        assert n, f"文件不存在: {path}"
        r = s.extents(n)
        cap = sum(L for _, L, _ in r) * s.bs
        assert len(new) <= cap, f"{path}: 新内容 {len(new)}B 超过已分配 {cap}B"
        off = 0
        for st, L, un in r:
            chunk = new[off:off + L * s.bs]
            if not chunk:
                break
            s.f.seek(s.P + st * s.bs)
            s.f.write(chunk.ljust(L * s.bs, b"\0"))
            off += L * s.bs
        o = s.ino_off(n)
        raw = bytearray(s.rd(o, s.isz))
        struct.pack_into("<I", raw, 4, len(new) & 0xFFFFFFFF)
        struct.pack_into("<I", raw, 0x6C, (len(new) >> 32) & 0xFFFFFFFF)
        c = s.ino_csum(bytes(raw), n)
        struct.pack_into("<H", raw, 0x7C, c & 0xFFFF)
        if s.isz > 128:
            struct.pack_into("<H", raw, 0x82, (c >> 16) & 0xFFFF)
        s.f.seek(o)
        s.f.write(bytes(raw))
        s.f.flush()
        got = s.data(n)
        chk = s.ino_csum(s.rd(o, s.isz), n) == (struct.unpack_from("<H", s.rd(o, s.isz), 0x7C)[0] |
                                                 ((struct.unpack_from("<H", s.rd(o, s.isz), 0x82)[0] << 16) if s.isz > 128 else 0))
        print(f"  {path}: inode={n} 新大小={len(new)}B 容量={cap}B 内容一致={got == new} inode校验={'PASS' if chk else 'FAIL'}")
        return got == new and chk


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    img, off, path, src = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    new = open(src, "rb").read()
    p = Part(img, off)
    print(f"改写前 {path} = {p.info(p.path(path))[1]} B")
    ok = p.write_inplace(path, new)
    sys.exit(0 if ok else 1)