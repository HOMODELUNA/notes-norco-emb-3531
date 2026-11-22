#!/bin/bash
# add-wifi-fw.sh —— 往镜像里补 RTL8188ETV(USB) 的固件，使 rtl8xxxu 驱动能接管
#
# 背景：
#   l1 用的是 A 的内核(6.18.63)与模块，其中已包含 rtl8xxxu.ko、cfg80211.ko、mac80211.ko；
#   l1 用的 A 的设备树里 /regulator-wifi-en 是 always-on（GPIO4_D4），芯片供电正常。
#   唯一缺的是 rtl8xxxu 需要的固件 rtlwifi/rtl8188eufw.bin —— B 的 rootfs 没有 /lib/firmware。
#
# 用法：
#   sudo ./add-wifi-fw.sh                      # 默认改 emb3531-b-with-a-kernel.img
#   sudo ./add-wifi-fw.sh 其它镜像.img
#   SRC=/mnt/a1 sudo -E ./add-wifi-fw.sh       # 指定提供固件的 A 根分区挂载点
set -euo pipefail

IMG="${1:-emb3531-b-with-a-kernel.img}"
SRC="${SRC:-/mnt/a1}"
P4_OFF=83886080          # 163840 * 512
FW_SRC="$SRC/usr/lib/firmware"

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -f "$IMG" ] || die "找不到镜像 $IMG"
[ -f "$FW_SRC/rtlwifi/rtl8188eufw.bin" ] || die "找不到 $FW_SRC/rtlwifi/rtl8188eufw.bin（A 是否挂在 $SRC？）"

L=$(losetup -fP --show "$IMG")
M=$(mktemp -d)
cleanup(){ mountpoint -q "$M" && umount "$M" || true; rmdir "$M" 2>/dev/null || true; [ -n "${L:-}" ] && losetup -d "$L" 2>/dev/null || true; }
trap cleanup EXIT

log "挂载 p4（已存在的 loop → 直接用分区设备）"
if [ -b "${L}p4" ]; then mount "${L}p4" "$M"; else
  mount -o loop,offset=$P4_OFF "$IMG" "$M" || die "挂载失败"
fi

log "写入固件"
# B 的 rootfs 是 usr-merge：/lib 是指向 /usr/lib 的符号链接，mkdir 走链接即可
mkdir -p "$M/lib/firmware/rtlwifi"
cp -v "$FW_SRC/rtlwifi/rtl8188eufw.bin" "$M/lib/firmware/rtlwifi/"
# 管制域数据库：Debian 用 alternatives 符号链接，指向 /etc/alternatives/…（在挂载点内无法解析）
# 因此优先复制实体文件 regulatory.db-debian / -upstream，再改名为标准名
if   [ -f "$FW_SRC/regulatory.db-debian" ];   then cp -v "$FW_SRC/regulatory.db-debian"   "$M/lib/firmware/regulatory.db"
elif [ -f "$FW_SRC/regulatory.db-upstream" ]; then cp -v "$FW_SRC/regulatory.db-upstream" "$M/lib/firmware/regulatory.db"
fi
if   [ -f "$FW_SRC/regulatory.db.p7s-debian" ];   then cp -v "$FW_SRC/regulatory.db.p7s-debian"   "$M/lib/firmware/regulatory.db.p7s"
elif [ -f "$FW_SRC/regulatory.db.p7s-upstream" ]; then cp -v "$FW_SRC/regulatory.db.p7s-upstream" "$M/lib/firmware/regulatory.db.p7s"
fi

log "结果"
ls -lL "$M/lib/firmware" "$M/lib/firmware/rtlwifi" 2>/dev/null | sed 's/^/  /'
if [ -L "$M/lib" ]; then echo "  注意：/lib 是符号链接 → 实际写入 $(readlink "$M/lib")/firmware"; fi
# 兜底：若经符号链看不到，直接确认物理目录
[ -f "$M/usr/lib/firmware/rtlwifi/rtl8188eufw.bin" ] && echo "  确认：usr/lib/firmware/rtlwifi/rtl8188eufw.bin 已就位"
echo "  可用空间: $(df -h "$M" | tail -1 | awk '{print $4}')"

sync
umount "$M"; rmdir "$M"; losetup -d "$L"; L=""

cat <<'EOT'

下一步：
1) 刷写该镜像，用 115200 串口或看路由器 DHCP 确认系统已起来
2) 登录后检查：
     lsusb | grep -i 0bda            # 应出现 0bda:0179（RTL8188ETV）
     dmesg | grep -iE 'rtl8xxxu|8188'
     ip -br link                     # 应出现 wlan0
     rfkill list                     # 若有 Soft blocked: yes → rfkill unblock wifi
3) 若没有 wlan0，重载驱动看日志：
     sudo modprobe -r rtl8xxxu; sudo modprobe rtl8xxxu; dmesg | tail -20
4) 联网（有线 DHCP 已可用，直接装包）：
     sudo apt install -y wpasupplicant iw rfkill wireless-regdb
     sudo iw reg set CN
     sudo iw dev wlan0 scan | grep SSID
5) 连接（写入 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf 后）：
     sudo systemctl enable --now wpa_supplicant@wlan0
     sudo dhclient wlan0    # 或配 systemd-networkd 的 .network
EOT