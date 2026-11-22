#!/usr/bin/env python3
"""gpio-set.py —— 用 GPIO v2 uAPI 直接拉住一根 GPIO 线（不依赖 libgpiod 版本）

用法：
    python3 gpio-set.py <chip 号或 /dev/gpiochipN> <线号> <0|1> [保持秒数，默认 300]

例子（把 GPIO4_D4 拉高并保持 180 秒）：
    python3 gpio-set.py 4 28 1 180 &
    lsusb | grep -i 0bda
    dmesg | tail -20

说明：脚本会保持文件描述符不关闭，因此线一直由本进程占用（值保持）。
     Ctrl-C 或计时到点退出后，线被释放，引脚回到输入状态。
"""
import fcntl
import os
import struct
import sys
import time

# ioctl：方向 3（读写）| 结构体大小 << 16 | 0xB4 << 8 | 序号
GET_LINE = (3 << 30) | (592 << 16) | (0xB4 << 8) | 0x07   # gpio_v2_line_request
SET_VALS = (3 << 30) | (16 << 16) | (0xB4 << 8) | 0x0F    # gpio_v2_line_values
GET_VALS = (3 << 30) | (16 << 16) | (0xB4 << 8) | 0x0E

FLAG_OUTPUT = 1 << 3

# gpio_v2_line_request 内部偏移
OFF_OFFSETS = 0          # __u32 offsets[64]
OFF_CONSUMER = 256       # char consumer[32]
OFF_CONFIG = 288         # struct gpio_v2_line_config
OFF_NUM_LINES = 560      # __u32 num_lines
OFF_FD = 588             # __s32 fd


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    chip = sys.argv[1]
    line = int(sys.argv[2])
    value = 1 if int(sys.argv[3]) else 0
    hold = int(sys.argv[4]) if len(sys.argv) > 4 else 300
    path = chip if chip.startswith("/dev/") else "/dev/gpiochip%s" % chip

    fd = os.open(path, os.O_RDONLY)
    req = bytearray(592)
    struct.pack_into("<I", req, OFF_OFFSETS, line)
    req[OFF_CONSUMER:OFF_CONSUMER + 13] = b"gpio-set-test"
    struct.pack_into("<Q", req, OFF_CONFIG, FLAG_OUTPUT)      # config.flags
    struct.pack_into("<I", req, OFF_CONFIG + 8, 0)            # config.num_attrs
    struct.pack_into("<I", req, OFF_NUM_LINES, 1)

    try:
        fcntl.ioctl(fd, GET_LINE, req, True)
    except OSError as e:
        print("申请 %s 线 %d 失败：%s" % (path, line, e))
        print("常见原因：该线已被驱动占用，或线号超出范围")
        return 2
    lfd = struct.unpack_from("<i", req, OFF_FD)[0]
    if lfd < 0:
        print("申请失败，返回 %d" % lfd)
        return 2

    vals = struct.pack("<QQ", value, 1)
    fcntl.ioctl(lfd, SET_VALS, vals, True)
    rb = fcntl.ioctl(lfd, GET_VALS, bytearray(16), True)
    bits, mask = struct.unpack("<QQ", rb)
    print("%s 线 %d 已设为输出，当前值=%d（回读 bits=%d mask=%d）"
          % (path, line, value, bits, mask))
    print("保持 %d 秒；结束时按 Ctrl-C" % hold)

    try:
        end = time.time() + hold
        while time.time() < end:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    print("释放线")
    os.close(lfd)
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())