#!/bin/bash
# emb-firstboot.sh —— 首次开机补齐运行期依赖（需要联网，DHCP 已自带）
set -u
PKGS="gpiod usbutils iw wpasupplicant wireless-regdb pciutils device-tree-compiler firmware-realtek"
need=0
command -v gpioset >/dev/null || need=1
[ -f /usr/lib/firmware/rtlwifi/rtl8188eufw.bin ] || need=1
[ "$need" = 0 ] && exit 0

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 update -qq || exit 0
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 install -y -qq $PKGS || exit 0

systemctl restart wifi-power.service || true
exit 0