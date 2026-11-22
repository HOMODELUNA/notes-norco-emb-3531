#!/bin/bash
# board-build-kernel.sh —— 在 EMB-3531 板上原生编译带 PCIe 与无线的内核
#
# 用法（按顺序执行）：
#   ./board-build-kernel.sh fetch     # 下载并解压源码（约 150 MB）
#   ./board-build-kernel.sh config    # 应用补丁、放入 defconfig 与 dts、校验
#   ./board-build-kernel.sh build     # 编译 Image + dtb + 模块（-j4，自动加 3 GB swap）
#   ./board-build-kernel.sh install   # 装模块到 /lib/modules，并把 Image 与 dtb 放进 p3
set -euo pipefail

KDIR=/root/k
SRC=$KDIR/linux-6.18.24
ASSETS=/root/emb-build
URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.24.tar.xz
TAR=$KDIR/dl/linux-6.18.24.tar.xz
JOBS=${JOBS:-4}
VER=6.18.24-emb3531

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
# free -m 的输出会随系统语言变化（中文为“交换：”），因此直接读 /proc/meminfo
swap_mb(){ awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null | grep -E '^[0-9]+$' || echo 0; }

case "${1:-help}" in
fetch)
	log "准备 wget 与目录"
	command -v wget >/dev/null || { apt-get -qq update; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y wget; }
	mkdir -p "$KDIR/dl"
	log "下载源码（约 150 MB）"
	[ -f "$TAR" ] || wget -O "$TAR" "$URL"
	sz=$(stat -c%s "$TAR")
	[ "$sz" -gt 100000000 ] || die "tarball 不完整：$sz 字节"
	echo "  tarball: $sz 字节"
	log "解压"
	[ -d "$SRC" ] || tar xf "$TAR" -C "$KDIR"
	echo "  源码: $SRC ($(du -sh "$SRC" | cut -f1))"
	;;
config)
	[ -d "$SRC" ] || die "先执行 fetch"
	cd "$SRC"
	log "应用 dtb Makefile 补丁（幂等）"
	if grep -q 'rk3399-emb3531\.dtb' arch/arm64/boot/dts/rockchip/Makefile; then
		echo "  Makefile 已包含 rk3399-emb3531.dtb，跳过"
	else
		patch -p1 < "$ASSETS/0001-add-emb3531-dtb-to-makefile.patch"
	fi
	rm -f arch/arm64/boot/dts/rockchip/Makefile.rej
	log "放入 defconfig 与 dts"
	cp "$ASSETS/emb3531_headless_defconfig" arch/arm64/configs/
	cp "$ASSETS/rk3399-emb3531.dts" arch/arm64/boot/dts/rockchip/
	make ARCH=arm64 emb3531_headless_defconfig
	log "校验本次改动项"
	for k in LOCALVERSION PCI PCI_MSI PCIE_ROCKCHIP_HOST PHY_ROCKCHIP_PCIE \
	         ATA SATA_AHCI SCSI BLK_DEV_SD WIRELESS WLAN RTL8XXXU CFG80211 MAC80211 RFKILL; do
		printf "  %-24s %s\n" "$k" "$(grep -E "^CONFIG_$k=|^# CONFIG_$k is not set" .config | head -1)"
	done
	;;
build)
	[ -f "$SRC/.config" ] || die "先执行 config"
	if [ "$(swap_mb)" -lt 1024 ]; then
		log "启用 3 GB swap（2 GB 内存编译大文件会 OOM）"
		if [ ! -f /swapfile ]; then
			fallocate -l 3G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=3072 status=none
			chmod 600 /swapfile; mkswap /swapfile >/dev/null
		fi
		swapon /swapfile 2>/dev/null || true
		echo "  swap: $(swap_mb) MB"
	fi
	cd "$SRC"
	log "编译（-j$JOBS）"
	make ARCH=arm64 -j"$JOBS" Image dtbs modules
	log "产物"
	ls -l arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3399-emb3531.dtb
	;;
install)
	cd "$SRC"
	[ -f arch/arm64/boot/Image ] || die "先执行 build"
	log "安装模块到 /lib/modules/$VER"
	make ARCH=arm64 INSTALL_MOD_PATH=/ INSTALL_MOD_STRIP=1 modules_install
	log "把内核与 dtb 放进 p3"
	mountpoint -q /mnt/p3 || mount /dev/mmcblk2p3 /mnt/p3
	mkdir -p /mnt/p3/dtb
	cp arch/arm64/boot/Image /mnt/p3/Image-emb3531
	cp arch/arm64/boot/dts/rockchip/rk3399-emb3531.dtb /mnt/p3/dtb/rk3399-emb3531-emb.dtb
	sync
	ls -l /mnt/p3 /mnt/p3/dtb | sed 's/^/  /'
	;;
*)
	sed -n '2,12p' "$0"
	;;
esac