#!/bin/bash
# pcie-test.sh —— PCIe 转 SATA 逐项诊断（在板子上以 root 执行）
#
# 用法：
#   /root/pcie-test.sh              正常测试（默认保持引脚 180 秒）
#   HOLD=300 /root/pcie-test.sh     指定保持时长
#   /root/pcie-test.sh release      只释放第 29 线，不做探测
set -u

CHIP=${CHIP:-gpiochip4}
LINE=${LINE:-29}
HOLD=${HOLD:-180}

line_info(){
	gpioinfo -c "$CHIP" 2>/dev/null | sed -n "$((LINE+2))p" | sed 's/^[[:space:]]*/    /'
}

if [ "${1:-}" = "release" ]; then
	echo "== 释放第 $LINE 线 =="
	pkill -f 'gpioset -p' 2>/dev/null
	sleep 1
	pgrep -a gpioset || echo "  已无 gpioset 进程"
	line_info
	exit 0
fi

echo "===== 0 环境 ====="
echo "  内核: $(uname -r)"
grep -q 'pcie_aspm=off' /proc/cmdline && echo "  pcie_aspm=off: 有" || echo "  pcie_aspm=off: 无"
echo "  lspci 设备数: $(lspci 2>/dev/null | wc -l)"

echo
echo "===== 1 释放第 $LINE 线 ====="
pkill -f 'gpioset -p' 2>/dev/null
sleep 1
pgrep -a gpioset || echo "  已无 gpioset 进程"
line_info

echo
echo "===== 2 拉高第 $LINE 线并保持 $HOLD 秒 ====="
gpioset -p "${HOLD}s" -C perst -c "$CHIP" "$LINE=1" &
GSPID=$!
sleep 2
line_info
echo "  >>> 请观察扩展板指示灯，3 秒后继续"
sleep 3

echo
echo "===== 3 PHY 寄存器 ====="
printf "  0xff77f7b0 (lane A~D 状态) = %s\n" "$(busybox devmem 0xff77f7b0 32 2>/dev/null || echo 读取失败)"
printf "  0xff77f780 (PHY 状态)      = %s\n" "$(busybox devmem 0xff77f780 32 2>/dev/null || echo 读取失败)"

echo
echo "===== 4 卸载驱动 ====="
modprobe -r pcie-rockchip-host 2>/dev/null
modprobe -r phy-rockchip-pcie 2>/dev/null
if lsmod | grep -qE 'pcie_rockchip_host|phy_rockchip_pcie'; then
	lsmod | grep -E 'pcie|phy' | sed 's/^/    /'
	echo "  警告: 仍有模块加载，探测可能被跳过"
else
	echo "  已全部卸载"
fi

echo
echo "===== 5 重新探测 ====="
modprobe phy-rockchip-pcie && echo "  phy-rockchip-pcie 已加载"
modprobe pcie-rockchip-host && echo "  pcie-rockchip-host 已加载"
sleep 4

echo
echo "===== 6 结果 ====="
echo "  lspci:"
lspci 2>/dev/null | sed 's/^/    /' || true
[ -z "$(lspci 2>/dev/null)" ] && echo "    （无设备）"
echo "  dmesg 尾部:"
dmesg | grep rockchip-pcie | tail -6 | sed 's/^/    /'
echo "  ahci 相关:"
dmesg | grep -iE 'ahci|ata[0-9]' | tail -5 | sed 's/^/    /' || echo "    （无）"
echo "  块设备:"
lsblk -dno NAME,SIZE,MODEL 2>/dev/null | sed 's/^/    /'

echo
echo "===== 7 引脚保持 ====="
echo "  后台 gpioset PID=$GSPID，保持 ${HOLD} 秒"
echo "  提前释放: /root/pcie-test.sh release"