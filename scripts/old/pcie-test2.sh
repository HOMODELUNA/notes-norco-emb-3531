#!/bin/bash
# pcie-test2.sh —— 验证 CLKREQ# 引脚对 PCIe 链路的影响
#
# 用法：/root/pcie-test2.sh
set -u

HOLD=${HOLD:-120}

banner(){ echo; echo "########## $* ##########"; }

line_state(){ # $1=chip $2=line
	gpioinfo -c "$1" 2>/dev/null | sed -n "$(( $2 + 2 ))p" | sed 's/^[[:space:]]*/  /'
}

hold(){ # $1=chip $2=consumer $3=line $4=value
	local chip="$1" cons="$2" line="$3" val="$4"
	gpioset -p "${HOLD}s" -C "$cons" -c "$chip" "${line}=${val}" 2>&1 | sed 's/^/  gpioset: /' &
	sleep 1
	if gpioinfo -c "$chip" 2>/dev/null | sed -n "$(( line + 2 ))p" | grep -q "consumer=${cons}"; then
		echo "  已取得 $chip 第 $line 线（consumer=$cons，值=$val）"
	else
		echo "  警告：$chip 第 $line 线未取得，后续结果无效"
	fi
}

drop(){ # $1=consumer
	pkill -f "gpioset .*-C ${1} " 2>/dev/null
}

read_lane(){
	printf "  lane 状态 = %s\n" "$(busybox devmem 0xff77f7b0 32 2>/dev/null || echo 读取失败)"
}

probe_once(){ # $1=标签
	banner "$1"
	modprobe -r pcie-rockchip-host 2>/dev/null
	modprobe -r phy-rockchip-pcie 2>/dev/null
	read_lane
	modprobe phy-rockchip-pcie 2>/dev/null
	modprobe pcie-rockchip-host 2>/dev/null
	sleep 4
	local n
	n=$(lspci 2>/dev/null | wc -l)
	echo "  lspci 设备数: $n"
	lspci 2>/dev/null | sed 's/^/    /'
	read_lane
	dmesg | grep rockchip-pcie | tail -2 | sed 's/^/    /'
	if [ "$n" -gt 0 ]; then
		echo
		echo "  >>> 成功。停止后续组合。"
		exit 0
	fi
}

banner "0 环境"
echo "  内核: $(uname -r)"
pkill -f 'gpioset -p [0-9]' 2>/dev/null
sleep 1
echo "  残留 gpioset: $(pgrep -c gpioset) 个"

banner "1 槽位上电（gpiochip4 第 29 线拉高）"
hold gpiochip4 perst 29 1
line_state gpiochip4 29

probe_once "2 基线：CLKREQ# 悬空"

banner "3 组合 A：CLKREQ#（gpiochip2 第 26 线）拉低"
hold gpiochip2 clkreqa 26 0
line_state gpiochip2 26
probe_once "3 结果"

banner "4 组合 B：CLKREQ#（gpiochip4 第 24 线）拉低"
drop clkreqa
hold gpiochip4 clkreqb 24 0
line_state gpiochip4 24
probe_once "4 结果"

banner "5 组合 C：两条 CLKREQ# 同时拉低"
hold gpiochip2 clkreqa 26 0
probe_once "5 结果"

banner "6 全部组合失败"
echo "  CLKREQ# 不是原因。"
echo "  释放引脚: pkill -f 'gpioset -p'"
echo "  恢复默认电平需重启。"