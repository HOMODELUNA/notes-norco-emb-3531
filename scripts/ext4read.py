"""ext4read.py —— 只读访问镜像内 ext4 的小工具（无需 root、无需 mount）

用法：
    from ext4read import FS
    fs = FS("/path/to/image", 557056*512)      # 分区起始字节偏移
    fs.label            # 超级块卷标
    fs.data(fs.path("/etc/fstab"))
    list(fs.walk())     # 迭代 (路径, 类型, inode)；类型 1=文件 2=目录 7=符号链接
"""
import struct

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


class FS:
    def __init__(s, path, off):
        s.f = open(path, "rb")
        s.P = off
        sb = s.rd(off + 1024, 1024)
        s.sb = sb
        s.bs = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
        s.ipg = struct.unpack_from("<I", sb, 0x28)[0]
        s.isz = struct.unpack_from("<H", sb, 0x58)[0]
        s.first = struct.unpack_from("<I", sb, 0x14)[0]
        s.inc = struct.unpack_from("<I", sb, 0x60)[0]
        s.dsz = struct.unpack_from("<H", sb, 0xFE)[0] if s.inc & 0x80 else 32
        s.label = sb[0x78:0x88].split(b"\0")[0].decode("utf8", "replace")
        s.bcnt = struct.unpack_from("<I", sb, 0x04)[0]
        s.free = struct.unpack_from("<I", sb, 0x0C)[0]
        s.uuid = sb[0x68:0x78].hex()
        s._tabs = {}

    def rd(s, o, n):
        s.f.seek(o)
        return s.f.read(n)

    def itab(s, g):
        if g not in s._tabs:
            b = s.rd(s.P + (s.first + 1) * s.bs + g * s.dsz, s.dsz)
            s._tabs[g] = struct.unpack_from("<I", b, 8)[0] | (
                (struct.unpack_from("<I", b, 40)[0] << 32) if s.inc & 0x80 and s.dsz >= 64 else 0)
        return s._tabs[g]

    def info(s, n):
        """返回 (mode, 大小, inode 内联区 40:100)"""
        g = (n - 1) // s.ipg
        o = s.P + s.itab(g) * s.bs + ((n - 1) % s.ipg) * s.isz
        r = s.rd(o, s.isz)
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
            off = 12 + k * 12
            lo = struct.unpack_from("<I", node, off + 4)[0]
            hi = struct.unpack_from("<H", node, off + 8)[0]
            r = s._walk_ext(s.rd(s.P + ((hi << 32) | lo) * s.bs, s.bs))
            if r:
                out += r
        return out

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

    def walk(s, n=2, pre=""):
        for nm, (ino, ft) in s.ls(n).items():
            p = pre + "/" + nm
            yield p, ft, ino
            if ft == 2:
                yield from s.walk(ino, pre=p)

    def text(s, p):
        n = s.path(p)
        return None if n is None else s.data(n).decode("utf8", "replace")