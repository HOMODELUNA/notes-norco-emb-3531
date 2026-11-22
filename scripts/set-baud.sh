#!/bin/bash
# set-baud.sh —— 把镜像里的调试串口波特率改掉（默认 1500000 -> 115200）
#
# 改的是启动参数（内核 cmdline），即 extlinux.conf 里的 append 行：
#    console=ttyS2,1500000      ->  console=ttyS2,115200n8
# 两处都改（u-boot 优先读 p3；p4 里的 /boot 是兜底副本，保持一致）：
#    p3:/extlinux/extlinux.conf
#    p4:/boot/extlinux/extlinux.conf
#
# 用法：
#   cd ~/test-img && sudo ./set-baud.sh                # 改到 115200
#   sudo BAUD=1500000 ./set-baud.sh                    # 改回 1500000（原始状态）
#   sudo EARLYCON=1 ./set-baud.sh                      # 同时加 earlycon（见下方警告）
#
# 重要限制（不是脚本能解决的）：
#   * U-Boot 自己的 console 波特率是 CONFIG_BAUDRATE=1500000（编译期），
#     bootargs/append 影响不到它。所以刷入后：
#       - U-Boot 阶段（含 extlinux 菜单）仍是 1500000
#       - 从内核 console 初始化开始才变成 115200
#     想让 U-Boot 也 115200：刷机后在板上 `fw_printenv baudrate` 看 env 是否可持久化，
#     能的话 `fw_setenv baudrate 115200` 再重启；否则只能重编 u-boot。
#   * earlycon 警告：通用 uart8250 earlycon 假定 uartclk=29.4912MHz，而本板 uart2 是 24MHz。
#     1500000 恰好整除（divisor=1）所以没问题；115200 会被算成 ~93750 → 乱码。
#     因此 EARLYCON 默认 0；只有当你把波特率留在 1500000 时才建议开。
set -euo pipefail

IMG="${IMG:-$(pwd)/emb3531-gpt-armbian.img}"
BAUD="${BAUD:-115200}"
EARLYCON="${EARLYCON:-0}"
UART_ADDR="${UART_ADDR:-0xff1a0000}"      # dtb: serial@ff1a0000 (uart2) = ttyS2
log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -f "$IMG" ] || die "找不到镜像 $IMG"

MNT3=$(mktemp -d /tmp/baud-p3.XXXXXX); MNT4=$(mktemp -d /tmp/baud-p4.XXXXXX)
L=""
cleanup(){ set +e; umount "$MNT3" 2>/dev/null; umount "$MNT4" 2>/dev/null;
           [ -n "$L" ] && losetup -d "$L" 2>/dev/null; rmdir "$MNT3" "$MNT4" 2>/dev/null; }
trap cleanup EXIT

log "0) 挂载"
L=$(losetup -fP --show "$IMG"); echo "   loop=$L"
mount "${L}p3" "$MNT3"; mount "${L}p4" "$MNT4"
findmnt -no TARGET,SOURCE,FSTYPE -T "$MNT3" | sed 's/^/   /'
findmnt -no TARGET,SOURCE,FSTYPE -T "$MNT4" | sed 's/^/   /'

NEWCON="console=ttyS2,${BAUD}n8"
[ "$EARLYCON" = 1 ] && NEWCON="$NEWCON earlycon=uart8250,mmio32,${UART_ADDR},${BAUD}"
log "1) 目标 console 参数： $NEWCON"

patch_one(){ # $1=conf 路径(挂载点内)
  local conf="$1"
  [ -f "$conf" ] || { echo "   ! $conf 不存在，跳过"; return 0; }
  local cur; cur=$(grep -m1 '^ *append ' "$conf" || true)
  echo "   改前: $cur"
  cp -a "$conf" "${conf}.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$conf" "$NEWCON" <<'PY'
import re, sys
p, newcon = sys.argv[1], sys.argv[2]
new = newcon.split()
txt = open(p).read()
out = []
for line in txt.splitlines():
    if re.match(r'^\s*append\s', line):
        indent = line[:len(line) - len(line.lstrip())]
        toks = line.split()
        cons_new = [t for t in new if t.startswith('console=')][0]
        early_new = [t for t in new if t.startswith('earlycon=')]
        # 只替换指向 ttyS2 的那条 console=；若没有则替换第一条 console=
        idx = next((i for i, t in enumerate(toks) if re.match(r'^console=ttyS2', t)), None)
        if idx is None:
            idx = next((i for i, t in enumerate(toks) if t.startswith('console=')), None)
        out_toks, done = [], False
        for t in toks:
            if t.startswith('earlycon='):
                continue                      # earlycon 统一在末尾重建
            if (not done) and idx is not None and t == toks[idx]:
                out_toks.append(cons_new); done = True
            else:
                out_toks.append(t)
        if not done:
            out_toks.append(cons_new)
        out_toks += early_new
        line = indent + ' '.join(out_toks)
    out.append(line)
open(p, 'w').write('\n'.join(out) + ('\n' if txt.endswith('\n') else ''))
PY
  echo "   改后: $(grep -m1 '^ *append ' "$conf")"
  echo "   备份: ${conf}.bak-*"
}

log "2) p3 (boot 分区, u-boot 首选)"
patch_one "$MNT3/extlinux/extlinux.conf"
log "3) p4 (rootfs 里的 /boot 兜底副本)"
patch_one "$MNT4/boot/extlinux/extlinux.conf"

log "4) 复核"
for f in "$MNT3/extlinux/extlinux.conf" "$MNT4/boot/extlinux/extlinux.conf"; do
  printf '   %s\n' "${f#$MNT3}"; grep -nE '^\s*(kernel|initrd|fdt|append)' "$f" | sed 's/^/     /'
done

log "5) 一致性检查（p3 与 p4 的 append 应完全相同）"
a=$(grep -m1 '^ *append ' "$MNT3/extlinux/extlinux.conf" | sed 's/^ *//')
b=$(grep -m1 '^ *append ' "$MNT4/boot/extlinux/extlinux.conf" | sed 's/^ *//')
[ "$a" = "$b" ] && echo "   OK 两份一致" || echo "   ! 两份不一致，请检查"

sync
log "6) 完成"
cat <<EOT
当前内核启动串口参数：$NEWCON
刷机后的串口现象：
  1) 上电 → Rockchip loader / U-Boot / extlinux 菜单：仍是 1500000（编译期 CONFIG_BAUDRATE）
  2) 内核 console 初始化之后：115200，登录提示也在此速率
  想只用一个速率看完整个启动过程，需要在板上把 U-Boot 的 baudrate 也改掉：
      fw_printenv baudrate          # 先看 env 是否可读
      fw_setenv  baudrate 115200    # 若能写入则持久生效（需 /etc/fw_env.config 正确）
  回滚：sudo BAUD=1500000 $0   或把 extlinux.conf.bak-* 覆盖回去
EOT