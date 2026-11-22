#!/bin/bash
# board-kexec-test.sh —— 用 kexec 试跑 p3 里的新内核，不必刷机
#
# 用法：
#   ./board-kexec-test.sh                     # 用默认 dtb（PCIe 打开）
#   ./board-kexec-test.sh /mnt/p3/dtb/rk3399-emb3531-nopcie.dtb    # 用 PCIe 关掉的 dtb
#
# 失败时的恢复：断电重启。`default` 仍是 l0，会回到当前可用系统。
set -euo pipefail

DTB=${1:-/mnt/p3/dtb/rk3399-emb3531-emb.dtb}
KERNEL=/mnt/p3/Image-emb3531
CMDLINE="root=LABEL=rootfs rootwait rw console=ttyS2,115200 console=tty0 net.ifnames=0 earlycon=uart8250,mmio32,0xff1a0000"

[ -f "$KERNEL" ] || { echo "缺 $KERNEL，先运行 board-build-kernel.sh install"; exit 1; }
[ -f "$DTB" ] || { echo "缺 $DTB"; exit 1; }

echo "内核: $KERNEL ($(stat -c%s "$KERNEL") 字节)"
echo "设备树: $DTB"
echo "参数: $CMDLINE"
echo

kexec --kexec-file-syscall -l "$KERNEL" --dtb="$DTB" --command-line="$CMDLINE"
echo "kexec_loaded = $(cat /sys/kernel/kexec_loaded)"
echo
echo "5 秒后切换内核；若想取消，按 Ctrl-C"
sleep 5
sync
systemctl kexec