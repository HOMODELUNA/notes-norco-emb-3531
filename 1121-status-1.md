# EMB-3531 测试进度

日期：2026-11-21
状态：串口故障未定位。静态地址镜像待刷写。

## 1. 目标

1. 用 B 的分区结构装 A 的内容。
2. 让系统开机自动配置网络地址。
3. 让 root 免密码登录。

## 2. 输入文件

| 代号 | 路径 | 大小 |
| --- | --- | --- |
| A | `/mnt/d/shared/Armbianminimal.img` | 1908408320 字节 |
| B | `/mnt/c/Users/wzq/Downloads/default/emb3531.img` | 398458880 字节 |

A 是 Armbian 社区镜像。B 是厂商镜像。两块镜像都面向 Rockchip RK3399 的 EMB-3531 板。

## 3. 已确认的事实

### 3.1 分区结构

| 项 | A | B |
| --- | --- | --- |
| 分区表 | MBR（主引导记录），1 个分区 | GPT（GUID 分区表），4 个分区 |
| 引导区 | 前 16 MiB 不登记为分区 | `idbloader` 与 `uboot` 登记为分区 |
| boot 分区 | 无 | 20 MiB，类型写成 EFI 系统 |
| rootfs 分区 | LBA 32768 起，1804 MiB | 351.4 MiB，剩余 38.1 MiB |

A 把内核放在 rootfs 的 `/boot` 目录。B 把内核放在独立 boot 分区。

### 3.2 引导链

| 项 | A | B |
| --- | --- | --- |
| U-Boot 版本 | `2026.01_armbian` | `2026.04-g9f61fd5b80a4-dirty` |
| 波特率 | 1500000 | 115200 |
| `boot_targets` | `mmc1 mmc0 nvme scsi usb pxe dhcp spi` | `mmc0` |
| `bootdelay` | 0 | 2 |

B 的 U-Boot 只扫描 eMMC。A 的 U-Boot 扫描 8 个目标，包括网络启动。

### 3.3 内核

| 项 | A | B |
| --- | --- | --- |
| 版本 | `6.18.63-current-rockchip64` | `6.18.24+` |
| 模块数 | 3576 | 130 |
| initrd | 有，24 MB | 无 |
| `/lib/firmware` | 1117 个文件，523 MB | 目录不存在 |

两个内核的模块版本字符串不同。模块不能互换。

### 3.4 调试串口

| 项 | 值 |
| --- | --- |
| 设备节点 | `ttyS2`，对应 `serial@ff1a0000` |
| 引脚 | `GPIO4_C3`、`GPIO4_C4`，功能 1 |
| 电平 | TTL（晶体管-晶体管逻辑）3.3 V |

A 的启动参数是 `console=ttyS2,1500000 console=tty0`。启动参数里没有 `earlycon`。

## 4. 已完成的工作

### 4.1 脚本

| 脚本 | 作用 |
| --- | --- |
| `build-gpt-image.sh` | 用 A 的引导链建四分区镜像 |
| `build-image-bloader.sh` | 用 B 的引导链装 A 的内容 |
| `set-image-settings.sh` | 加 DHCP（动态主机配置协议）配置，清空 root 密码 |
| `set-baud.sh` | 改内核控制台波特率 |
| `patch-static-ip.py` | 直接改镜像：静态地址、root 密码、SSH（安全外壳协议）配置 |
| `serial-tool.py` | 串口自环、速率扫描、原始字节采集 |

### 4.2 产物

| 镜像 | 内容 | 状态 |
| --- | --- | --- |
| `emb3531-gpt-armbian.img` | A 引导链，GPT 四分区 | 已刷写，启动故障 |
| `emb3531-bloader-armbian.img` | B 引导链，静态地址 | 已改好，待刷写 |

两个镜像都是 2202009600 字节。

### 4.3 镜像内改动

| 文件 | 改动 |
| --- | --- |
| `/etc/shadow` | root 密码字段清空 |
| `/etc/ssh/sshd_config` | `PermitEmptyPasswords yes` |
| `/usr/lib/systemd/network/80-wifi-adhoc.network` | 内容改为静态地址配置 |

静态地址是 `192.168.0.123/24`。网关与 DNS 都是 `192.168.0.1`。

警告：root 无密码，SSH 允许空密码。同一网段任何人都能登录。该镜像仅用于调试网络。

### 4.4 校验结果

p4 分区的 ext4 带 `metadata_csum` 与 `csum_seed` 特性。改写后重算 inode 校验和。`/etc` 全树 31695 个 inode 校验全部通过。超级块校验通过。

## 5. 当前故障

1. 串口在 115200 与 1500000 两个速率都只收到乱码。
2. 刷 `emb3531-gpt-armbian.img` 后，路由器无 DHCP 记录。
3. 刷 `emb3531-bloader-armbian.img` 后，串口仍乱码。

已确认第 2 条的根因。该镜像的 rootfs 是 A 的原版拷贝。原版没有网络配置。所以无 DHCP 属于预期结果。

第 3 条指向串口链路。B 的 U-Boot 在这块板能正常启动。它的波特率是 115200。

## 6. 下一步

前置条件：PC 与板子接同一台交换机。PC 网段是 `192.168.0.0/24`。

1. 刷写 `emb3531-bloader-armbian.img`。
2. 等待 60 秒。
3. 执行 `ping 192.168.0.123`。
4. 如果 `ping` 不通，执行 `arp -a`，查该地址的 MAC 记录。
5. 如果 `ping` 通，执行 `ssh root@192.168.0.123`，密码直接回车。
6. 执行 `cat /proc/cmdline`，确认 `console=ttyS2,115200n8`。
7. 执行 `dmesg | grep -iE 'tty|8250|stmmac'`，查串口与网卡驱动。
8. 短接适配器 TX 与 RX，执行 `python serial-tool.py loopback COM5 115200`。

第 8 步验证适配器与驱动。回显正常说明问题在接线或引脚。

## 7. 未确认项

| 项 | 现状 |
| --- | --- |
| 串口乱码根因 | 待自环测试与接线检查 |
| bloader 镜像能否启动 | 待刷写验证 |
| U-Boot 是否命中启动项 | p3 的 `extlinux.conf` 在分区根，U-Boot 搜索前缀含 `/boot/` |
| `fw_setenv baudrate` | 镜像无 `/etc/fw_env.config`，待板上确认 |
| apt 升级后的启动参数 | 安装脚本重写 `extlinux.conf` 路径前缀，待板上验证 |

## 8. 文件清单

| 文件 | 说明 |
| --- | --- |
| `overview.md` | A 与 B 的详细对比 |
| `1121-status-1.md` | 本文件 |
| `emb3531-gpt-armbian.img` | 产物 1 |
| `emb3531-bloader-armbian.img` | 产物 2 |
| `p3-boot.img` | 中间文件，256 MiB |
| `rollback-shadow.bin` | 回滚数据 |