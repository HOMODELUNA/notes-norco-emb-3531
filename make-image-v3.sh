#!/bin/bash
# make-image-v3.sh —— 生成 emb3531-v3.img：恢复用镜像 + 全量部署（需 sudo）
#
# 做三件事：
#   1) p3：放入新内核与 3 个设备树（全部基于厂商 dtb），写入 4 个启动标签
#   2) p4：安装 6.18.24-emb3531 模块、无线上电服务、PCIe 黑名单、首启补齐脚本
#   3) 输出可直接刷写的 emb3531-v3.img
#
# 用法：sudo ./make-image-v3.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC=emb3531-b-with-a-kernel.img
DST=emb3531-v3.img
V2=v2
MODTAR=$V2/modules-6.18.24-emb3531.tar.gz
LOCALVER=6.18.24-emb3531

P3MNT=/mnt/emb-v3-p3
P4MNT=/mnt/emb-v3-p4
LOOP=""

log(){ echo -e "\033[1;36m== $*\033[0m"; }
die(){ echo "错误: $*" >&2; exit 1; }
cleanup(){
	sync
	mountpoint -q "$P3MNT" && umount "$P3MNT" || true
	mountpoint -q "$P4MNT" && umount "$P4MNT" || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rmdir "$P3MNT" "$P4MNT" 2>/dev/null || true
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "需要 root：sudo ./make-image-v3.sh"
for f in "$SRC" "$V2/Image-emb3531" "$V2/rk3399-emb3531.dtb" \
         "$V2/rk3399-emb3531-pcie1.dtb" "$V2/rk3399-emb3531-pcie4.dtb" \
         "$MODTAR" "$V2/wifi-power.sh" extlinux-v3.conf scripts/emb-firstboot.sh; do
	[ -f "$f" ] || die "缺文件 $f"
done

log "1/6 复制镜像"
cp -f "$SRC" "$DST"
log "2/6 挂载回环设备"
LOOP=$(losetup -fP --show "$DST")
echo "  $LOOP"

log "3/6 处理 p3（内核与设备树）"
mkdir -p "$P3MNT"; mount "${LOOP}p3" "$P3MNT"
rm -f "$P3MNT/Image-armbian" "$P3MNT/dtb/rk3399-emb-3531.dtb"
# 清掉早期自编译 dtb（含 wifi_en 节点，会导致启动挂死）
rm -f "$P3MNT/dtb/rk3399-emb3531-emb.dtb" "$P3MNT/dtb/rk3399-emb3531-nopcie.dtb"
cp -f "$V2/Image-emb3531" "$P3MNT/Image-emb3531"
mkdir -p "$P3MNT/dtb"
cp -f "$V2/rk3399-emb3531.dtb"      "$P3MNT/dtb/"
cp -f "$V2/rk3399-emb3531-pcie1.dtb" "$P3MNT/dtb/"
cp -f "$V2/rk3399-emb3531-pcie4.dtb" "$P3MNT/dtb/"
cp -f extlinux-v3.conf "$P3MNT/extlinux/extlinux.conf"
sync
echo "  p3 用量: $(df -h "$P3MNT" | awk 'NR==2{print $3" / "$2}')"
ls -l "$P3MNT" "$P3MNT/dtb" | grep -E 'Image|dtb|extlinux' | sed 's/^/    /'
umount "$P3MNT"

log "4/6 处理 p4（模块 / 服务 / 黑名单）"
mkdir -p "$P4MNT"; mount "${LOOP}p4" "$P4MNT"
echo "  p4 处理前: $(df -h "$P4MNT" | awk 'NR==2{print $3" 已用, "$4" 可用"}')"

# A 的旧内核模块已无用，腾出空间
if [ -d "$P4MNT/lib/modules/6.18.63-current-rockchip64" ]; then
	rm -rf "$P4MNT/lib/modules/6.18.63-current-rockchip64"
	echo "  已删除 A 的旧模块目录 6.18.63-current-rockchip64"
fi

rm -rf "$P4MNT/lib/modules/$LOCALVER"
tar xzf "$MODTAR" -C "$P4MNT/lib/modules"
depmod -b "$P4MNT" "$LOCALVER"
echo "  模块: $(find "$P4MNT/lib/modules/$LOCALVER" -name '*.ko' | wc -l) 个"

install -m 755 "$V2/wifi-power.sh" "$P4MNT/usr/local/sbin/wifi-power.sh"
cat > "$P4MNT/etc/systemd/system/wifi-power.service" <<'UNIT'
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
mkdir -p "$P4MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/wifi-power.service \
       "$P4MNT/etc/systemd/system/multi-user.target.wants/wifi-power.service"
echo "  已启用 wifi-power.service"

install -m 755 scripts/emb-firstboot.sh "$P4MNT/usr/local/sbin/emb-firstboot.sh"
cat > "$P4MNT/etc/systemd/system/emb-firstboot.service" <<'UNIT'
[Unit]
Description=Install runtime packages on first boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/usr/bin/gpioset

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/emb-firstboot.sh
RemainAfterExit=yes
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/emb-firstboot.service \
       "$P4MNT/etc/systemd/system/multi-user.target.wants/emb-firstboot.service"
echo "  已启用 emb-firstboot.service"

mkdir -p "$P4MNT/etc/modprobe.d"
cat > "$P4MNT/etc/modprobe.d/emb-pcie-blacklist.conf" <<'CONF'
# PCIe 驱动保持模块形式并默认不自动加载；测试时手动 modprobe
blacklist pcie-rockchip-host
blacklist phy-rockchip-pcie
CONF
echo "  已写入 PCIe 黑名单"

sync
echo "  p4 处理后: $(df -h "$P4MNT" | awk 'NR==2{print $3" 已用, "$4" 可用"}')"
umount "$P4MNT"

log "5/6 卸载"
losetup -d "$LOOP"; LOOP=""
log "6/6 结果"
ls -lh "$DST" | sed 's/^/  /'
echo "  md5: $(md5sum "$DST" | cut -d' ' -f1)"
echo
echo "刷入 $DST 后：默认 l2（新内核 + 厂商 dtb，无线自动上电）"
echo "  l0 = 厂商内核   l2 = 新内核   l3 = PCIe gen1 x1   l4 = PCIe gen2 x4"