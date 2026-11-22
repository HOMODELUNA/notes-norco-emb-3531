#!/bin/bash
# board-install-v2.sh —— 重刷镜像后在板上一次性部署「新内核 + 无线 + PCIe 测试标签」
#
# 前提：/root/v2/ 下已有
#   Image-emb3531                 新编内核
#   rk3399-emb3531.dtb            厂商原设备树（含 eMMC PHY，最稳）
#   rk3399-emb3531-emb.dtb        厂商 + wifi_en + PCIe x4
#   rk3399-emb3531-nopcie.dtb     厂商 + wifi_en，PCIe 关闭
#   modules-6.18.24-emb3531.tar.gz
#   extlinux-emb.conf             标签文件
#   wifi-power.sh                 无线上电脚本
#
# 用法：./board-install-v2.sh [标签，默认 l2]
set -euo pipefail

SRC=/root/v2
P3=/dev/mmcblk2p3
MNT=/mnt/p3
TARGET=${1:-l2}
KDIR=/lib/modules/6.18.24-emb3531

log(){ echo -e "\033[1;36m== $*\033[0m"; }
die(){ echo "错误: $*" >&2; exit 1; }

for f in Image-emb3531 rk3399-emb3531.dtb rk3399-emb3531-emb.dtb \
         rk3399-emb3531-nopcie.dtb modules-6.18.24-emb3531.tar.gz \
         extlinux-emb.conf wifi-power.sh; do
	[ -f "$SRC/$f" ] || die "缺文件 $SRC/$f"
done

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P3" "$MNT"

log "1/5 腾出 p3 空间（删除 A 的旧内核）"
rm -f "$MNT/Image-armbian" "$MNT/dtb/rk3399-emb-3531.dtb"
df -h "$MNT" | tail -1 | sed 's/^/  /'

log "2/5 放入新内核与设备树"
cp -f "$SRC/Image-emb3531" "$MNT/Image-emb3531"
mkdir -p "$MNT/dtb"
for d in rk3399-emb3531.dtb rk3399-emb3531-emb.dtb rk3399-emb3531-nopcie.dtb; do
	cp -f "$SRC/$d" "$MNT/dtb/$d"
done
sync
df -h "$MNT" | tail -1 | sed 's/^/  /'
ls -l "$MNT" "$MNT/dtb" | sed 's/^/  /'

log "3/5 安装模块到 $KDIR"
rm -rf "$KDIR"
tar xzf "$SRC/modules-6.18.24-emb3531.tar.gz" -C /lib/modules
depmod -a 6.18.24-emb3531
echo "  .ko 数量: $(find "$KDIR" -name '*.ko' | wc -l)"

log "3.5 安装 PCIe 模块黑名单（防止开机自动探测导致挂死）"
cat > /etc/modprobe.d/emb-pcie-blacklist.conf <<'EOF'
# PCIe 驱动保持模块形式并默认不自动加载，需要时手动 modprobe 测试
blacklist pcie-rockchip-host
blacklist phy-rockchip-pcie
EOF
echo "  已写入 /etc/modprobe.d/emb-pcie-blacklist.conf"

log "4/5 安装无线上电服务"
log "安装依赖包（gpiod / 固件 / 无线与 PCIe 工具）"
PKGS="gpiod usbutils iw wpasupplicant wireless-regdb pciutils device-tree-compiler firmware-realtek"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 update -qq || echo "  apt update 失败，继续"
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 install -y -qq $PKGS 2>&1 | grep -E '^(正在设置|Setting up|E:)' | tail -5
command -v gpioset >/dev/null || die "gpioset 仍缺失，无法自动给无线上电"
[ -f /usr/lib/firmware/rtlwifi/rtl8188eufw.bin ] || echo "  警告：rtl8188eufw.bin 缺失，无线无法加载固件"
install -m 755 "$SRC/wifi-power.sh" /usr/local/sbin/wifi-power.sh
cat > /etc/systemd/system/wifi-power.service <<'UNIT'
[Unit]
Description=Power on board RTL8188EUS wifi (GPIO4_D4)
After=local-fs.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/wifi-power.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable wifi-power.service
systemctl start wifi-power.service || true
sleep 4
modprobe -r rtl8xxxu 2>/dev/null || true
modprobe rtl8xxxu 2>/dev/null || true
sleep 2
if ip -br link 2>/dev/null | grep -q wlan0; then
	echo "  无线已验证：wlan0 存在"
else
	echo "  警告：wlan0 未出现，请检查 /usr/lib/firmware/rtlwifi/rtl8188eufw.bin"
fi
echo "  已启用 wifi-power.service"

log "5/5 写入启动标签，默认 $TARGET"
cp -f "$MNT/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf.bak" 2>/dev/null || true
cp -f "$SRC/extlinux-emb.conf" "$MNT/extlinux/extlinux.conf"
sed -i "s/^default .*/default $TARGET/" "$MNT/extlinux/extlinux.conf"
sync
cat "$MNT/extlinux/extlinux.conf" | sed 's/^/  /'

echo
echo "完成。重启后生效：reboot"
echo "当前默认项: $(grep -m1 '^default' "$MNT/extlinux/extlinux.conf")"
echo "提示：l0=vendor 内核, l2=新内核(vendor dtb), l4=新内核+PCIe"