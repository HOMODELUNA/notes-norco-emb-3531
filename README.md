# EMB-3531 内核移植记录（WiFi 与 PCIe）

本仓库记录 EMB-3531（RK3399）主板的两个内核移植目标：板载无线网卡驱动，PCIe x4 转 SATA 支持。

## 结果

| 目标 | 结果 | 说明 |
| --- | --- | --- |
| 自编内核 | 成功 | 版本 `6.18.24-emb3531`，134 个模块 |
| 无线网卡驱动 | 成功 | `rtl8xxxu`，芯片 RTL8188EUS |
| 无线自动联网 | 成功 | 装天线后稳定连接 `Xia***915`，信号 -59 dBm |
| PCIe 转 SATA | 失败 | 链路状态机停在 Detect.Active |
| 串口调试 | 失败 | 疑 RS232 电平，需要 USB 转 RS232 线 |

WiFi 全部功能可用。PCIe 在软件层已排除全部可调项，剩余疑点在供电。

## 最新进度（2026-11-25）

装上 `ANT1` 天线后重新测试无线，结果记录在 [wifi-config.md](wifi-config.md)。

| 项目 | 结果 |
| --- | --- |
| 天线 | 已安装 2.4 GHz 天线 |
| 关联 SSID | `Xia***915`，BSSID `f0:0c:51:28:ce:0a` |
| 信号 | -59 dBm（平均 -57 dBm），信道 9，20 MHz |
| 链路质量 | 发送重传 0 次，发送失败 0 次，信标丢失 0 个 |
| 地址 | `192.168.1.8/24`，DHCP，metric 600 |
| 待处理 | 监管数据库无效（`country 00`），用户不在 `netdev` 组 |

此前未装天线时 `Xia***915` 只有 -91 dBm 且四次握手超时，现已在 -59 dBm 稳定关联。

## 硬件

| 项目 | 值 |
| --- | --- |
| 主板 | EMB-3531，SoC 为 RK3399 |
| 系统盘 | eMMC，容量 14.7 GiB |
| 电源 | DC 12 V，2 A，圆口输入 |
| 无线芯片 | RTL8188EUS，USB `0bda:8179`，1T1R 2.4 GHz |
| 无线天线 | 接口 `ANT1`，已安装 2.4 GHz 天线 |
| 扩展卡 | PCIe 转 SATA，型号 `SU-SA3234A` |
| 调试口 | DB9，物理层疑为 RS232 |

## 经历

### 第一阶段：镜像层

原厂镜像缺少 PCI 与 WLAN 配置。Armbian 社区版内核有这两项配置，但换内核后主板不启动。

做法：取原厂镜像的分区结构，装入社区版镜像的根文件系统。系统设置在没有 root 的情况下用字节级补丁写入，其中 CRC32C 校验和由脚本重算。

结果：得到 `emb3531-v3.img`，可刷写，可启动。

### 第二阶段：内核层

社区版内核在本板两次启动都失败。kexec 交接也失败，两个内核都会失联。

做法：用原厂 SDK 的配置为基线，自编 vanilla 6.18.24。启动切换改用 U-Boot 标签，共 5 个。

本阶段的坑：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 板上编译报「需要整数表达式」 | `free -m` 输出中文表头 | 改读 `/proc/meminfo` |
| `CONFIG_PHY_ROCKCHIP_PCIE` 未生效 | 配置文件同一项出现两次 | 删除重复行 |
| `CONFIG_RTL8XXXU` 未出现在配置里 | 依赖 `LEDS_CLASS`，而 `NEW_LEDS` 关闭 | 启用两个选项 |
| 主机编译报 `can't open …/cc*.s` | 编译进程继承沙箱临时目录 | 设 `TMPDIR=/var/tmp` |

### 第三阶段：设备树层

自编设备树启动挂死两次，每次都要刷机恢复。

原因有两个：

1. 新增稳压器节点会挂死。无线供电改为用户态服务 `wifi-power.service` 处理。
2. `phy@f780` 是 eMMC 的 PHY。早期补丁把它关闭，导致根文件系统找不到。

做法：全部测试设备树从原厂设备树逐字节派生，只改 `status`、`num-lanes`、`max-link-speed` 三个属性。读写工具为 `dtbedit.py`，不依赖 `dtc`。

### 第四阶段：PCIe 排查

PCIe 驱动改为模块，并加入内核参数黑名单。这样探测失败只需要卸载模块，不必刷机。

测试覆盖 4 种组合：1 lane 与 4 lane，gen1 与 gen2，槽位供电引脚未拉高与拉高。全部返回 `PCIe link training gen1 timeout!`。

追加取证：

| 证据 | 读数 | 含义 |
| --- | --- | --- |
| `PCIE_CLIENT_DEBUG_OUT_0` | `0x00320001` | LTSSM 为 `0x01`，Detect.Active |
| `PCIE_CLIENT_BASIC_STATUS1` | `0x00080001` | 链路状态位为 0 |
| PHY `0xff77f7b0` | `0x00000000` | 4 条 lane 的接收器检测位全为 0 |
| PHY `0xff77f780` | `0x00000A00` | PLL 锁定且输出使能 |

移植两个上游补丁后仍然失败：PHY 复位（Armbian PR 6057），链路训练重试（Armbian PR 4308）。

结论：对端在电气层没有呈现接收器终端电阻。软件可调项已全部排除。

## 项目结构

```
test-img/
├── README.md                 本文件
├── overview.md               A/B 两个原厂镜像的对比
├── 1122-status.md            系统状态、编译环境、无线联网
├── wifi-config.md            装天线后的 wlan0 复测记录（最新进度）
├── 1122-pcie.md              PCIe 全部测试与读数
├── 1121-status-1.md          早期阶段记录
├── 1122-plan.md              早期计划
├── patches/                  内核补丁与说明
├── emb3531-headless-sdk/     原厂 SDK，含 defconfig、dts、dtb 补丁
├── scripts/                  工具脚本与运行期脚本
│   ├── README.md             脚本索引
│   └── old/                  已停用的历史脚本
├── host-build-out/           交叉编译产物，含 config
├── v2/                       部署用内核、设备树、模块
├── emb3531-v3.img            可刷写镜像
├── make-image-v3.sh          最新版镜像构建
├── host-build-kernel.sh      主机交叉编译内核
├── extlinux-v3.conf          启动标签 l0 至 l4
└── extlinux-v4.conf          启动标签 l0 至 l5
```

| 分组 | 内容 |
| --- | --- |
| 文档 | 6 个 Markdown 文件，见下节 |
| 内核补丁 | `patches/` 两个补丁，另加 SDK 内 3 处改动 |
| 镜像构建 | `make-image-v3.sh`，根目录唯一构建入口 |
| 内核编译 | `host-build-kernel.sh` |
| 工具脚本 | `scripts/` 内 9 个脚本，见 [scripts/README.md](scripts/README.md) |
| 历史脚本 | `scripts/old/` 内 13 个脚本 |

内核源码树、`kernel-out`、`build-out` 与早期镜像已删除。重新编译需要先下载 `linux-6.18.24` 源码包。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [wifi-config.md](wifi-config.md) | 2026-11-25 装天线后的 wlan0 复测：关联状态、链路质量、网络管理现状、后续路线 |
| [1122-status.md](1122-status.md) | 当前状态、编译环境、启动标签、无线驱动与联网、已解决的问题 |
| [1122-pcie.md](1122-pcie.md) | PCIe 硬件、测试记录、寄存器读数、对照资料、补丁存盘 |
| [patches/README.md](patches/README.md) | 两个内核补丁的来源、应用方法、校验值 |
| [overview.md](overview.md) | A 与 B 两个镜像的分区、内核、设备树差异 |
| [1121-status-1.md](1121-status-1.md) | 第一阶段记录，镜像制作的早期细节 |
| [1122-plan.md](1122-plan.md) | 早期计划与目标拆分 |
| [scripts/README.md](scripts/README.md) | 脚本索引，含历史脚本停用原因 |

## 板上当前状态

| 项目 | 值 |
| --- | --- |
| 内核 | `6.18.24-emb3531` |
| 启动标签 | `l0`、`l2`、`l3`、`l4`、`l5` |
| 默认标签 | `l5`，建议改回 `l2` |
| 无线服务 | `wifi-power.service`，常驻持有 `gpiochip4` 第 28 线 |
| 无线联网 | `wpa_supplicant@wlan0` 加 `systemd-networkd` |
| 有线地址 | `192.168.0.126`，metric 100 |
| 无线地址 | `192.168.1.8`，metric 600（2026-11-25 复测网段 `192.168.1.0/24`） |
| 无线信号 | `Xia***915`，-59 dBm，信道 9，详见 [wifi-config.md](wifi-config.md) |

## 常用操作

| 目的 | 命令 |
| --- | --- |
| 登录板子 | `ssh emb` |
| 查看接口状态 | `networkctl status` |
| 查看关联与信号 | `/sbin/iw dev wlan0 link` |
| 查看链路统计 | `/sbin/iw dev wlan0 station dump` |
| 查看无线连接 | `wpa_cli -i wlan0 status`（需 `netdev` 组权限） |
| 扫描无线信号 | `/sbin/iw dev wlan0 scan \| grep SSID` |
| 测试 PCIe | `/root/pcie-test3.sh` |
| 查看开机耗时 | `systemd-analyze` |
| 清理中间产物 | `scripts/cleanup-intermediate.sh` |

## 已知限制

1. 手头没有万用表，无法测量槽内 12 V、3.3 V、3.3 Vaux。
2. 手头没有 NVMe 设备，无法在本板做对照。
3. 串口始终不可读，看不到 U-Boot 与内核早期日志。
4. 监管数据库无效，`iw reg get` 显示 `country 00`，发射功率上限 20 dBm，5 GHz 部分信道只能被动扫描。
5. 用户 `homodeluna` 不在 `netdev` 组，`wpa_cli` 无法连接控制套接字。
6. `/sbin` 不在登录用户的 `PATH` 里，`iw` 与 `wpa_cli` 需写全路径。

## 警告

警告：`extlinux-emb.conf` 已删除。`board-install-v2.sh` 与 `install-labels.sh` 仍引用它，重跑这两个脚本前改为引用 `extlinux-v3.conf`。

警告：PCIe 测试标签依赖模块黑名单。删除黑名单后，开机探测 PCIe 会导致挂死。

警告：禁止用 `devmem` 读 `0xfd000000` 区域。控制器时钟关闭时该操作会挂死总线。

警告：拆下 `ANT1` 天线时禁止让无线网卡长期发射。驻波比过高会损伤功放。

警告：日常使用建议把默认标签改回 `l2`。

## 外部资料

| 内容 | 地址 |
| --- | --- |
| Armbian 论坛帖，PCIe 训练故障 | https://forum.armbian.com/topic/18440-invalid-partially-fixed-pcie-training-problem/ |
| Armbian build PR 4308，链路训练重试 | https://github.com/armbian/build/pull/4308 |
| Armbian build PR 6057，PHY 复位 | https://github.com/armbian/build/pull/6057 |
| GitHub issue 116，RK3399 PCIe 端口不可用 | https://github.com/rockchip-linux/kernel/issues/116 |