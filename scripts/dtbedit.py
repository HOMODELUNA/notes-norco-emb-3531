#!/usr/bin/env python3
"""dtbedit.py —— 无需 dtc 的 DTB 读写工具（可改变属性值长度）

用法示例：
    python3 dtbedit.py in.dtb out.dtb set /pcie@f8000000 status disabled
    python3 dtbedit.py in.dtb out.dtb del /pcie@f8000000 status
    python3 dtbedit.py in.dtb --dump /pcie@f8000000

支持的 set 值：字符串 / u32 列表（形如 "0x4 0x1c 0x0"） / 自动判断。
"""

import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


class Node:
    __slots__ = ('name', 'props', 'children')

    def __init__(self, name):
        self.name = name
        self.props = []          # [(name, value_bytes)]
        self.children = []

    def prop(self, name):
        for n, v in self.props:
            if n == name:
                return v
        return None

    def set_prop(self, name, value):
        for i, (n, _) in enumerate(self.props):
            if n == name:
                self.props[i] = (name, value)
                return False
        self.props.append((name, value))
        return True

    def del_prop(self, name):
        before = len(self.props)
        self.props = [(n, v) for n, v in self.props if n != name]
        return len(self.props) != before


def load(path):
    d = open(path, 'rb').read()
    (magic, totalsize, off_struct, off_strings, off_rsv,
     version, last_comp, boot_cpuid, size_strings, size_struct) = \
        struct.unpack('>10I', d[:40])
    if magic != FDT_MAGIC:
        raise SystemExit(f'不是合法 DTB: magic={magic:#x}')

    # memreserve
    rsv = []
    p = off_rsv
    while True:
        addr, size = struct.unpack('>QQ', d[p:p+16])
        p += 16
        if addr == 0 and size == 0:
            break
        rsv.append((addr, size))

    strings = d[off_strings:off_strings + size_strings]

    def s(off):
        e = strings.index(b'\0', off)
        return strings[off:e].decode('latin1')

    root = Node('')
    stack = [root]
    p = off_struct
    while True:
        tag = struct.unpack('>I', d[p:p+4])[0]
        p += 4
        if tag == FDT_BEGIN_NODE:
            p2 = p
            while d[p2] != 0:
                p2 += 1
            name = d[p:p2].decode('latin1')
            p = (p2 + 1 + 3) & ~3
            n = Node(name)
            stack[-1].children.append(n)
            stack.append(n)
        elif tag == FDT_END_NODE:
            stack.pop()
        elif tag == FDT_PROP:
            ln, nameoff = struct.unpack('>II', d[p:p+8])
            p += 8
            val = d[p:p+ln]
            p = (p + ln + 3) & ~3
            stack[-1].props.append((s(nameoff), val))
        elif tag == FDT_NOP:
            pass
        elif tag == FDT_END:
            break
        else:
            raise SystemExit(f'未知 tag {tag} at {p}')
    # 结构块里的第一个 BEGIN_NODE 才是真正的根节点
    if len(root.children) == 1 and not root.props:
        root = root.children[0]
    return root, rsv, boot_cpuid

def save(root, rsv, boot_cpuid, path):
    strings = bytearray()
    index = {}

    def name_off(name):
        if name in index:
            return index[name]
        off = len(strings)
        strings.extend(name.encode('latin1') + b'\0')
        index[name] = off
        return off

    body = bytearray()

    def emit(node):
        pad = (4 - (len(body) % 4)) % 4
        body.extend(b'\0' * pad)
        body.extend(struct.pack('>I', FDT_BEGIN_NODE))
        body.extend(node.name.encode('latin1') + b'\0')
        pad = (4 - (len(body) % 4)) % 4
        body.extend(b'\0' * pad)
        for pname, pval in node.props:
            body.extend(struct.pack('>III', FDT_PROP, len(pval), name_off(pname)))
            body.extend(pval)
            pad = (4 - (len(pval) % 4)) % 4
            body.extend(b'\0' * pad)
        for ch in node.children:
            emit(ch)
        pad = (4 - (len(body) % 4)) % 4
        body.extend(b'\0' * pad)
        body.extend(struct.pack('>I', FDT_END_NODE))

    emit(root)
    body.extend(struct.pack('>I', FDT_END))

    off_rsv = 40                      # 头部 40 字节后紧跟 memreserve
    rsv_blob = bytearray()
    for a, s in rsv:
        rsv_blob.extend(struct.pack('>QQ', a, s))
    rsv_blob.extend(b'\0' * 16)

    off_struct = off_rsv + len(rsv_blob)
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)

    hdr = struct.pack('>10I', FDT_MAGIC, total, off_struct, off_strings, off_rsv,
                      17, 16, boot_cpuid, len(strings), len(body))
    open(path, 'wb').write(hdr + bytes(rsv_blob) + bytes(body) + bytes(strings))
    return total


def find(root, path):
    if path in ('/', ''):
        return root
    node = root
    for part in [x for x in path.split('/') if x]:
        hit = None
        for ch in node.children:
            if ch.name == part or ch.name.split('@')[0] == part:
                hit = ch
                break
        if hit is None:
            raise SystemExit(f'找不到节点 {path}（在 {part} 处失败）')
        node = hit
    return node


def parse_value(text):
    if text.startswith('0x') or ' ' in text:
        return b''.join(struct.pack('>I', int(x, 0)) for x in text.split())
    return text.encode('latin1') + b'\0'


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(__doc__)
        raise SystemExit(1)
    src, dst, action = sys.argv[1], sys.argv[2], sys.argv[3]
    root, rsv, cpuid = load(src)
    if action == 'set':
        node_path, prop, value = sys.argv[4], sys.argv[5], sys.argv[6]
        n = find(root, node_path)
        added = n.set_prop(prop, parse_value(value))
        print(f'{"新增" if added else "修改"} {node_path}[{prop}] = {value}')
        total = save(root, rsv, cpuid, dst)
        print(f'已写出 {dst}（{total} 字节）')
    elif action == 'del':
        node_path, prop = sys.argv[4], sys.argv[5]
        n = find(root, node_path)
        if not n.del_prop(prop):
            raise SystemExit(f'{node_path} 没有属性 {prop}')
        print(f'删除 {node_path}[{prop}]')
        total = save(root, rsv, cpuid, dst)
        print(f'已写出 {dst}（{total} 字节）')
    elif action == 'dump':
        want = sys.argv[4] if len(sys.argv) > 4 else '/'
        n = find(root, want)
        print(f'节点 {want}: 属性 {len(n.props)} 个, 子节点 {len(n.children)} 个')
        for k, v in n.props:
            try:
                txt = v.decode('latin1').strip('\0')
                if not txt.isprintable():
                    raise ValueError
            except Exception:
                txt = ' '.join(str(x) for x in struct.unpack(f'>{len(v)//4}I', v[:len(v)//4*4])) if len(v) % 4 == 0 else v.hex()
            print(f'  {k:32s} {txt[:70]}')
    else:
        raise SystemExit(f'未知动作 {action}')