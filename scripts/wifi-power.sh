#!/bin/bash
# wifi-power.sh —— 给板载 RTL8188EUS 上电（一次性拉高 GPIO4_D4，硬件自锁）
set -u

CHIP=${WIFI_GPIO_CHIP:-gpiochip4}
LINE=${WIFI_GPIO_LINE:-28}

wifi_present() {
	grep -l -i '0bda' /sys/bus/usb/devices/*/idVendor 2>/dev/null | while read -r f; do
		[ "$(cat "$(dirname "$f")/idProduct" 2>/dev/null)" = "8179" ] && echo yes
	done | head -1
}

# 1) 驱动先就位
modprobe cfg80211 2>/dev/null
modprobe mac80211 2>/dev/null
modprobe rtl8xxxu 2>/dev/null
sleep 1

# 2) 已上电则直接结束
if [ "$(wifi_present)" = "yes" ]; then
	echo "wifi 芯片已上电"
	exit 0
fi

# 3) 拉高 GPIO4_D4 上电（芯片电源自锁，置高后可释放引脚）
if ! command -v gpioset >/dev/null; then
	echo "缺 gpioset（apt install gpiod）"
	exit 1
fi
echo "拉高 $CHIP 第 $LINE 线给 wifi 上电"
gpioset -c "$CHIP" "$LINE=1"
sleep 2

# 4) 上电后重新探测
if [ "$(wifi_present)" != "yes" ]; then
	modprobe -r rtl8xxxu 2>/dev/null
	modprobe rtl8xxxu 2>/dev/null
	sleep 2
fi

if [ "$(wifi_present)" = "yes" ]; then
	echo "wifi 已上电并枚举"
	exit 0
fi
echo "wifi 未枚举"
exit 1