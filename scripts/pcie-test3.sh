#!/bin/bash
# pcie-test3.sh —— 验证 ep-gpios（PERST# 时序）方案
#
# 与前两个脚本的区别：不再用 gpioset 碰第 29 线。
# 该线由驱动按 ep-gpios 管理：上电期间复位有效，100 ms 后释放。
#
# 用法：/root/pcie-test3.sh
set -u

banner(){ echo; echo "########## $* ##########"; }

banner "0 环境"
echo "  内核: $(uname -r)"
echo "  当前设备树: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
if [ -d /proc/device-tree/pcie@f8000000 ]; then
	if [ -f /proc/device-tree/pcie@f8000000/ep-gpios ]; then
		echo "  ep-gpios: 存在"
	else
		echo "  ep-gpios: 不存在（说明没启动到 l5）"
	fi
	[ -f /proc/device-tree/pcie@f8000000/status ] && \
		echo "  pcie0 status: $(cat /proc/device-tree/pcie@f8000000/status | tr -d '\0')"
fi
echo "  残留 gpioset: $(pgrep -c gpioset 2>/dev/null || echo 0)"
pgrep -a gpioset 2>/dev/null | sed 's/^/    /'

banner "1 卸载驱动"
modprobe -r pcie-rockchip-host 2>/dev/null
modprobe -r phy-rockchip-pcie 2>/dev/null
if lsmod | grep -qE 'pcie_rockchip_host|phy_rockchip_pcie'; then
	echo "  警告：仍有模块加载"
else
	echo "  已全部卸载"
fi
echo "  第 29 线: $(gpioinfo -c gpiochip4 2>/dev/null | sed -n 31p | sed 's/^[[:space:]]*//')"

banner "2 PHY 寄存器（加载前）"
printf "  lane 状态 = %s\n" "$(busybox devmem 0xff77f7b0 32 2>/dev/null || echo 读取失败)"

banner "3 加载驱动（驱动会自动拉 PERST#）"
modprobe phy-rockchip-pcie && echo "  phy 已加载"
modprobe pcie-rockchip-host && echo "  host 已加载"
sleep 5

banner "4 结果"
echo "  第 29 线: $(gpioinfo -c gpiochip4 2>/dev/null | sed -n 31p | sed 's/^[[:space:]]*//')"
printf "  lane 状态 = %s\n" "$(busybox devmem 0xff77f7b0 32 2>/dev/null || echo 读取失败)"
echo "  lspci 设备数: $(lspci 2>/dev/null | wc -l)"
lspci 2>/dev/null | sed 's/^/    /'
echo "  dmesg:"
dmesg | grep rockchip-pcie | tail -12 | sed 's/^/    /'
echo "  ahci:"
dmesg | grep -iE 'ahci|ata[0-9]' | tail -5 | sed 's/^/    /'
echo "  块设备:"
lsblk -dno NAME,SIZE,MODEL 2>/dev/null | sed 's/^/    /'