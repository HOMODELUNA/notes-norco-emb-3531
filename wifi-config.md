# wlan0 无线网卡检查记录

日期：2026-11-25（UTC）
板卡：EMB-3531，Debian 13（trixie），内核 `6.18.24-emb3531`，aarch64
方式：只读检查。本次检查不需要 root 权限。

## 1. 结论

天线已生效。wlan0 关联到 `Xia***915`，信号 -59 dBm，信道 9。

判断依据：1T1R（1 发 1 收）网卡在 -57 至 -59 dBm 属于良好区间。发送重传 0 次，发送失败 0 次，信标丢失 0 个。

## 2. 硬件与驱动

| 项 | 值 |
| --- | --- |
| 网卡 | USB Realtek RTL8188EUS，ID `0bda:8179`，1T1R |
| 总线位置 | USB 2.0，端口 `2-1.4` |
| MAC | `d4:b7:61:7b:63:75` |
| 驱动 | `rtl8xxxu`，内核内置 |
| 固件 | `rtlwifi/rtl8188eufw.bin`，修订号 28.0，签名 `0x88e1` |

## 3. 关联状态

采集命令：`/sbin/iw dev wlan0 link`。采集时间 2026-11-25 12:20（UTC）。

| 项 | 值 |
| --- | --- |
| SSID | `Xia***915` |
| BSSID | `f0:0c:51:28:ce:0a` |
| 频点 | 2452 MHz，信道 9，宽度 20 MHz |
| 信号 | 当前 -59 dBm，平均 -57 dBm |
| 发射功率 | 20.00 dBm |
| 发送速率 | 52.0 Mbit/s，MCS 5 |
| 接收速率 | 6.0 Mbit/s |
| 收包 | 11769 个 |
| 发包 | 2646 个 |
| 发送重传 | 0 次 |
| 发送失败 | 0 次 |
| 信标接收 | 4436 个 |
| 信标丢失 | 0 个 |
| 连接时长 | 481 秒 |
| 地址 | `192.168.1.8/24`，DHCP |
| 默认路由 | `192.168.1.1`，metric 600 |

说明：eth0 的默认路由 metric 是 100。板卡优先走 eth0。

## 4. 网络管理现状

系统用三个 systemd 服务管理网络。

| 组件 | 服务 | 状态 |
| --- | --- | --- |
| 地址与路由 | `systemd-networkd` | active，enabled |
| 无线关联 | `wpa_supplicant@wlan0` | active，enabled |
| 无线关联备用实例 | `wpa_supplicant.service` | active，enabled |

配置文件：

| 文件 | 内容 |
| --- | --- |
| `/etc/systemd/network/10-ethernet-dhcp.network` | eth0，DHCP，DNS 为 `8.8.8.8` 和 `1.1.1.1`，metric 100 |
| `/etc/systemd/network/20-wlan0.network` | wlan0，DHCP，metric 600 |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | SSID 与密钥，权限 0600 |

未安装的组件有四个：`ifupdown`、`NetworkManager`、`systemd-resolved`、`resolvconf`。

`dhcpcd-base` 已安装。`dhcpcd` 服务未运行。`/etc/network/interfaces` 只有 `source` 一行。`/etc/wpa_supplicant/ifupdown.sh` 没有调用者。`/etc/resolv.conf` 是普通文件，内容只有 `nameserver 8.8.8.8`。

## 5. 检查过程

1. 查看系统版本：`uname -a`、`cat /etc/os-release`。
2. 查看接口：`ip -br link`。
3. 查找无线工具：`which nmcli rfkill iw`。
4. 查看驱动与总线：`readlink -f /sys/class/net/wlan0/device`、`lsusb`、`lsmod`。
5. 查看内核日志：`dmesg`。
6. 查看服务状态：`systemctl status 'wpa_supplicant*'`、`systemctl is-active ...`。
7. 查看地址与路由：`ip -br addr show wlan0`、`ip route`。
8. 查看关联：`/sbin/iw dev wlan0 link`。
9. 查看统计：`/sbin/iw dev wlan0 station dump`。
10. 查看监管域：`/sbin/iw reg get`。
11. 查看 networkd 配置：`ls -l /etc/systemd/network/`、`networkctl`。
12. 查看已装网络包：`dpkg -l | grep -iE 'network|dhcp|wpa'`、`apt-cache policy network-manager`。

注意：`/sbin` 不在登录用户的 `PATH` 里。`iw` 与 `wpa_cli` 必须写全路径。

## 6. 三个观察结果

### 6.1 监管数据库无效

`dmesg` 显示 `cfg80211: loaded regulatory.db is malformed or signature is missing/invalid`。`iw reg get` 显示 `country 00`。

后果有两个：

- 发射功率上限为 20 dBm。
- 5 GHz 部分信道只能被动扫描。

### 6.2 没有 /proc/net/wireless

内核 6.18 删除了 WEXT，`/proc/net/wireless` 不存在。查信号必须用 `iw`。

### 6.3 wpa_cli 缺权限

`/run/wpa_supplicant` 的属主是 root，组是 `netdev`。用户 `homodeluna` 不在 `netdev` 组。`wpa_cli` 因此无法连接控制套接字。

## 7. 安装 NetworkManager 的冲突

`nmtui` 只在 `network-manager` 包内。安装该包会同时安装 NetworkManager 守护进程。当前系统与 NetworkManager 有三处冲突。

| 层 | 冲突 |
| --- | --- |
| 地址 | `systemd-networkd` 与 NetworkManager 都管理 eth0 和 wlan0。两个 DHCP 客户端争用同一接口。 |
| 关联 | `wpa_supplicant@wlan0` 与 NetworkManager 都控制 wlan0。NetworkManager 会启动自己的 supplicant 进程。 |
| DNS | `/etc/resolv.conf` 是普通文件。NetworkManager 会覆写该文件。 |

补充：`ifupdown` 未安装。NetworkManager 不会把 eth0 和 wlan0 视为 unmanaged。

### 7.1 路线 A：不安装 NetworkManager

1. 运行 `sudo usermod -aG netdev homodeluna`。
2. 重新登录，使新组生效。
3. 运行 `wpa_cli -i wlan0`。
4. 在交互界面执行 `scan`、`scan_results`、`add_network`、`set_network`、`enable_network` 五个子命令。

要固定 SSID 与密钥时，改 `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`，再重启 `wpa_supplicant@wlan0`。

### 7.2 路线 B：完整切换到 NetworkManager

警告：切换过程中 eth0 的地址会变化。SSH 会话会断开。操作必须在串口 `ttyS2`（115200 bps）上完成。

1. 运行 `sudo mkdir -p /root/netbak`。
2. 运行 `sudo systemctl disable --now wpa_supplicant@wlan0`。
3. 运行 `sudo systemctl disable --now systemd-networkd.socket systemd-networkd-wait-online systemd-networkd`。
4. 运行 `sudo mv /etc/systemd/network/*.network /root/netbak/`。
5. 运行 `sudo apt install network-manager`。
6. 运行 `nmtui`。
7. 建立 eth0 连接，把地址方式设为 DHCP。
8. 在 eth0 连接里把 DNS 设为 `8.8.8.8` 和 `1.1.1.1`。
9. 在 eth0 连接里把 metric 设为 100。
10. 建立 wlan0 连接，输入 SSID `Xia***915` 与密钥。
11. 在 wlan0 连接里把 metric 设为 600。

说明：NetworkManager 不读取 `wpa_supplicant-wlan0.conf`。密钥要在 `nmtui` 里重新输入。`network-manager` 包推荐 `wireless-regdb`。装好后，6.1 的监管数据库错误消失。

### 7.3 路线 C：只让 NetworkManager 管理 wlan0

警告：SSH 会话走 eth0 时不会断开。wlan0 的地址会变化一次。

1. 运行 `sudo systemctl disable --now wpa_supplicant@wlan0`。
2. 运行 `sudo rm /etc/systemd/network/20-wlan0.network`。
3. 新建 `/etc/NetworkManager/conf.d/99-unmanaged.conf`。
4. 在文件里写入 `[keyfile]` 段和 `unmanaged-devices=interface-name:eth0`。
5. 运行 `sudo apt install network-manager`。
6. 运行 `nmtui`，只建立 wlan0 连接。

说明：路线 C 的 DNS 仍有两套。NetworkManager 覆写 `/etc/resolv.conf` 后，eth0 配置里的 `DNS=` 行失效。

## 8. 待确认事项

下面五项都需要 root 权限。本次检查没有执行。

| 项 | 命令 | 目的 |
| --- | --- | --- |
| 无线配置 | `sudo cat /etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | 查看 `key_mgmt` 与 `country` 字段 |
| 关联日志 | `sudo journalctl -u wpa_supplicant@wlan0 -b` | 查看四次握手是否重试 |
| 周边网络 | `sudo iw dev wlan0 scan` | 对比其他 AP 的信号强度 |
| 安装预演 | `sudo apt install -s network-manager` | 列出会安装的包 |
| 监管域 | `sudo apt install wireless-regdb` | 修正 6.1 的监管数据库 |