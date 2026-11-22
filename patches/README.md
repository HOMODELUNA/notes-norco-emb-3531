# PCIe 内核补丁

这两个补丁记录本次 PCIe 排查中改动的两处内核源码。两个补丁都作用于 `linux-6.18.24`。

| 文件 | 改动对象 | 内容 | 效果 |
| --- | --- | --- | --- |
| `0001-pcie-rockchip-host-retry-and-ltssm-debug.patch` | `drivers/pci/controller/pcie-rockchip-host.c` | 链路训练重试 4 次，超时输出寄存器值 | 无效，但输出有用 |
| `0002-phy-rockchip-pcie-reset-on-probe.patch` | `drivers/phy/rockchip/phy-rockchip-pcie.c` | `probe` 时把 lane 置 idle-off 并复位 PHY | 无效 |

## 来源

| 补丁 | 来源 |
| --- | --- |
| 0001 | Armbian build PR 4308，另加 LTSSM 调试输出 |
| 0002 | Armbian build PR 6057 |

详细背景见 [../1122-pcie.md](../1122-pcie.md)。

## 应用

前置条件：当前目录是内核源码根目录，源码版本为 `linux-6.18.24`。源码包 `linux-6.18.24.tar.xz` 已随源码树删除，需要重新下载。

```bash
patch -p1 < /home/homodeluna/test-img/patches/0001-pcie-rockchip-host-retry-and-ltssm-debug.patch
patch -p1 < /home/homodeluna/test-img/patches/0002-phy-rockchip-pcie-reset-on-probe.patch
```

## 校验

两个补丁在原始 `linux-6.18.24` 源码上应用后，结果与本次使用的源码逐字节相同。

| 文件 | 应用后 md5 | 校验 |
| --- | --- | --- |
| `pcie-rockchip-host.c` | `01167a994ceed0ecefbf1610e43da732` | 相同 |
| `phy-rockchip-pcie.c` | `ec475e765829fdbf16f99e76818d1b44` | 相同 |

## 其余本地改动

内核树另有 3 处改动，已存于 `emb3531-headless-sdk/patches/kernel/`，不重复导出。

| 文件 | 存放位置 |
| --- | --- |
| `rk3399-emb3531.dts` | 完整文件，md5 `39ef18fc4c2ed5fccc437006eb9b1327` |
| `emb3531_headless_defconfig` | 完整文件，md5 `a3f12dfba0b3f4e6e3b639fab535d649` |
| `Makefile` 增加 dtb 条目 | `0001-add-emb3531-dtb-to-makefile.patch` |

所以删除 `kernel/linux-6.18.24` 后，全部改动仍可复原。

## 警告

警告：0001 补丁含中文注释。用 `git am` 应用时，先确认提交编码为 UTF-8。

警告：两个补丁都会重新编译 `pcie-rockchip-host.ko` 与 `phy-rockchip-pcie.ko`。板上现有模块已含这两处改动。