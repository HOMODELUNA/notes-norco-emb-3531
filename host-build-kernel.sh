#!/bin/bash
# host-build-kernel.sh —— 在 x86_64 主机上交叉编译 EMB-3531 的 ARM64 内核
#
# 子命令：
#   fetch     下载并解压 linux-6.18.24
#   config    应用 defconfig / 设备树 / dtb Makefile 补丁
#   build     make Image modules dtbs（交叉编译）
#   stage     modules_install 到 staging/，并打包成 tar.gz
#   all       fetch + config + build + stage
#
# 用法：./host-build-kernel.sh all
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
KDIR=$BASE/kernel
SRC=$KDIR/linux-6.18.24
OUT=$BASE/kernel-out
STAGING=$BASE/kernel-staging
ASSETS=$BASE/emb3531-headless-sdk/patches/kernel

VER=6.18.24
URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz
LOCALVER=6.18.24-emb3531
JOBS=${JOBS:-16}

export ARCH=arm64
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

log(){ echo -e "\033[1;36m== $*\033[0m"; }
die(){ echo "错误: $*" >&2; exit 1; }

check_tools(){
	local miss=()
	for t in "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld" make bc bison flex cpio depmod rsync; do
		command -v "$t" >/dev/null || miss+=("$t")
	done
	[ -f /usr/include/openssl/ssl.h ] || miss+=("libssl-dev")
	[ -f /usr/include/libelf.h ] || miss+=("libelf-dev")
	if [ ${#miss[@]} -gt 0 ]; then
		echo "缺少: ${miss[*]}"
		echo "请执行："
		echo "  sudo apt install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \\"
		echo "    libc6-dev-arm64-cross build-essential bc bison flex libssl-dev \\"
		echo "    libelf-dev cpio kmod rsync xz-utils device-tree-compiler dwarves"
		die "工具链不完整"
	fi
}

do_fetch(){
	mkdir -p "$KDIR"
	if [ -d "$SRC" ] && [ -f "$SRC/Makefile" ]; then
		log "源码已存在：$SRC"
		return
	fi
	if [ ! -f "$KDIR/linux-$VER.tar.xz" ]; then
		log "下载 $URL"
		wget -c -O "$KDIR/linux-$VER.tar.xz" "$URL"
	fi
	log "解压"
	tar xf "$KDIR/linux-$VER.tar.xz" -C "$KDIR"
	[ -f "$SRC/Makefile" ] || die "解压后未找到 Makefile"
	log "完成：$(head -4 "$SRC/Makefile" | tr '\n' ' ')"
}

do_config(){
	[ -d "$SRC" ] || die "先执行 fetch"
	cd "$SRC"
	log "放入 defconfig 与设备树"
	cp -f "$ASSETS/emb3531_headless_defconfig" arch/arm64/configs/
	cp -f "$ASSETS/rk3399-emb3531.dts" arch/arm64/boot/dts/rockchip/
	log "打 dtb Makefile 补丁（幂等）"
	if grep -q 'rk3399-emb3531\.dtb' arch/arm64/boot/dts/rockchip/Makefile; then
		echo "  已包含，跳过"
	else
		patch -p1 < "$ASSETS/0001-add-emb3531-dtb-to-makefile.patch"
	fi
	rm -f arch/arm64/boot/dts/rockchip/Makefile.rej

	log "生成 .config（ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE）"
	make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE O="$OUT" emb3531_headless_defconfig 2>&1 | tail -3

	log "校验关键项"
	local bad=0
	check_one(){
		local k=$1 want=$2 have
		have=$(grep -E "^CONFIG_$k=" "$OUT/.config" | head -1 | sed "s/^CONFIG_$k=//")
		if [ "${have:-未设置}" = "$want" ]; then
			printf "  %-22s %-18s OK\n" "$k" "$have"
		else
			printf "  %-22s %-18s 期望 %s\n" "$k" "${have:-未设置}" "$want"
			bad=1
		fi
	}
	check_one LOCALVERSION    '"-emb3531"'
	check_one PCI             y
	check_one PCI_MSI         y
	check_one PCIE_ROCKCHIP_HOST m
	check_one PHY_ROCKCHIP_PCIE  m
	check_one ATA             y
	check_one ATA_BMDMA       y
	check_one SATA_AHCI       y
	check_one SCSI            y
	check_one BLK_DEV_SD      y
	check_one WIRELESS        y
	check_one WLAN            y
	check_one WLAN_VENDOR_REALTEK y
	check_one RTL8XXXU        m
	check_one CFG80211        m
	check_one MAC80211        m
	check_one RFKILL          m
	[ "$bad" = 0 ] || echo "  注意：上面有不符合期望的项"
	printf "  内核版本串: %s\n" "$(make -s ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE O="$OUT" kernelrelease 2>/dev/null)"
}

do_build(){
	[ -f "$OUT/.config" ] || die "先执行 config"
	cd "$SRC"
	log "编译 Image modules dtbs（-j$JOBS）"
	time make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE O="$OUT" -j"$JOBS" Image modules dtbs 2>&1 | tail -25
	log "产物"
	ls -l "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/dts/rockchip/rk3399-emb3531.dtb"
	echo "  .ko 数量: $(find "$OUT" -name '*.ko' | wc -l)"
}

do_stage(){
	[ -f "$OUT/arch/arm64/boot/Image" ] || die "先执行 build"
	cd "$SRC"
	log "modules_install 到 $STAGING"
	rm -rf "$STAGING"
	make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE O="$OUT" \
	     INSTALL_MOD_PATH="$STAGING" modules_install 2>&1 | tail -5
	local md="$STAGING/lib/modules/$LOCALVER"
	[ -d "$md" ] || die "未生成 $md"
	log "打包模块"
	tar czf "$BASE/modules-$LOCALVER.tar.gz" -C "$STAGING/lib/modules" "$LOCALVER"
	log "收集产物到 $BASE/host-build-out/"
	mkdir -p "$BASE/host-build-out"
	cp -f "$OUT/arch/arm64/boot/Image" "$BASE/host-build-out/Image-$LOCALVER"
	cp -f "$OUT/arch/arm64/boot/dts/rockchip/rk3399-emb3531.dtb" \
	      "$BASE/host-build-out/rk3399-emb3531-emb.dtb"
	cp -f "$OUT/.config" "$BASE/host-build-out/config-$LOCALVER"
	cp -f "$BASE/modules-$LOCALVER.tar.gz" "$BASE/host-build-out/"
	ls -lh "$BASE/host-build-out/" | sed 's/^/  /'
}

case "${1:-}" in
	fetch)  check_tools; do_fetch ;;
	config) check_tools; do_config ;;
	build)  check_tools; do_build ;;
	stage)  check_tools; do_stage ;;
	all)    check_tools; do_fetch; do_config; do_build; do_stage ;;
	*)      sed -n '2,14p' "$0"; exit 1 ;;
esac