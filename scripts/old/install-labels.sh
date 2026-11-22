#!/bin/bash
# install-labels.sh —— 在板上把 p3 的 extlinux.conf 换成本项目的 4 个标签，并可选切换默认项
#
# 用法（在板上执行）：
#   ./install-labels.sh            # 只写入标签，默认项保持 l2（见文件内容）
#   ./install-labels.sh l0         # 写入标签并把默认项设为 l0
#   ./install-labels.sh l3         # 写入标签并把默认项设为 l3
#   ./install-labels.sh show       # 只显示当前内容
set -euo pipefail

CONF_SRC=/root/extlinux-emb.conf
P3=/dev/mmcblk2p3
MNT=/mnt/p3
WANT=${1:-keep}

[ -f "$CONF_SRC" ] || { echo "缺 $CONF_SRC"; exit 1; }
mountpoint -q "$MNT" || mount "$P3" "$MNT"

if [ "$WANT" = show ]; then
	echo "--- 当前 $MNT/extlinux/extlinux.conf ---"
	cat "$MNT/extlinux/extlinux.conf"
	exit 0
fi

echo "备份: $MNT/extlinux/extlinux.conf.bak"
cp -f "$MNT/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf.bak"

cp -f "$CONF_SRC" "$MNT/extlinux/extlinux.conf"

if [ "$WANT" != keep ]; then
	sed -i "s/^default .*/default $WANT/" "$MNT/extlinux/extlinux.conf"
fi

sync
echo "--- 写入结果 ---"
cat "$MNT/extlinux/extlinux.conf"
echo "--- p3 里的内核与设备树 ---"
ls -l "$MNT" "$MNT/dtb"