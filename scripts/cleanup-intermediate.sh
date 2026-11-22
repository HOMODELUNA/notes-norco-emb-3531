#!/bin/bash
# cleanup-intermediate.sh —— 清理 test-img 目录的中间产物
#
# 默认只列出将要删除的内容，不删除任何文件。
# 用法：
#   ./cleanup-intermediate.sh            只列出
#   ./cleanup-intermediate.sh --yes      删除「安全组」
#   ./cleanup-intermediate.sh --yes --deep  同时删除「历史组」
#
# 安全组：编译输出、缓存、重复文件，全部可重新生成。
# 历史组：早期路线的产物，需要原始镜像与新脚本才能重建。
set -u

BASE=$(cd "$(dirname "$0")/.." && pwd)
cd "$BASE" || exit 1

DO=0
DEEP=0
for a in "$@"; do
	case "$a" in
		--yes) DO=1 ;;
		--deep) DEEP=1 ;;
		*) echo "未知参数: $a"; exit 2 ;;
	esac
done

SAFE=(
	kernel-out
	kernel-staging
	__pycache__
	build-out
	modules-6.18.24-emb3531.tar.gz
	p3-boot.img
	p3-boot-b.img
	p3-min.img
)
HIST=(
	emb3531-gpt-armbian.img
	emb3531-bloader-armbian.img
	emb3531-b-with-a-kernel.img
)
KEEP=(
	emb3531-v3.img
	v2
	host-build-out
	kernel
	emb3531-headless-sdk
)

total=0
echo "== 安全组 =="
for f in "${SAFE[@]}"; do
	[ -e "$f" ] || continue
	sz=$(du -sk "$f" | cut -f1)
	total=$((total + sz))
	printf "  %-38s %6.1f MiB\n" "$f" "$(echo "$sz/1024" | bc -l)"
done

if [ "$DEEP" = 1 ]; then
	echo "== 历史组 =="
	for f in "${HIST[@]}"; do
		[ -e "$f" ] || continue
		sz=$(du -sk "$f" | cut -f1)
		total=$((total + sz))
		printf "  %-38s %6.1f MiB\n" "$f" "$(echo "$sz/1024" | bc -l)"
	done
fi

printf "  合计 %.1f MiB\n" "$(echo "$total/1024" | bc -l)"

for f in "${KEEP[@]}"; do
	[ -e "$f" ] && printf "  保留 %s\n" "$f"
done

if [ "$DO" = 0 ]; then
	echo
	echo "只列出，未删除。加 --yes 执行删除。"
	exit 0
fi

# 重复文件先核对，防止误删唯一副本
TAR=modules-6.18.24-emb3531.tar.gz
if [ -f "$TAR" ] && [ -f "v2/$TAR" ]; then
	if [ "$(md5sum "$TAR" | cut -d' ' -f1)" != "$(md5sum "v2/$TAR" | cut -d' ' -f1)" ]; then
		echo "警告：$TAR 与 v2/$TAR 内容不同，跳过删除"
		SAFE=("${SAFE[@]/$TAR}")
	fi
fi

echo
echo "== 开始删除 =="
for f in "${SAFE[@]}"; do
	[ -e "$f" ] || continue
	rm -rf -- "$f" && echo "  已删除 $f"
done

if [ "$DEEP" = 1 ]; then
	for f in "${HIST[@]}"; do
		[ -e "$f" ] || continue
		rm -f -- "$f" && echo "  已删除 $f"
	done
fi

echo
df -h "$BASE" | tail -1