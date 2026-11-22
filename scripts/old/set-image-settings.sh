#!/bin/bash
# set-image-settings.sh —— 修改已构建镜像里的系统设置：
#   1) 开机自动 DHCP 启用以太网（补 systemd-networkd 的 .network，镜像里原本缺失）
#   2) root 空密码（并允许 SSH 空密码登录）
#
# 用法：  cd ~/test-img && sudo ./set-image-settings.sh
#         IMG=/path/to/emb3531-gpt-armbian.img sudo -E ./set-image-settings.sh
#
# 为什么这样改（已核实的事实）：
#   * 镜像里 systemd-networkd.service / systemd-networkd.socket / systemd-resolved.service
#     都已 enable，/etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf 也就位，
#     但 /etc/systemd/network/ 只有 00-armbian.network.readme（Match MACAddress=NONE，
#     永不匹配）→ 没有任何 DHCP 配置。
#   * /etc/netplan/10-dhcp-all-interfaces.yaml 存在，但镜像里没有 netplan 的 systemd unit
#     （netplan 不会在开机 apply）→ 不能指望它。
#   * /etc/pam.d/common-auth 已含 pam_unix.so nullok → 空密码可登录控制台；
#     /etc/securetty 只列 ttyS2 → root 可在串口控制台登录。
#   * sshd_config: PermitRootLogin yes（已开），PermitEmptyPasswords 需显式打开。
#   * 内核 cmdline 有 net.ifnames=0 → 网卡名是 eth0；stmmac/dwmac-rk 与 realtek PHY 驱动
#     在 A 的内核里是 built-in，无需装模块。
set -euo pipefail

IMG="${IMG:-$(pwd)/emb3531-gpt-armbian.img}"
IFACE_GLOB="${IFACE_GLOB:-eth* en*}"      # net.ifnames=0 → eth0；顺带兼容 en*
log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -f "$IMG" ] || die "找不到镜像 $IMG"
command -v losetup >/dev/null || die "缺 losetup"

MNT=$(mktemp -d /tmp/setimg.XXXXXX)
TAIL=""
cleanup(){ set +e; [ -n "$TAIL" ] && { umount "$MNT" 2>/dev/null; losetup -d "$TAIL" 2>/dev/null; }; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

log "0) 挂载 p4 (rootfs) 为可写"
TAIL=$(losetup -fP --show "$IMG")
echo "   loop = $TAIL"
mount "${TAIL}p4" "$MNT"
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS "$MNT"
[ -f "$MNT/etc/shadow" ] || die "挂载的内容不像 rootfs"

log "1) 以太网自动 DHCP：新增 /etc/systemd/network/10-eth0-dhcp.network"
mkdir -p "$MNT/etc/systemd/network"
cat > "$MNT/etc/systemd/network/10-eth0-dhcp.network" <<EOF
# 由 set-image-settings.sh 生成：开机即对有线网卡做 DHCP
[Match]
Name=$IFACE_GLOB

[Network]
DHCP=yes
IPv6AcceptRA=yes
LinkLocalAddressing=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
EOF
chmod 644 "$MNT/etc/systemd/network/10-eth0-dhcp.network"
cat "$MNT/etc/systemd/network/10-eth0-dhcp.network"

log "2) 确保 networkd / resolved / ssh 开机自启（直接建链接，不依赖宿主 systemctl 版本）"
ensure_link(){ # $1=want 目录 $2=链接名 $3=目标
  local d="$MNT/etc/systemd/system/$1"
  mkdir -p "$d"
  ln -sfn "$3" "$d/$2"
}
ensure_link multi-user.target.wants  systemd-networkd.service /usr/lib/systemd/system/systemd-networkd.service
ensure_link sockets.target.wants     systemd-networkd.socket  /usr/lib/systemd/system/systemd-networkd.socket
ensure_link sysinit.target.wants     systemd-resolved.service /usr/lib/systemd/system/systemd-resolved.service
ensure_link multi-user.target.wants  ssh.service              /usr/lib/systemd/system/ssh.service
ensure_link /                        dbus-org.freedesktop.resolve1.service /usr/lib/systemd/system/systemd-resolved.service
for l in multi-user.target.wants/systemd-networkd.service sockets.target.wants/systemd-networkd.socket \
         sysinit.target.wants/systemd-resolved.service multi-user.target.wants/ssh.service; do
  printf "   %-52s -> %s\n" "$l" "$(readlink "$MNT/etc/systemd/system/$l")"
done

log "3) root 空密码（/etc/shadow 第 2 字段清空，保持 inode/属主不变）"
python3 - "$MNT/etc/shadow" <<'PY'
import sys, os, stat
p = sys.argv[1]
st = os.stat(p)
lines = open(p, 'r').read().splitlines()
out, hit = [], False
for l in lines:
    f = l.split(':')
    if len(f) >= 2 and f[0] == 'root':
        f[1] = ''            # 空密码
        f[2] = '0' if len(f) > 2 else f[2]
        l = ':'.join(f); hit = True
    out.append(l)
assert hit, "shadow 里没有 root 行"
open(p, 'w').write('\n'.join(out) + '\n')
os.chmod(p, stat.S_IMODE(st.st_mode)); os.chown(p, st.st_uid, st.st_gid)
print("   root 行已清空密码字段")
PY
awk -F: '/^root:/{printf "   现在: root:%s:...  (密码字段长度=%d)\n", substr($2,1,4), length($2)}' "$MNT/etc/shadow"

log "4) SSH 允许 root 空密码登录"
sed -i -e 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' \
       -e 's/^[#[:space:]]*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' \
       -e 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' \
       "$MNT/etc/ssh/sshd_config"
grep -nE '^(PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication)' "$MNT/etc/ssh/sshd_config"

log "5) 复核：PAM nullok / securetty / host key"
grep -n 'pam_unix.so' "$MNT/etc/pam.d/common-auth" | sed 's/^/   /'
echo "   securetty: $(tr '\n' ' ' < "$MNT/etc/securetty")"
echo "   ssh host key 数量: $(ls "$MNT"/etc/ssh/ssh_host_*key 2>/dev/null | wc -l)"

log "6) 完成（卸载中）"
sync
echo
cat <<EOT
改动清单（镜像 $IMG 的 p4）：
  /etc/systemd/network/10-eth0-dhcp.network   新增，DHCP=yes
  /etc/shadow                                 root 密码字段清空
  /etc/ssh/sshd_config                        PermitRootLogin/PermitEmptyPasswords/PasswordAuthentication = yes
  启用链接                                    systemd-networkd(.service/.socket) / systemd-resolved / ssh

上板后预期：
  串口 1500000 → 出现 login: 输入 root、密码直接回车即进；或用 root@<板子IP> ssh 免密登录
  网线插入 → 约 2~5 s 内 systemd-networkd 拿到地址；\`networkctl status\` / \`ip a\` 可查
  出错排查：\`systemctl status systemd-networkd\`、\`networkctl list\`、\`journalctl -u systemd-networkd -b\`

⚠️ 安全提醒：root 空密码 + SSH 允许空密码 = 同一网段任何人都能直接进系统。
   仅限隔离调试网络；上生产前务必：
     passwd root                      # 设密码
     sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config && systemctl restart ssh
EOT