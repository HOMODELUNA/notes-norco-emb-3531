# EMB-3531 两份镜像对比 overview

生成时间：2026-11-21（WSL2 `luna-legion`, kernel `6.18.33.2-microsoft-standard-WSL2`）
取证方式：只读探测（扇区/超级块/FDT/IKCONFIG 解析）+ 用户手动 `sudo mount -o loop,ro,noload` + `debugfs`。
**未对两份 `.img` 做任何写入。**

| 代号 | 路径 | 大小 |
|---|---|---|
| **A** | `/mnt/d/shared/Armbian_community_26.11.0-trunk.130_Norco-emb-3531_trixie_current_6.18.63_minimal.img` | 1,908,408,320 B（1.78 GiB / 3,727,360 扇） |
| **B** | `/mnt/c/Users/wzq/Downloads/default/emb3531.img` | 398,458,880 B（380 MiB / 778,240 扇） |

同一块板：Rockchip **RK3399**，NORCO/EMB-3531；同为 Debian 13 (trixie) + 同为 **mainline 6.18** 内核（都不是 5.10/6.1 Rockchip BSP）。

---

## 1. 分区结构

### A — MBR/DOS + 未分区引导裸区（Armbian 风格）
- `label: dos`, disk-id `0x714d871c`，**只有 1 条分区条目**
- LBA 0–32767 = 前 16 MiB **未分区裸区**，按固定扇区号写入引导链，`fdisk/parted/lsblk` 看不到
  - idbloader/miniloader @ LBA 64（32 KiB），`0xff` 填充至 8 MiB
  - `u-boot.itb` @ LBA 16384（8 MiB，FIT `d0 0d fe ed`），数据超过 9 MiB
  - FIT 内容：`/images/u-boot` + `atf-1..3` + `fdt-1 = rockchip/rk3399-emb-3531`，`default = config-1`
- `img1` LBA **32768**（16 MiB）起，3,694,592 扇 = 1.8 GiB，type `0x83`
  - ext4 `label=armbi_root` `uuid=9816602b-8a47-44ce-bd5e-df5f0fea429f`，**block 4 KiB**，115,680 inode，剩余 239.6 MiB
  - mkfs 时间 2026-11-13 03:29，`last_mounted=/armbian/.tmp/mount-…`（Armbian build 产物）
- **无独立 boot 分区**：内核/dtb/initrd/config 全在 rootfs 的 `/boot`

### B — GPT 4 分区（厂商 SDK 风格，引导区也登记为分区）
- `label: gpt`（保护性 MBR `0xEE`），disk-guid `2F9CA5B6-A7FC-4600-9030-B0FB75F7B7B6`，first-lba 34 / last-lba 778206，尾部 34 扇备份表

| # | 名称 | LBA | 大小 | 声明类型 | 实际内容 |
|---|---|---|---|---|---|
| 1 | `idbloader` | 64–16383 | 8 MiB | Linux fs GUID | Rockchip loader 裸 blob |
| 2 | `uboot` | 16384–17609 | 613 KiB | Linux fs GUID | `u-boot.itb`（FIT，`/images`: u-boot + `atf-1..5` + `fdt-1 = rockchip/rk3399-emb3531`） |
| 3 | `boot` | 17610–58569 | 20 MiB | **EFI System**（C12A7328…） | **实际是 ext4**：`label=boot` `uuid=80e16f5d-ae27-4e7d-afbd-e3febe459611` block 1 KiB，仅剩 1.9 MiB |
| 4 | `rootfs` | 58570–778206 | 351.4 MiB | Linux fs | ext4 `label=rootfs` `uuid=cdbafa53-d8c5-4392-82c7-2e0560153938` block **1 KiB**，90,112 inode，仅剩 38.1 MiB |

- mkfs 时间 2026-04-27 03:30；`last_mounted=/tmp/emb-final-boot-dst`、`/tmp/emb-final-rootfs-dst` → 由自研脚本 `emb-final-*` 逐分区拷贝生成，非 Armbian build
- **B.img3 内容（用 debugfs 读出，无需挂载）**：

| 路径 | 大小 |
|---|---|
| `/Image` | 16,373,768 B |
| `/dtb/rk3399-emb3531.dtb` | 59,782 B（**只有 1 个 dtb**） |
| `/extlinux/extlinux.conf` | 255 B |
| `/lost+found` | 12 KiB |

- 无 initrd、无 config、无 System.map、无 overlay 目录

```
default l0
menu title EMB3531 Headless Server
prompt 1
timeout 1

label l0
 menu label Linux 6.18.24
 linux /Image
 fdt /dtb/rk3399-emb3531.dtb
 append root=/dev/mmcblk2p4 rootwait rw console=ttyS2,115200 net.ifnames=0 earlycon=uart8250,mmio32,0xff1a0000
```
> 路径写成 `/Image`、`/dtb/…`（不带 `/boot` 前缀）→ 证实引导文件根就在 p3 分区；**B 的 rootfs 里 `/boot` 是空目录**（mtime 2026-03-03，只是挂载点），这就是「b4 的 boot 目录为空、没有设备树」的原因。

### A 的 `/mnt/a1/boot`（对照）
`Image → vmlinuz-6.18.63-current-rockchip64`(36,063,744 B)、`System.map-6.18.63`(5,807,030)、`config-6.18.63`(269,672)、`initrd.img-6.18.63`/`uInitrd`(24,029,252 / 24,029,316)、`boot.bmp`、`dtb → dtb-6.18.63-current-rockchip64`（rockchip 下 **284 个 dtb + overlay/ 目录**）、`extlinux/extlinux.conf`

```
label Armbian_community
  kernel /boot/Image
  initrd /boot/uInitrd
  fdt /boot/dtb/rockchip/rk3399-emb-3531.dtb
  append root=UUID=9816602b-8a47-44ce-bd5e-df5f0fea429f console=ttyS2,1500000 console=tty0 rk3399_pcie_ignore_serror rw no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0
```

---

## 2. Linux 内核区别

| 维度 | A | B |
|---|---|---|
| `uname` | `6.18.63-current-rockchip64` | `6.18.24+`（`+` = 本地 git 树未打 tag） |
| banner | `(build@armbian) aarch64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0, ld 2.44` `#1 SMP PREEMPT Tue Nov 10 18:07:06 UTC 2026` | `(root@debian) 同一工具链` `#1 SMP PREEMPT Mon Apr 27 11:15:13 CST 2026` |
| vermagic | `6.18.63-current-rockchip64 SMP preempt mod_unload aarch64` | `6.18.24+ SMP preempt mod_unload aarch64` → **模块不可互换** |
| 交付方式 | dpkg：`linux-image-current-rockchip64` / `linux-dtb-current-rockchip64` / `linux-u-boot-norco-emb-3531-current`（均 `26.11.0-trunk.130`）+ `/etc/kernel` hook | **无 linux-image 包**，`modules_install` 拷进 rootfs；`apt` 无法跟踪/升级内核 |
| Image | 36,063,744 B | 16,373,768 B（均未压缩 arm64 Image） |
| .ko 模块 | **3576 个 / 239 MB** | **130 个 / 5.7 MB** |
| built-in | 451 | 275 |
| initrd | uInitrd 24 MB（Debian 式） | **无** |
| config 可见性 | `/boot/config-*` 随镜像发布，`IKCONFIG(_PROC)=y` | 镜像里**没有**；已从 Image 尾部 `IKCFG_ST` 解出（130,182 B，存 `/tmp/imgcmp/B-config`） |
| `/lib/firmware` | 1117 文件 / 523 MB（armbian-firmware） | **目录不存在（0 文件）** |
| rootfs | 1499 MiB / 303 包 / Debian 13.7 | 282 MiB / 172 包 / Debian 13.4（清华源） |

config 差异（A=Debian generic + Armbian 片段，启用 5951 项；B=手工极简，启用 1451 项；A 独有 4573、B 独有 73）：

- **B 整体关闭**：`PCI`/`PCIEPORTBUS`/`PHY_ROCKCHIP_PCIE`/`NVME_CORE`（→ 无 PCIe/NVMe）、`DRM`/`DRM_ROCKCHIP`/`DRM_PANFROST`（→ 无显示无 GPU）、`SND`/`SND_SOC`、`VIDEO_ROCKCHIP_VDEC/IEP/RGA`、`CRYPTO_DEV_ROCKCHIP`、`CFG80211`/`MAC80211`/`WLAN`/`BT`（→ 无 WiFi/BT）、`TYPEC`/`PHY_ROCKCHIP_INNO_USB3`（→ USB3 SuperSpeed PHY 缺失）、`HID_SUPPORT`/`SERIO`（→ USB 键盘鼠标不可用）、`ATA`、`NUMA`、`EFI`、`KEXEC`、`DEBUG_INFO`
- **B 改为内建**（A 里是模块）：`NF_TABLES` 全家 + conntrack + bridge/vlan/veth/br_netfilter、`TCP_CONG_BBR`（且 `DEFAULT_BBR=y`，A 是 `DEFAULT_CUBIC=y`+BBR=m）、`KVM`/`VHOST`/`PSTORE`/`TEE`/`OPTEE`、SCMI 栈（`ARM_SCMI_CPUFREQ`/`REGULATOR_ARM_SCMI`/`SENSORS_ARM_SCMI`/`scmi_transport_optee`）、Coresight/STM + CMN/CCN/CCI/DSU/SPE PMU、`bfq`/`kyber`/`mq-deadline`
- **B 独有地址空间选项**：`ARM64_LPA2` + `ARM64_VA_BITS_52`/`ARM64_PA_BITS_52`（A 用 48-bit）
- **B 独有其它**：`CPU_ISOLATION`/`ENERGY_MODEL`/`THERMAL_GOV_POWER_ALLOCATOR`/`MEMORY_FAILURE`/`MMC_MTK`/`RMNET`/`SERIAL_8250_EXTENDED`
- **两边共同基线**：`PREEMPT=y HZ=250 ARM64_4K_PAGES MODULES=y IKCONFIG(_PROC) SMP EXT4(+jbd2/mbcache) MMC/dw_mmc-rockchip/sdhci STMMAC/dwmac-rk PHY_ROCKCHIP_EMMC XHCI/DWC3 CMA CGROUPS/MEMCG/BPF/SECCOMP THERMAL_ROCKCHIP CPUFREQ_DT`
  → B 能在无 initrd 下挂根，正是因为 ext4/jbd2/mmc_block/dw_mmc-rockchip/stmmac/dwmac-rk 全内建
- 日志缓冲：`LOG_BUF_SHIFT` A=18(256 KiB) / B=17(128 KiB)

---

## 3. 设备树（同一板子，两份不同 DTS 来源）

| | A `rk3399-emb-3531.dtb` 82,572 B | B `rk3399-emb3531.dtb` 59,782 B |
|---|---|---|
| sha256 | `501d2840050cab38…822a59d6` | `276c0c53fdc5f41b…a6765c03` |
| model | `NORCO EMB-3531` | `Rockchip EMB3531` |
| compatible | `norco,emb-3531`,`rockchip,rk3399` | `rockchip,emb3531`,`rockchip,rk3399` |
| 节点/aliases | 514 / 30 | 486 / 27 |
| `__symbols__` | **有**（可挂 `.dtbo`，配 `/boot/dtb/rockchip/overlay`） | **无 → overlay 机制不可用** |
| `chosen stdout-path` | `serial2:1500000n8` | `serial2:115200n8` |
| `/memory` | 无（依赖 u-boot fixup） | 同 |

### 3.1 关键：`/aliases` 里 mmc 编号相反（互换的致命点）

| alias | A | B |
|---|---|---|
| `mmc0` | **`/mmc@fe330000`（eMMC）** | — |
| `mmc1` | `/mmc@fe320000`（SD） | `/mmc@fe320000`（SD） |
| `mmc2` | — | **`/mmc@fe330000`（eMMC）** |
| `ethernet0` | `/ethernet@fe300000` | — |
| `rtc0`/`rtc1` | 外置 `rtc@51` / `pmic@1b` | — |

→ A 的 dtb 下 eMMC = `mmcblk0`；B 的 dtb 下 eMMC = `mmcblk2`（因此 B 的 `root=/dev/mmcblk2p4` 才成立）。
→ **B 的 rootfs + A 的 dtb：`/dev/mmcblk2p4` 不存在 → VFS 挂根失败 panic**；反之 A 的 rootfs 用 `root=UUID=` → 与 dtb 的 mmc 编号无关，天然可移植。

### 3.2 外设差异

| 节点 | A | B |
|---|---|---|
| `pcie@f8000000` | `status=okay`, `num-lanes=4`, `max-link-speed=2`(Gen2), `ep-gpios` | **`status=disabled`**, `num-lanes=1`, `max-link-speed=1`(Gen1), 另有 `vpcie12v-supply`/`vpcie0v9-supply`/`pinctrl default` |
| `gpu@ff9a0000` | okay | disabled |
| `vop@ff900000` / `hdmi@ff940000` | okay（hdmi 还带 `ddc-i2c-bus`+pinctrl） | 均 disabled |
| `dp@ff970000` | disabled | disabled |
| `video-codec@ff650000`/`ff660000`、`rga@ff680000` | okay（默认） | disabled |
| `iep@ff670000` | 存在 | **节点不存在** |
| `hdmi-sound` / `spdif@ff870000` / `i2s@ff880000` | okay | disabled |
| 音频 codec `i2c@ff110000/audio-codec@10`、`analog-sound`、`dp-sound`、`speaker-amplifier`、`headphone-ctrl` | 有 | 无 |
| 外置 RTC `i2c@ff3d0000/rtc@51` | 有 | 无 |
| gmac `ethernet@fe300000` | `phy-handle` → `mdio/ethernet-phy@0`（`reset-gpios`+`realtek,led-data=0x820b`，Realtek RTL8211 系）、`tx_delay=0x20`(32) `rx_delay=0x23`(35) | **无 mdio/phy-handle**，改 `snps,reset-gpio`+`snps,reset-active-low`+`snps,reset-delays-us=<0 10000 50000>`、`tx_delay=0x26`(38) `rx_delay=0x20`(32) |
| eMMC `mmc@fe330000` | `non-removable`、`mmc-hs400-1_8v`、`mmc-hs400-enhanced-strobe`、`max-frequency=150000000`、`assigned-clock-rates=200000000` | 同上但**无 `max-frequency`**，**多 `keep-power-in-suspend`** |
| SD `mmc@fe320000` | `cd-gpios`、`vmmc-supply`、`vqmmc-supply`、`cap-sd-highspeed`+`cap-mmc-highspeed`、`sd-uhs-sdr104` | **无 `cd-gpios`、无 `vmmc-supply`、无 `sd-uhs-sdr104`、无 `cap-mmc-highspeed`**，仅 `cap-sd-highspeed`+`vqmmc-supply` |
| PMIC | `rockchip,rk808` @ `i2c@ff3c0000/pmic@1b`(0x1b) | 同 |
| PMIC 输出 | DCDC1 `vdd_center`, DCDC2 `vdd_cpu_l`, DCDC4 `vcc_1v8`; LDO1 `vcc2v8_dvp`(2.8 V), LDO2 `vcca1v8_cam`, LDO3 `vcca1v8`, LDO4 `vcc_sd`(1.8–3.0 V), LDO5 `vcc3v0_sd`, LDO6 `vcc_1v5`, LDO7 `vcca1v8_codec`, LDO8 `vcc_3v0` | DCDC1/2/4 同; LDO1 `vcc1v8_dvp`(1.8 V), LDO2 `vcc3v0_tp`, LDO3 `vcc1v8_pmu`, LDO4 `vcc_sd`(**1.8–3.3 V**), LDO5 `vcca3v0_codec`, LDO6/7/8 同 |
| CPU OPP（`opp-table-0`） | 408M/825 mV … 1416M/1125 mV, 上限 1250 mV | **逐档完全相同** |
| 固定调节器命名 | `regulator-vcc-sys/vcc3v3-sys/vdd-log/vcc-phy/backlight-12v/otg-vbus/perst/usb3-hub-en/wifi-en` | `vcc-sys/vcc3v3-sys/vdd-log/vcc-phy-regulator/dc-12v/vcc12v-pcie/vcca-0v9/vcc1v8-s3/regulator-vcc5v0-host`（**无 perst / usb3-hub-en / wifi-en / 背光使能**） |
| PMIC vsel 引脚 | `/pinctrl/pmic/vsel1-pin`(gpio1 pin 0x12) `vsel2-pin`(0x0e) | 同引脚，改名 `vsel1-gpio`/`vsel2-gpio` |
| `vdd_log`/`vcc_sys`/`vcc3v3_sys` 电压 | 三者数值两边一致 | 同 |

> 仅 A 有 39 个节点、仅 B 有 11 个节点（多为调节器/pinctrl 命名差异 + B 的 `vcc12v-pcie`、`vcca-0v9`、`vcc1v8-s3`、`dc-12v`）。

---

## 4. 两个悬置问题（按现有证据的结论，未再做实验）

### 4.1 「只改 B 的设备树一处，把禁用的 PCIe 启用」
**结论：改 dtb 一处不够，光靠 dtb 无法启用 PCIe。**
- 需要改的确实主要是 `pcie@f8000000` 的 `status="disabled"` → `"okay"`（B 的 dtb 里 PCIe 的 `vpcie12v-supply`/`vpcie0v9-supply`/`pinctrl` 都还在，供电描述齐全，这一点比多数裁剪过的 vendor dts 好）。
- 但 **B 的内核 `6.18.24+` 里根本没有 PCIe 栈**：`CONFIG_PCI`、`CONFIG_PCIEPORTBUS`、`CONFIG_NVME_CORE`、`CONFIG_PHY_ROCKCHIP_PCIE` 在解出的 config 中全部不存在（连 `=n` 的痕迹都没有），因此没有 `pcie-dw-rockchip` 主机驱动、没有 portservice、没有 NVMe。dtb 改完 status 也只是多了几个不会有人 bind 的节点。
- 另外 B 的 dtb PCIe 节点是 `num-lanes=1`、`max-link-speed=1`（Gen1 x1），A 是 `num-lanes=4`、`max-link-speed=2`（Gen2 x4）；即使驱动就绪，链路能力也和 A 不同。
- 未验证项（若继续做需要查）：B dtb 里 `pcie-phy`/`combphy`、`&pcie_phy status` 之类第二处 disable、以及 `perst` 使能（B 无 `regulator-perst`，复位脚靠什么拉需要看硬件手册/u-boot）。
- 若目标只是「能跑 NVMe」，现成路径是用 **A 内核**（`PCI=y`/`NVME_CORE=y`/`PHY_ROCKCHIP_PCIE=y` + `drm/rockchip` 等模块齐）而不是改 B。

### 4.2 「镜像 A 能否直接用于刷写 system」
**结论：不能按 Android 的 `system` 分区来刷；A 是「整盘镜像」，只能整盘写入。**
- A 是 **整块设备镜像**（MBR + 前 16 MiB 裸引导区 + 单个 ext4 根分区，`root=UUID=…`），里面**没有** `system/vendor/boot/uboot` 这类 Android 分区，也没有 `parameter.txt`/GPT 分区名；把它当 `system.img` 用 `rkdeveloptool wl <lba>` 灌进某个分区，引导链（idbloader/uboot 在 32 KiB 与 8 MiB 固定扇区）和分区表都对不上。
- 与 B 的布局互不兼容：B 期望 GPT p1..p4 + `root=/dev/mmcblk2p4` + `/boot` 在 p3；A 的 MBR 只有 1 分区，`fdisk`/烧写工具看不到 boot 分区，且 Armbian 的 rootfs 内不含 p3 的那份 `/Image`+`/dtb`。
- 容量硬约束：A 根分区 1.8 GiB（已用 1499 MiB）≫ B 的 p4 351.4 MiB（仅剩 38 MiB）→ 无法把 A 的 rootfs 塞进 B 的 p4；A 的 `/lib/firmware` 就 523 MB、模块 239 MB。
- 可行的两种正确用法：
  1. **整盘刷 A**：`dd if=<A> of=/dev/mmcblkN bs=4M conv=fsync`（或 Rockchip 侧 `rkdeveloptool wl 0 <A>`），之后走 MBR+单分区的 Armbian 引导流；
  2. 想保留 B 的 GPT 四分区框架时，需要重建分区表/引导区（不是「刷一个 system」能解决的）。

---

## 5. 运维/风险评估（已确认）

1. **B 的 `root=/dev/mmcblk2p4` 写死分区号**：任何改动 GPT（增删分区、换 eMMC 容量重分）都会导致挂根失败；改成 `root=UUID=cdbafa53-d8c5-4392-82c7-2e0560153938` 更稳。
2. **B 的 p3 在 GPT 里类型是 EFI System GUID**：插到 Windows 会被识别为 ESP 并可能提示格式化 → 极易误毁引导分区。建议 Windows 侧不要挂载，或把类型 GUID 改回 `0FC63DAF-…`。
3. **B 的 rootfs 只剩 38.1 MiB，且 ext4 block=1 KiB**（A 是 4 KiB）：空间与性能双重受限，`apt` 稍装即满；块大小 1 KiB 使大文件读写明显变慢。
4. **B 无 `/lib/firmware`、无 initrd、无内核包**：升级内核只能手工重刷 p2/p3/p4，没有 `apt` 回滚路径。
5. **两份内核模块不可互换**（vermagic `6.18.63-current-rockchip64` vs `6.18.24+`），B 的 dtb 无 `__symbols__`，Armbian 的 overlay 流程在 B 的 dtb 上无法工作。
6. **B 上换 A 的 dtb**：因 `mmc0/mmc2` alias 交换会挂不上根（见 3.1）；**A 上换 B 的 dtb**：可挂根（root=UUID），但会失去 PCIe/NVMe、显示/GPU/音频、WiFi/BT 使能、外置 RTC、USB3 hub/perst 电源、SD 卡检测与 UHS-104，且 overlay 失效。

---

## 6. 命令备忘（WSL2 挂载/取证）

可用条件：内核含 `ext4`/`vfat`，`/dev/loop-control` + `loop0..7`（`max_loop=8`）。`.img` 用 `losetup/mount -o loop`，**不要**用 `wsl --mount`（那只能挂物理盘/VHDX）。

| 对象 | offset（bytes） | sizelimit |
|---|---|---|
| A img1 rootfs (LBA 32768) | 16777216 | 1891631104 |
| B p1 idbloader (LBA 64) | 32768 | 8355840 |
| B p2 uboot (LBA 16384) | 8388608 | 627712 |
| B p3 boot (LBA 17610) | 9016320 | **20971520（必须给）** |
| B p4 rootfs (LBA 58570) | 29987840 | 368454144 |

```bash
# 已验证可用（只读、禁止 journal 回放，避免改动 .img）
sudo mount -o loop,ro,noload,noatime,offset=16777216 -t ext4 "$A" /mnt/a1
sudo mount -o loop,ro,noload,noatime,offset=29987840 -t ext4 "$B" /mnt/b4
# 之前失败的原因：不给 sizelimit → loop 区间覆盖到文件尾 → 与 loop1 重叠 → "overlapping loop device exists"
sudo mount -o loop,ro,noload,offset=9016320,sizelimit=20971520 -t ext4 "$B" /mnt/b3

# 免 root / 免挂载也能读分区内容（本次用它取到 B 的 /Image 与 dtb）
dd if="$B" bs=512 skip=17610 count=40960 of=B3-boot.ext4      # 20 MiB
debugfs -R 'ls -l /' B3-boot.ext4 ; debugfs -R 'cat /extlinux/extlinux.conf' B3-boot.ext4
debugfs -R 'dump /Image B-Image' B3-boot.ext4
scripts/extract-ikconfig B-Image > B-config                    # 或按 IKCFG_ST/ED 手工 gzip 解
```

---

## 7. 本次产物

| 位置 | 内容 |
|---|---|
| `/mnt/d/shared/dtb-compare/rk3399-emb-3531.dtb` | A 的 dtb 副本，82,572 B，sha256 `501d2840…822a59d6`，`cmp` 与镜像内一致 |
| `/mnt/d/shared/dtb-compare/rk3399-emb3531.dtb` | B 的 dtb 副本，59,782 B，sha256 `276c0c53…a6765c03`，`cmp` 与分区内一致 |
| `/tmp/imgcmp/`（约 78 MB） | `B3-boot.ext4`、`B-Image`、`A-Image`、`B-config`(解出的 B config)、`A.dtb`/`B.dtb`、两个 `*.itb` |
| 挂载状态 | `/mnt/a1`（A rootfs）、`/mnt/b4`（B rootfs）仍在挂；`/mnt/b3` 未挂 |

清理：`sudo umount /mnt/a1 /mnt/b4 && losetup -a`（必要时 `sudo losetup -d /dev/loopN`）；`rm -rf /tmp/imgcmp`。

## 8. 未完成的待办（如需继续）
- B dtb 中 PCIe 相关第二处 `status`（`pcie-phy`/`combphy`/`ep-gpios`）与 perst 复位脚来源确认
- dpkg 包清单与 `/etc` 配置差集（B 到底启用了哪些服务）
- 两边 u-boot / ATF 版本号与配置差（引导链细节，本次只看了 FIT 结构）
