# EMB-3531 测试记录（1122）

最后更新：2026-11-25。板子当前默认标签为 `l5`，日常使用建议改回 `l2`。

> 2026-11-25 进展：`ANT1` 已装天线，`wlan0` 重新测试通过，关联 `Xia***915`，信号 -59 dBm。完整读数见 [wifi-config.md](wifi-config.md)。

## 目标

1. 自编内核，支持 PCIe x4 转 SATA。
2. 自编内核，支持板载 RTL8188EUS 无线网卡。

## 当前结论

| 项目 | 状态 |
| --- | --- |
| 内核交叉编译 | 完成 |
| 无线网卡驱动 | 完成 |
| 无线联网 | 完成，当前连接 `Xia***915` |
| 天线 | 已安装，信号 -59 dBm |
| PCIe 软件层 | 全部可调项已排除 |
| PCIe 链路 | 阻塞。链路状态机停在 Detect.Active |

PCIe 的失败位置是链路训练第一个子状态。对端没有呈现接收器终端电阻。

## 编译环境

| 项目 | 值 |
| --- | --- |
| 主机 | Ubuntu 24.04，x86_64，18 核，内存 7.5 GB |
| 交叉编译器 | `aarch64-linux-gnu-gcc` 13.3.0 |
| 内核源码 | `linux-6.18.24`，源码树已删除，重新编译需先下载 |
| 版本串 | `6.18.24-emb3531` |
| 模块数量 | 134 个 |
| 编译命令 | `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image modules dtbs` |

两处内核改动已导出为补丁，存放在 `patches/`。

关键配置：

```
CONFIG_LOCALVERSION="-emb3531"
CONFIG_PCI=y
CONFIG_PCIE_ROCKCHIP_HOST=m
CONFIG_PHY_ROCKCHIP_PCIE=m
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_RTL8XXXU=m
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_STORAGE=m
CONFIG_USB_UAS=m
```

## 镜像与启动标签

| 项目 | 值 |
| --- | --- |
| 镜像文件 | `emb3531-v3.img` |
| 镜像大小 | 734020608 字节 |
| 根分区 | `mmcblk2p4`，14.6 GB |
| 当前默认标签 | `l5` |
| 建议默认标签 | `l2` |

| 标签 | 内核 | 设备树 | PCIe 状态 |
| --- | --- | --- | --- |
| `l0` | 厂商 6.18.24 | 厂商原版 | 关闭 |
| `l2` | `6.18.24-emb3531` | 厂商原版 | 关闭 |
| `l3` | `6.18.24-emb3531` | `pcie1`，gen1，1 lane | 开 |
| `l4` | `6.18.24-emb3531` | `pcie4`，gen2，4 lane | 开 |
| `l5` | `6.18.24-emb3531` | `pcie4-ep`，含 `ep-gpios` | 开 |

标签写错时，U-Boot 回退启动 `l0`。实测：默认项误写为 `l34` 后，板子正常启动厂商内核。

`l3`、`l4`、`l5` 三个 PCIe 测试标签的用途见 [1122-pcie.md](1122-pcie.md)。

## 无线网卡驱动

| 项目 | 值 |
| --- | --- |
| 芯片 | `0bda:8179`，RTL8188EUS |
| 驱动 | `rtl8xxxu.ko` |
| 固件 | `rtlwifi/rtl8188eufw.bin`，15262 字节，版本 28.0 |
| 供电引脚 | GPIO4_D4，`gpiochip4` 第 28 线 |
| 服务 | `wifi-power.service`，`Type=simple`，常驻持有第 28 线 |
| 网卡 | `wlan0`，MAC `d4:b7:61:7b:63:75` |

## 无线联网

| 文件 | 作用 |
| --- | --- |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | SSID 与密钥，权限 600 |
| `/etc/systemd/network/20-wlan0.network` | DHCP，`RouteMetric=600`，`RequiredForOnline=no` |
| `/etc/systemd/network/10-ethernet-dhcp.network` | 有线 DHCP，metric 100 |

| SSID | 优先级 | 信号 | 结果 |
| --- | --- | --- | --- |
| `Xia***915` | 10 | -91 dBm（未装天线） | 关联成功，握手超时，回退 |
| `535***cal` | 5 | -81 dBm（未装天线） | 连接成功，密钥协商完成 |
| `Xia***915` | 10 | -59 dBm（已装天线，2026-11-25） | 稳定关联，重传与失败均为 0 |

上表前两行为 2026-11-22 未装天线时的对照数据。装上 `ANT1` 天线后复测，`Xia***915` 信号从 -91 dBm 提升到 -59 dBm，已能稳定保持连接。关联时间 481 秒内发送重传 0 次、发送失败 0 次、信标丢失 0 个。完整读数见 [wifi-config.md](wifi-config.md)。

| 接口 | 地址 | metric | 说明 |
| --- | --- | --- | --- |
| `eth0` | `192.168.0.126/24` | 100 | 默认路由，SSH 走此路径 |
| `wlan0` | `192.168.1.8/24` | 600 | 装天线后取自 DHCP，复测网段 `192.168.1.0/24` |

实测：经 `wlan0` ping 网关 4 个包 0% 丢包，平均 14.8 ms（未装天线时）。关联耗时 2 秒，取址耗时 4 秒。

板上有 `ANT1` 接口，已装 2.4 GHz 天线。WPA2-PSK 密钥长度必须为 8 至 63 个字符，`XS****` 只有 6 个字符，正确密钥为 `XS******`。

## PCIe

PCIe 的故障现象、测试过程、寄存器读数、对照资料全部见 [1122-pcie.md](1122-pcie.md)。

当前状态：阻塞。链路状态机停在 Detect.Active，对端没有呈现接收器终端电阻。

## 已解决的问题

| 故障 | 原因 | 处理 |
| --- | --- | --- |
| 板上编译报 `需要整数表达式` | `free -m` 输出中文表头 | 改读 `/proc/meminfo` |
| `CONFIG_RTL8XXXU` 未出现 | 依赖 `LEDS_CLASS`，而 `NEW_LEDS` 关闭 | 启用 `NEW_LEDS` 与 `LEDS_CLASS` |
| 主机编译报 `can't open /tmp/.ctx-mode-*` | 编译进程继承沙箱临时目录 | 换干净环境重新编译 |
| 首次开机 `apt` 失败 | 系统时钟错误，签名未生效 | 等 NTP 同步后安装 |
| 开机用户空间耗时 61.7 秒 | `wifi-power` 用 `Type=oneshot`，`gpioset` 不返回 | 改为 `Type=simple` |
| `wlan0` 状态为 `unmanaged` | `20-wlan0.network` 未写入 | 补写后执行 `networkctl reconfigure` |

## 待验证

1. ~~插入 2.4 GHz 天线到 `ANT1`，重新扫描对比信号。~~ 2026-11-25 完成，见 [wifi-config.md](wifi-config.md)。
2. ~~天线到位后单独验证 `Xia***915` 能否稳定保持连接。~~ 已完成，-59 dBm，重传 0 次。
3. 重启一次，确认开机全自动恢复，用户空间耗时降到 3 秒内。
4. 接入 USB 3.0 转 SATA 适配器，测量读写速率。
5. 修正监管数据库：安装 `wireless-regdb`，消除 `country 00`。
6. 把用户加入 `netdev` 组，使 `wpa_cli` 可用。

## 关键文件

| 文件 | 大小 | md5 |
| --- | --- | --- |
| `v2/Image-emb3531` | 17975304 | `7a7b1bc3a8cf427757de9c9e37cbc1c8` |
| `v2/rk3399-emb3531.dtb` | 59782 | `dd1be17e8af28d236a728d813b4caecd` |
| `v2/modules-6.18.24-emb3531.tar.gz` | 2238705 | `36869de0c1e9b0ac0bc4fe541490da7d` |

PCIe 设备树与内核补丁的清单见 [1122-pcie.md](1122-pcie.md)。内核补丁存放在 `patches/`。

## 警告

警告：拆下天线时禁止让无线网卡长期发射。驻波比过高会损伤功放。

警告：不要删除 `20-wlan0.network` 中的 `RouteMetric=600`。删除后 `wlan0` 可能抢占默认路由，导致 SSH 断连。
