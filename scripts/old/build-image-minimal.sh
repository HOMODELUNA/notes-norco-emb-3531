#!/bin/bash
# build-image-minimal.sh —— 以 B 为底座，只换 A 的内核 + 设备树 + 模块（最小改动）
#
# 保留：
#   * B 的引导区字节（LBA 64 的 idbloader、LBA 16384 的 u-boot.itb）→ 115200 串口、boot_targets=mmc0
#   * B 的 boot 分区内容：/Image (6.18.24)、/dtb/rk3399-emb3531.dtb、extlinux.conf 的 label l0 原文
#   * B 的整个 rootfs：DHCP 配置、sshd（已启用、已允许空密码）、fstab、host key、首启服务
# 新增：
#   * /Image-armbian                            A 的内核 6.18.63（34.39 MiB）
#   * /dtb/rk3399-emb-3531.dtb                  A 的设备树
#   * /usr/lib/modules/6.18.63-current-rockchip64   A 的 3590 个模块（229.1 MiB）
#   * extlinux.conf 增加 label l1，default 指向 l1（l0 保留作回退）
# 必须调整的尺寸：
#   * p3 28.6 MiB → 64 MiB   （A 的内核 34.39 MiB 放不进 28.6 MiB）
#   * p4 文件系统 320 MiB → 620 MiB（B 只剩 17 MiB，A 的模块要 229.1 MiB）
#   * p4 起始 LBA 58570 → 163840（p3 变大后重排，1 MiB 对齐）
#
# 为什么 root= 要用 LABEL 而不是 /dev/mmcblk2p4：
#   A 的设备树把 eMMC 枚举成 mmc0，B 的是 mmc2。换设备树后 /dev/mmcblk2p4 不存在。
#   B 的 /etc/fstab 本来就用 LABEL=rootfs，所以 l1 用 root=LABEL=rootfs。
#
# 源镜像已有 loop 挂载时的处理：
#   内核禁止为同一后端文件的同一范围建两个 loop 设备（overlapping loop device）。
#   本脚本不新建源 loop：B 的 boot 分区 dd 到临时文件再挂；A 的根分区复用已有挂载点。
#
# 用法： cd ~/test-img && sudo ./build-image-minimal.sh
#        DEFAULT_LABEL=l0 sudo -E ./build-image-minimal.sh   # 让 B 的内核做默认（回退版）
set -euo pipefail

SRC_A="${SRC_A:-/mnt/d/shared/Armbianminimal.img}"
SRC_B="${SRC_B:-/mnt/c/Users/wzq/Downloads/default/emb3531.img}"
OUT="${OUT:-$(pwd)}"
IMG="$OUT/emb3531-b-with-a-kernel.img"
KVER_A=6.18.63-current-rockchip64
DEFAULT_LABEL="${DEFAULT_LABEL:-l1}"

A_ROOT_OFF=16777216        # A 的 rootfs 分区起点
A_ROOT_LEN=1891631104
B_P3_SECT=40960            # B 的 boot 分区有效长度 20 MiB（起于 LBA 17610）
B_P3_OFF=9016320           # LBA 17610
B_P4_OFF=29987840          # LBA 58570
B_P4_SECT=778206           # B 的 p4 声明长度 380.0 MB
LFS=0FC63DAF-8483-4772-8E79-3D69D8477DE4
ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B   # 与 B 的 p3 完全一致（B 把 boot 分区标成 EFI System）

P1S=64;     P1N=16320                  # idbloader 8 MiB
P2S=16384;  P2N=4096                   # uboot 2 MiB（B 的 itb 占 613 KiB，结束于 LBA 17609）
P3S=32768;  P3N=131072                 # boot 64 MiB
P4S=163840; P4N=1269760                # rootfs 620 MiB
TOTAL_SECT=$((P4S + P4N + 34))

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -r "$SRC_A" ] || die "找不到 $SRC_A"
[ -r "$SRC_B" ] || die "找不到 $SRC_B"
mkdir -p "$OUT"; cd "$OUT"

TMPD=$(mktemp -d)
BP3TMP="$TMPD/b-p3.img"
MOUNTS=(); OWNED=()
cleanup(){
  for i in "${!MOUNTS[@]}"; do
    m=${MOUNTS[$i]}
    if mountpoint -q "$m"; then
      [ "${OWNED[$i]}" = 1 ] && umount "$m" || true
    fi
  done
  [ -n "${L:-}" ] && losetup -d "$L" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
}
trap cleanup EXIT
add_mount(){ MOUNTS+=("$1"); OWNED+=("$2"); }

# 找 A 的根分区：1) 环境变量指定 2) /mnt/a1 3) 已存在的 loop 设备（后端路径可能已被改名）
# 4) 自己建 loop。优先级如此是为了避开 "overlapping loop device" 错误。
find_a_root(){
  local c dev
  for c in "${A_MNT:-}" /mnt/a1; do
    [ -n "$c" ] && [ -f "$c/boot/vmlinuz-$KVER_A" ] && { A_MNT_FOUND=$c; A_OWNED=0; return 0; }
  done
  for dev in $(losetup -a 2>/dev/null | cut -d: -f1); do
    mkdir -p "$TMPD/probe"
    if mount -o ro,noload "$dev" "$TMPD/probe" 2>/dev/null; then
      if [ -f "$TMPD/probe/boot/vmlinuz-$KVER_A" ]; then
        A_MNT_FOUND=$TMPD/probe; A_OWNED=1; return 0
      fi
      umount "$TMPD/probe"
    fi
  done
  mkdir -p "$TMPD/a"
  if mount -o loop,ro,noload,offset=$A_ROOT_OFF,sizelimit=$A_ROOT_LEN "$SRC_A" "$TMPD/a" 2>/dev/null; then
    A_MNT_FOUND=$TMPD/a; A_OWNED=1; return 0
  fi
  return 1
}

log "0) 准本源镜像"
if find_a_root; then
  MA="$A_MNT_FOUND"
  if [ "$A_OWNED" = 0 ]; then echo "   A rootfs: $MA（复用已有挂载）"
  else echo "   A rootfs: $MA（本次挂载）"; add_mount "$MA" 1; fi
else
  die "无法读取 $SRC_A 的根分区。请执行 sudo umount /mnt/a1 后重试，或用 A_MNT=<挂载点> sudo -E ./build-image-minimal.sh"
fi
dd if="$SRC_B" of="$BP3TMP" bs=512 skip=$((B_P3_OFF/512)) count=$B_P3_SECT conv=sparse status=none
mkdir -p "$TMPD/b"
mount -o loop,ro,noload "$BP3TMP" "$TMPD/b"; MB="$TMPD/b"; add_mount "$MB" 1
echo "   B boot:  $MB（B 的 p3 已复制到临时文件，避免 overlapping loop）"

[ -f "$MA/boot/vmlinuz-$KVER_A" ]              || die "A 里找不到内核 $KVER_A"
[ -d "$MA/usr/lib/modules/$KVER_A" ]           || die "A 里找不到模块 $KVER_A"
[ -f "$MA/boot/dtb/rockchip/rk3399-emb-3531.dtb" ] || die "A 里找不到设备树"
[ -f "$MB/extlinux/extlinux.conf" ]            || die "B 的 boot 分区结构不符"
[ -f "$MB/Image" ]                             || die "B 的内核 /Image 不存在"

log "1) 建空镜像（$((TOTAL_SECT*512/1048576)) MiB）并搬运 B 的引导区"
rm -f "$IMG"
truncate -s $((TOTAL_SECT*512)) "$IMG"
dd if="$SRC_B" of="$IMG" bs=512 count=17610 conv=notrunc,sparse status=none
sync

log "2) 写 GPT（4 个分区，名字/类型与 B 相同：p3 = EFI System，其余 = Linux filesystem）"
sfdisk --force --no-reread "$IMG" <<EOF
label: gpt
label-id: 8f3c1a52-6b7e-4a41-9c3d-2e5f6a7b8c9d
first-lba: 34
start=$P1S, size=$P1N, name=idbloader, type=$LFS
start=$P2S, size=$P2N, name=uboot,     type=$LFS
start=$P3S, size=$P3N, name=boot,      type=$ESP
start=$P4S, size=$P4N, name=rootfs,    type=$LFS
EOF

log "3) 制作 p3：保留 B 的内核/设备树/配置，追加 A 的内核与设备树"
truncate -s $((P3N/2048))M "$OUT/p3-min.img"
mkfs.ext4 -q -F -b 1024 -L boot -m 0 "$OUT/p3-min.img"
mkdir -p "$TMPD/p3"
mount -o loop "$OUT/p3-min.img" "$TMPD/p3"; M3="$TMPD/p3"; add_mount "$M3" 1
cp -a --reflink=auto "$MB/." "$M3/"
rmdir "$M3/lost+found" 2>/dev/null || true
mkdir -p "$M3/dtb"
cp --sparse=always "$MA/boot/vmlinuz-$KVER_A" "$M3/Image-armbian"
cp "$MA/boot/dtb/rockchip/rk3399-emb-3531.dtb" "$M3/dtb/"
grep -q '^label l1' "$M3/extlinux/extlinux.conf" || cat >> "$M3/extlinux/extlinux.conf" <<EOF

label l1
 menu label Linux $KVER_A (armbian)
 linux /Image-armbian
 fdt /dtb/rk3399-emb-3531.dtb
 append root=LABEL=rootfs rootwait rw console=ttyS2,115200 net.ifnames=0 earlycon=uart8250,mmio32,0xff1a0000 rk3399_pcie_ignore_serror
EOF
sed -i "s/^default .*/default $DEFAULT_LABEL/" "$M3/extlinux/extlinux.conf"
sync
echo "   p3 占用 $(du -sh --apparent-size "$M3" | cut -f1) / $((P3N/2048)) MiB"
ls -l "$M3" "$M3/dtb" | sed 's/^/     /'
echo "   --- extlinux.conf ---"; sed 's/^/     /' "$M3/extlinux/extlinux.conf"
umount "$M3"
dd if="$OUT/p3-min.img" of="$IMG" bs=1M seek=$((P3S/2048)) count=$((P3N/2048)) conv=notrunc status=none
sync

log "4) 搬运 B 的 rootfs 并扩容到 $((P4N/2048)) MiB"
dd if="$SRC_B" of="$IMG" bs=512 skip=$((B_P4_OFF/512)) seek=$P4S count=$B_P4_SECT conv=notrunc,sparse status=none
sync
L=$(losetup -fP --show "$IMG")
echo "   新镜像 loop: $L"
rc=0; FSCK_OUT=$(e2fsck -f -y "${L}p4" 2>&1) || rc=$?
echo "$FSCK_OUT" | tail -3 | sed 's/^/   /'
[ "$rc" -le 1 ] || die "e2fsck 失败（返回码 $rc）"
resize2fs "${L}p4" 2>&1 | sed 's/^/   /' || die "resize2fs 失败"
mkdir -p "$TMPD/p4"
mount "${L}p4" "$TMPD/p4"; M4="$TMPD/p4"; add_mount "$M4" 1
echo "   扩容后: $(df -h "$M4" | tail -1 | awk '{print $2" 总, "$4" 可用"}')"

log "5) 加入 A 的模块"
mkdir -p "$M4/usr/lib/modules"
cp -a --reflink=auto "$MA/usr/lib/modules/$KVER_A" "$M4/usr/lib/modules/"
rm -f "$M4/usr/lib/modules/$KVER_A/build" "$M4/usr/lib/modules/$KVER_A/source"
echo "   /usr/lib/modules: $(ls "$M4/usr/lib/modules" | tr '\n' ' ')"
echo "   $KVER_A: $(find "$M4/usr/lib/modules/$KVER_A" -name '*.ko' | wc -l) 个 .ko, $(du -sh "$M4/usr/lib/modules/$KVER_A" | cut -f1)"
sync
umount "$M4"

log "6) 校验"
fdisk -l "$IMG" | sed 's/^/   /'
echo "   -- 类型明细（p3 应为 EFI System，与 B 相同）:"
sfdisk -d "$IMG" | grep ' : start=' | sed -E 's/^[^ ]+ +: //; s/, uuid=[^,]+,//' | sed 's/^/     /'
echo "   -- 引导区与 B 是否逐字节相同:"
for lba in 64 16384; do
  a=$(dd if="$SRC_B" bs=512 skip=$lba count=128 status=none | sha256sum | cut -c1-16)
  b=$(dd if="$IMG" bs=512 skip=$lba count=128 status=none | sha256sum | cut -c1-16)
  printf "     LBA %-6d B=%s new=%s %s\n" $lba $a $b "$([ "$a" = "$b" ] && echo OK || echo MISMATCH)"
done
echo "   -- blkid:"
blkid "${L}p3" "${L}p4" | sed 's/^/     /'
echo "   -- 文件系统检查:"
e2fsck -fn "${L}p3" >/dev/null 2>&1 && echo "     p3 e2fsck OK" || echo "     p3 e2fsck 失败"
e2fsck -fn "${L}p4" >/dev/null 2>&1 && echo "     p4 e2fsck OK" || echo "     p4 e2fsck 失败"
mkdir -p "$TMPD/v3"
mount -o ro "${L}p3" "$TMPD/v3"; add_mount "$TMPD/v3" 1
cmp -s "$TMPD/v3/Image-armbian" "$MA/boot/vmlinuz-$KVER_A" \
  && echo "     p3: Image-armbian ≡ A 的 vmlinuz  OK" || echo "     p3: Image-armbian 不一致!"
cmp -s "$TMPD/v3/Image" "$MB/Image" \
  && echo "     p3: B 的原内核 /Image 仍完整  OK" || echo "     p3: B 的原内核 丢失!"
umount "$TMPD/v3"
mkdir -p "$TMPD/v4"
mount -o ro "${L}p4" "$TMPD/v4"; add_mount "$TMPD/v4" 1
echo "   -- p4 复核:"
echo "     fstab:   $(grep -m1 '^LABEL=rootfs' "$TMPD/v4/etc/fstab")"
echo "     modules: $(ls "$TMPD/v4/usr/lib/modules" | tr '\n' ' ')"
echo "     DHCP:    $(ls "$TMPD/v4/etc/systemd/network/" | tr '\n' ' ')"
echo "     sshd:    $(grep -m1 '^PermitEmptyPasswords' "$TMPD/v4/etc/ssh/sshd_config")"
echo "     可用:    $(df -h "$TMPD/v4" | tail -1 | awk '{print $4}')"
umount "$TMPD/v4"
losetup -d "$L"; L=""
[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMG" "$OUT/p3-min.img" 2>/dev/null || true

log "7) 完成：$IMG（$(du -h --apparent-size "$IMG" | cut -f1)）"
cat <<EOT
刷写： rkdeveloptool db rk3399_loader_v1.24.126.bin
       rkdeveloptool wl 0 $(basename "$IMG")
       rkdeveloptool rd
串口： 115200 8N1
默认启动项：$DEFAULT_LABEL（l0 = B 的内核 6.18.24，l1 = A 的内核 $KVER_A）
回退： DEFAULT_LABEL=l0 sudo -E ./build-image-minimal.sh 重新构建
EOT