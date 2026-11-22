#!/usr/bin/env python3
"""set-default-label.py —— 无 sudo 修改 extlinux.conf 的默认启动项

用法：
    python3 set-default-label.py emb3531-b-with-a-kernel.img l0
    python3 set-default-label.py emb3531-b-with-a-kernel.img l1
    python3 set-default-label.py p3-min.img l1 0      # 分区镜像，偏移填 0

只改 `default` 一行，其余内容保持不变。写入在同一数据块内完成，
并重算 inode 校验和（metadata_csum + csum_seed）。
"""
import re
import sys

from imgfile import Part

P3_OFF = 32768 * 512          # 整盘镜像里 p3 的起始偏移；分区镜像用 0
CONF = "/extlinux/extlinux.conf"


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[2] not in ("l0", "l1"):
        print(__doc__)
        return 1
    img, label = sys.argv[1], sys.argv[2]
    off = int(sys.argv[3]) if len(sys.argv) == 4 else P3_OFF
    p3 = Part(img, off)
    old = p3.data(p3.path(CONF)).decode()
    new = re.sub(r"(?m)^default .*$", f"default {label}", old)
    if new == old:
        print(f"  已是 default {label}，无需修改")
        return 0
    print(f"  {old.splitlines()[0]}  →  default {label}")
    ok = p3.write_inplace(CONF, new.encode())
    print(f"  {p3.data(p3.path(CONF)).decode().splitlines()[0]}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())