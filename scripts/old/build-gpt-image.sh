#!/bin/bash
# build-gpt-image.sh —— 用 B 的 GPT 四分区结构 + A 的内容，制作新镜像 emb3531-gpt-armbian.img
#
# 已核实的硬性约束（来自本次镜像取证）：
#   1) Rockchip BootROM/idbloader 读固定扇区：idbloader @ LBA 64、u-boot.itb @ LBA 16384
#      A: loader 长 290,059 B（结束 LBA 566）   A: itb 长 1,171,149 B（结束 LBA 18,671）
#      → B 原来的 p2 只有 613 KiB（结束 LBA 17,609），**装不下 A 的 itb**，也容不下 A 的 itb+ p3@17610
#      → 新布局把 p3 推到 LBA 32768（=16 MiB，与 A 相同），p2 扩到 4 MiB
#   2) A 的 /boot 已用 118 MiB（Image 35M + uInitrd 23M + initrd.img 23M + dtb 目录 32M + System.map 5.6M
#      + config 264K + overlay 134 个 dtbo）→ B 的 p3 只有 20 MiB 远远不够 → 新 p3 = 256 MiB
#   3) A 的根分区 = 3,694,592 扇区（1804 MiB，已用 1499 MiB）→ 逐字节原样搬到 p4，
#      ext4 的 UUID(9816602b-8a47-44ce-bd5e-df5f0fea429f)/label(armbi_root)/权限/xattr 全部不变，
#      /etc/fstab 与 root=UUID= 都不用改
#   4) 启动参数**不要**沿用 B 的 root=/dev/mmcblk2p4：A 的 dtb 把 eMMC alias 成 mmc0（B 的 dtb 是 mmc2），
#      用 UUID 才与分区编号无关
#   5) boot 分区类型 GUID 用 0FC63DAF-8483-4772-8E79-3D69D8477DE4（Linux fs），不用 B 的 ESP GUID
#      C12A7328-F81F-11D2-…，否则插 Windows 会被当 ESP 提示格式化
#   6) sgdisk 默认 2048 扇区对齐，会把 start=64 悄悄改成 2048（实测）→ 本脚本用 sfdisk --force 写表（实测精确落位）
#   7) mke2fs -d 以普通用户运行会把 uid/gid 写成 1000（实测）→ 第 4 步必须 sudo
#
# 用法：  cd /home/homodeluna/test-img && sudo -E ./build-gpt-image.sh   （必须 root，为了 p3 的属主正确）
#         工作目录 = 调用脚本时的当前目录；产物与中间文件都落在那里
#         想换目录：OUT=/path ./build-gpt-image.sh
set -euo pipefail

SRC_A="${SRC_A:-/mnt/d/shared/Armbianminimal.img}"                       # 原 Armbianminimal.img 改名后的文件（已核实同一 rootfs）
SRC_B="${SRC_B:-/mnt/c/Users/wzq/Downloads/default/emb3531.img}"          # 仅作参考，不被本脚本写入
SRC_A_BOOT="${SRC_A_BOOT:-/mnt/a1/boot}"                                  # A 的 /boot（sudo mount -o loop,ro,noload,offset=16777216）
OUT="${OUT:-$(pwd)}"                     # 默认就是当前工作目录
IMG="$OUT/emb3531-gpt-armbian.img"
cd "$OUT"
LFS=0FC63DAF-8483-4772-8E79-3D69D8477DE4

# 布局（扇区，512B）—— 已用算术核实
P1S=64;      P1N=16320          # idbloader  8 MiB   (64..16383)
P2S=16384;   P2N=8192           # uboot      4 MiB   (16384..24575)
P3S=32768;   P3N=524288         # boot       256 MiB (32768..557055)
P4S=557056;  P4N=3694592        # rootfs     1804 MiB(557056..4251647)
DISK_MiB=2100                  # 需要 ≥ (4251647+34)/2048 = 2076 MiB → 2100 有余量
P3_MiB=$((P3N/2048)); P4_MiB=$((P4N/2048))
P3_byte_MiB=$((P3S/2048)); P4_byte_MiB=$((P4S/2048))   # 32 MiB / 272 MiB（均为 MiB 对齐）

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ -r "$SRC_A" ] || die "找不到 $SRC_A（注意原镜像已被改名/复制，请确认是同一份：rootfs label=armbi_root）"
[ -d "$SRC_A_BOOT" ] || die "$SRC_A_BOOT 未挂载；先 sudo mount -o loop,ro,noload,offset=16777216 -t ext4 '$SRC_A' /mnt/a1"
[ "$(id -u)" = 0 ] || die "请用 sudo 运行（mke2fs -d 需要 root 才能写入 root:root 属主）"
mkdir -p "$OUT"; df -Pm "$OUT" | awk -v need=$((DISK_MiB+600)) 'NR==2{if($4<need) exit 1} ' || die "$OUT 剩余空间不足（需 ~$((DISK_MiB+600)) MiB）"
log "工作目录：$OUT（产物 $IMG，中间文件 p3-boot.img / mnt-p3 / loop.path）"
command -v sfdisk >/dev/null || die "缺 sfdisk"

log "0) 参照：B 的原始 GPT（本脚本不修改 B）"
sfdisk -d "$SRC_B" | sed -n '1,12p'

log "1) 新建 $IMG = ${DISK_MiB} MiB（若当前目录在 /mnt/c 或 /mnt/d 上：NTFS/9p 不支持稀疏、速度慢，建议先在本目录天然 ext4 下做完再拷）"
rm -f "$IMG" "$OUT/p3-boot.img"
truncate -s ${DISK_MiB}M "$IMG"

log "2) 原样搬运 A 的前 16 MiB 裸引导区（保住 LBA64 的 idbloader 与 LBA16384 的 u-boot.itb）"
dd if="$SRC_A" of="$IMG" bs=1M count=16 conv=notrunc status=none
# A 的 MBR（LBA0）随后会被 sfdisk 的保护性 MBR 覆盖，属预期
sync

log "3) 写 GPT 分区表（精确落位，p3 用 Linux fs 类型而非 ESP）"
sfdisk --force --no-reread "$IMG" <<EOF
label: gpt
label-id: 12345678-1234-1234-1234-1234567890ab
first-lba: 34
start=$P1S, size=$P1N, name=idbloader, type=$LFS, uuid=11111111-0000-0000-0000-000000000001
start=$P2S, size=$P2N, name=uboot,     type=$LFS, uuid=22222222-0000-0000-0000-000000000002
start=$P3S, size=$P3N, name=boot,      type=$LFS, uuid=33333333-0000-0000-0000-000000000003
start=$P4S, size=$P4N, name=rootfs,    type=$LFS, uuid=44444444-0000-0000-0000-000000000004
EOF
# 可选：给 boot 分区打 legacy-BIOS-bootable 位（老 u-boot 的 devplist 兜底；实测 B 全为 0，
# 两份 u-boot 都是 bootstd/bootmeth_extlinux，会扫所有分区，因此非必需）
# sgdisk --attributes=3:set:2 "$IMG" >/dev/null

log "4) 制作 p3（boot 分区）：内容=A 的 /boot，布局仿 B（Image 在分区根，路径不带 /boot 前缀）"
truncate -s ${P3_MiB}M "$OUT/p3-boot.img"
mkfs.ext4 -q -F -b 4096 -L boot -m 0 -O ^64bit "$OUT/p3-boot.img"
# 先挂载再拷贝（而不是 mke2fs -d），以确保 uid/gid=0、符号链接与权限逐字节保真
mkdir -p "$OUT/mnt-p3"
mount -o loop "$OUT/p3-boot.img" "$OUT/mnt-p3"
cp -a "$SRC_A_BOOT/." "$OUT/mnt-p3/"
# 把 A 的 extlinux.conf 从 /boot/ 前缀改成 p3 根相对路径（B 风格），root 继续用 A 的 UUID
mkdir -p "$OUT/mnt-p3/extlinux"
sed -e 's|^  kernel /boot/|  kernel /|' \
    -e 's|^  initrd /boot/|  initrd /|' \
    -e 's|^  fdt /boot/|  fdt /|' \
    "$SRC_A_BOOT/extlinux/extlinux.conf" > "$OUT/mnt-p3/extlinux/extlinux.conf"
# dtb 目录：A 里是 /boot/dtb -> dtb-6.18.xx（cp -a 后仍有效），保持 /dtb/rockchip/rk3399-emb-3531.dtb 可达
umount "$OUT/mnt-p3"
dd if="$OUT/p3-boot.img" of="$IMG" bs=1M seek=$P3_byte_MiB count=$P3_MiB conv=notrunc status=none
sync

log "5) 搬运 p4（根分区）：A 的分区字节级复制，不 mkfs、不改 UUID/fstab"
dd if="$SRC_A" of="$IMG" bs=1M skip=16 seek=$P4_byte_MiB count=$P4_MiB conv=notrunc,sparse status=none
sync

log "6) 校验"
fdisk -l "$IMG"
sfdisk -d "$IMG"
echo "-- 引导 blob 是否与 A 一致（应 identical）"
for off in $((P1S*512)) $((P2S*512)); do
  n=$((32*1024))
  a=$(dd if="$SRC_A" bs=1 skip=$off count=$n status=none | sha256sum | cut -d' ' -f1)
  b=$(dd if="$IMG"    bs=1 skip=$off count=$n status=none | sha256sum | cut -d' ' -f1)
  printf "  LBA %6d  A=%s  new=%s  %s\n" $((off/512)) "${a:0:16}" "${b:0:16}" "$([ "$a" = "$b" ] && echo OK || echo MISMATCH)"
done
echo "-- p4 起始的 ext4 超级块（应见 armbi_root / UUID 9816602b…）"
losetup -fP --show "$IMG" > "$OUT/loop.path" || die "losetup 失败"
L=$(cat "$OUT/loop.path")
blkid "$L"p3 "$L"p4 || true
echo "-- p3 内容"
mkdir -p "$OUT/mnt-p3"; mount -o ro "$L"p3 "$OUT/mnt-p3"
ls -l "$OUT/mnt-p3" | head; echo "  --- extlinux.conf:"; cat "$OUT/mnt-p3/extlinux/extlinux.conf"
umount "$OUT/mnt-p3"
echo "-- p4 挂载 + fstab 自检"
mkdir -p "$OUT/mnt-p4"; mount -o ro,noload "$L"p4 "$OUT/mnt-p4"
grep -E 'UUID|LABEL' "$OUT/mnt-p4/etc/fstab" | head -3
ls "$OUT/mnt-p4/usr/lib/modules" ; ls "$OUT/mnt-p4/usr/lib/firmware" | wc -l
umount "$OUT/mnt-p4"; losetup -d "$L"

log "7) 完成。产物：$IMG ($(du -h "$IMG" | cut -f1))，工作目录 $OUT"
# sudo 会留下 root 属主的产物，交还给调用者
if [ -n "${SUDO_UID:-}" ]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMG" "$OUT/p3-boot.img" 2>/dev/null || true; fi
cat <<'EOT'
下一步（上板前）
  * 整盘写入（BootROM 需要 LBA64/LBA16384，不能只刷某个分区）：
      dd if=emb3531-gpt-armbian.img of=/dev/mmcblkN bs=4M conv=fsync status=progress
      或 rkdeveloptool wl 0 emb3531-gpt-armbian.img
  * 刷写会摧毁现有 B 的 p1..p4；请确认已保留 B 原镜像。
  * 串口 1500000（A 的 dtb stdout-path），不是 B 的 115200。
已知遗留
  * apt 升级内核时 Armbian 的 postinst 会把 extlinux.conf 重新写成 `/boot/...` 前缀；
    若把 p3 挂成 /boot 则路径自洽但 u-boot 读到的分区根路径不同 —— 需在板上验证一次
    （最省事：不挂载 p3，升级后重跑本脚本第 4 步的 sed 部分）。
  * p1/p2 无文件系统（与 B 相同），lsblk 挂载它们会失败，属预期。
EOT
