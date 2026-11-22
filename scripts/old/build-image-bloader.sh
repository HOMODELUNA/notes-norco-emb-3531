#!/bin/bash
# build-image-bloader.sh —— B 的引导链 + A 的内容（单一 115200 波特率）
#
# 与 build-gpt-image.sh 的唯一区别：p1/p2 用 **B（厂商固件）的 idbloader + u-boot.itb**
#   - B 的 u-boot: U-Boot 2026.04-g9f61fd5b80a4, baudrate=115200, boot_targets=mmc0, bootdelay=2
#     → 串口 115200（你现有适配器可用）、不会跑去 pxe/dhcp 网络启动重试
#   - A 的 u-boot: U-Boot 2026.01_armbian, baudrate=1500000, boot_targets='mmc1 mmc0 nvme scsi usb pxe dhcp spi'
#     → 1.5M 看不到日志，且找不到启动项时会静默走网络启动
#
# p3（boot 分区）用 B 风格：/Image、/uInitrd、/dtb/...、/extlinux/extlinux.conf
#   * 全部用**实体文件**（A 的 /boot 里是 Image→vmlinuz-… 之类符号链接，不冒 u-boot 符号链接支持的风险）
#   * 只放启动必需的 3 样东西 + conf，约 60 MiB（p3 给 256 MiB）
#
# p4（rootfs）= A 的根分区逐字节复制（UUID 9816602b-… 不变，fstab 不用改）
#
# 用法： cd ~/test-img && sudo ./build-image-bloader.sh
#         OUT=/path sudo -E ./build-image-bloader.sh
set -euo pipefail

SRC_A="${SRC_A:-/mnt/d/shared/Armbianminimal.img}"
SRC_B="${SRC_B:-/mnt/c/Users/wzq/Downloads/default/emb3531.img}"
SRC_A_BOOT="${SRC_A_BOOT:-/mnt/a1/boot}"
OUT="${OUT:-$(pwd)}"
IMG="$OUT/emb3531-bloader-armbian.img"
LFS=0FC63DAF-8483-4772-8E79-3D69D8477DE4
BAUD="${BAUD:-115200}"

P1S=64;     P1N=16320      # idbloader   (B 的有效长度 ~195 KiB, 仍在 8 MiB 内)
P2S=16384;  P2N=8192       # uboot.itb   (B 的 itb 613 KiB, 给 4 MiB)
P3S=32768;  P3N=524288     # boot 256 MiB
P4S=557056; P4N=3694592    # rootfs 1804 MiB (= A 的根分区)
DISK_MiB=2100
B_HEAD_SECT=17610          # B 的有效引导区结束（其 p3 起点）→ 只搬这些扇区

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -r "$SRC_A" ] || die "找不到 $SRC_A"; [ -r "$SRC_B" ] || die "找不到 $SRC_B"
[ -d "$SRC_A_BOOT" ] || die "$SRC_A_BOOT 未挂载（sudo mount -o loop,ro,noload,offset=16777216 -t ext4 '$SRC_A' /mnt/a1）"
mkdir -p "$OUT"; cd "$OUT"

log "0) 准备"
echo "   A(内容) = $SRC_A"
echo "   B(引导) = $SRC_B"
echo "   输出    = $IMG  (${DISK_MiB} MiB)"
rm -f "$IMG" "$OUT/p3-boot-b.img"
truncate -s ${DISK_MiB}M "$IMG"

log "1) 搬入 B 的引导链（LBA 64 的 idbloader + LBA 16384 的 u-boot.itb）"
dd if="$SRC_B" of="$IMG" bs=512 count=$B_HEAD_SECT conv=notrunc status=none
dd if=/dev/zero of="$IMG" bs=512 seek=$B_HEAD_SECT count=$((P3S-B_HEAD_SECT)) conv=notrunc status=none
sync

log "2) GPT 分区表（p3 用 Linux fs 类型，不用 B 的 ESP GUID）"
sfdisk --force --no-reread "$IMG" <<EOF
label: gpt
label-id: 22334455-1234-1234-1234-1234567890ab
first-lba: 34
start=$P1S, size=$P1N, name=idbloader, type=$LFS, uuid=11111111-0000-0000-0000-000000000001
start=$P2S, size=$P2N, name=uboot,     type=$LFS, uuid=22222222-0000-0000-0000-000000000002
start=$P3S, size=$P3N, name=boot,      type=$LFS, uuid=33333333-0000-0000-0000-000000000003
start=$P4S, size=$P4N, name=rootfs,    type=$LFS, uuid=44444444-0000-0000-0000-000000000004
EOF

log "3) 制作 p3（B 风格 boot 分区，实体文件，无符号链接）"
truncate -s $((P3N/2048))M "$OUT/p3-boot-b.img"
mkfs.ext4 -q -F -b 4096 -L boot -m 0 -O ^64bit "$OUT/p3-boot-b.img"
MNT=$(mktemp -d /tmp/p3.XXXXXX)
mount -o loop "$OUT/p3-boot-b.img" "$MNT"
mkdir -p "$MNT/dtb/rockchip" "$MNT/extlinux"
cp --sparse=always "$SRC_A_BOOT/vmlinuz-6.18.63-current-rockchip64"      "$MNT/Image"
cp --sparse=always "$SRC_A_BOOT/uInitrd-6.18.63-current-rockchip64"      "$MNT/uInitrd"
cp  "$SRC_A_BOOT/dtb/rockchip/rk3399-emb-3531.dtb"                        "$MNT/dtb/rockchip/"
cp  "$SRC_A_BOOT/config-6.18.63-current-rockchip64"                       "$MNT/" 2>/dev/null || true
cat > "$MNT/extlinux/extlinux.conf" <<EOF
label EMB3531
  kernel /Image
  initrd /uInitrd
  fdt /dtb/rockchip/rk3399-emb-3531.dtb
  append root=UUID=9816602b-8a47-44ce-bd5e-df5f0fea429f rootwait rw console=ttyS2,${BAUD}n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 rk3399_pcie_ignore_serror
EOF
sync
echo "   p3 内容:"; ls -l "$MNT" | sed 's/^/     /'
echo "   p3 占用: $(du -sh --apparent-size "$MNT" | cut -f1) / $((P3N/2048)) MiB"
umount "$MNT"; rmdir "$MNT"
dd if="$OUT/p3-boot-b.img" of="$IMG" bs=1M seek=$((P3S/2048)) count=$((P3N/2048)) conv=notrunc status=none
sync

log "4) 搬入 p4 = A 的根分区（逐字节，UUID 不变）"
dd if="$SRC_A" of="$IMG" bs=1M skip=16 seek=$((P4S/2048)) count=$((P4N/2048)) conv=notrunc,sparse status=none
sync

log "5) 校验"
fdisk -l "$IMG" | sed 's/^/   /'
echo "   -- 引导 blob 与 B 对照："
for lba in 64 16384; do
  a=$(dd if="$SRC_B" bs=512 skip=$lba count=256 status=none | sha256sum | cut -c1-16)
  b=$(dd if="$IMG"    bs=512 skip=$lba count=256 status=none | sha256sum | cut -c1-16)
  printf "     LBA %-6d B=%s new=%s %s\n" $lba $a $b "$([ "$a" = "$b" ] && echo OK || echo MISMATCH)"
done
L=$(losetup -fP --show "$IMG")
echo "   -- blkid:"; blkid "${L}p3" "${L}p4" | sed 's/^/     /'
M3=$(mktemp -d); mount -o ro "${L}p3" "$M3"
echo "   -- p3 复核:"; find "$M3" -maxdepth 3 -type f -printf '     %p (%s B)\n' | sed 's|'"$M3"'||'
echo "   -- p3 extlinux.conf:"; sed 's/^/     /' "$M3/extlinux/extlinux.conf"
echo "   -- Image 与 A 的一致性:"; cmp -s "$M3/Image" "$SRC_A_BOOT/vmlinuz-6.18.63-current-rockchip64" && echo "     Image≡vmlinuz OK" || echo "     Image 不一致!"
umount "$M3"; rmdir "$M3"
M4=$(mktemp -d); mount -o ro,noload "${L}p4" "$M4"
echo "   -- p4 复核: $(grep -m1 root= "$M4/etc/fstab")"
echo "      modules: $(ls "$M4/usr/lib/modules")  firmware: $(ls "$M4/usr/lib/firmware" | wc -l) 项"
umount "$M4"; rmdir "$M4"
losetup -d "$L"
[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMG" "$OUT/p3-boot-b.img" 2>/dev/null || true

log "6) 完成：$IMG ($(du -h --apparent-size "$IMG" | cut -f1))"
cat <<EOT
刷写（同你现有方式）：
   rkdeveloptool db   rk3399_loader_v1.24.126.bin
   rkdeveloptool wl 0 emb3531-bloader-armbian.img
   rkdeveloptool rd

串口参数：**${BAUD} 8N1**（B 的 u-boot 就是 115200，整段启动单一速率）
预期时间线：
   U-Boot 2026.04-g9f61fd5b80a4 → bootflow scan(mmca0) → 找到 p3:/extlinux/extlinux.conf
   → Loading Image(35M)/uInitrd(23M)/dtb → Linux 6.18.63-current-rockchip64
   → systemd → DHCP（eth0）→ login: root（空密码直接回车）

若仍停在 U-Boot 阶段，现在日志是**可读的**，把串口输出贴出来即可定位。
回滚：重新刷 B 的 emb3531.img 或本目录下 emb3531-gpt-armbian.img。
EOT