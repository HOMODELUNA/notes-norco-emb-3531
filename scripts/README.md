# 脚本与工具

本目录存放工具性脚本，与「最新版镜像构建」「内核交叉编译」无关的条目都在这里。

根目录只保留 3 项与构建直接相关的内容：`make-image-v3.sh`、`host-build-kernel.sh`、`extlinux-v3.conf`。

## 在用脚本

| 文件 | 类型 | 用途 | 运行位置 |
| --- | --- | --- | --- |
| `dtbedit.py` | 工具 | 读写 DTB，可改变属性值长度，不依赖 `dtc` | 主机 |
| `ext4read.py` | 工具 | 只读访问镜像内 ext4，无需 root，无需 mount | 主机 |
| `imgfile.py` | 工具 | 在镜像内部原地改写文件 | 主机 |
| `set-default-label.py` | 工具 | 无 sudo 修改 extlinux 默认项 | 主机 |
| `set-baud.sh` | 工具 | 修改镜像内的调试串口波特率 | 主机 |
| `cleanup-intermediate.sh` | 维护 | 清理中间产物，默认只列出 | 主机 |
| `wifi-power.sh` | 运行期 | 拉高 GPIO4_D4 给无线网卡上电 | 板上 |
| `emb-firstboot.sh` | 运行期 | 首次开机补齐运行期依赖 | 板上 |
| `pcie-test3.sh` | 测试 | 由 `ep-gpios` 交给驱动管理，探测 PCIe | 板上 |

`wifi-power.sh` 与 `emb-firstboot.sh` 会被 `make-image-v3.sh` 复制进镜像，路径为 `scripts/`。

## 历史脚本

`old/` 目录存放最新版构建不再使用的脚本。保留原因是记录早期路线。

| 文件 | 阶段 | 停用原因 |
| --- | --- | --- |
| `build-gpt-image.sh` | 第一阶段 | 装 A 内核的路线已放弃 |
| `build-image-bloader.sh` | 第一阶段 | 同上 |
| `build-image-minimal.sh` | 第二阶段 | 产物 `emb3531-b-with-a-kernel.img` 已被 `emb3531-v3.img` 取代 |
| `board-build-kernel.sh` | 第二阶段 | 改为主机交叉编译 |
| `board-install-v2.sh` | 第二阶段 | 部署改由 `make-image-v3.sh` 完成 |
| `board-kexec-test.sh` | 第二阶段 | 本板 kexec 交接不可用 |
| `install-labels.sh` | 第二阶段 | 启动标签已写入镜像 |
| `add-wifi-fw.sh` | 第二阶段 | 固件已含在 v3 镜像内 |
| `set-image-settings.sh` | 第一阶段 | 目标是已放弃的 `emb3531-gpt-armbian.img` |
| `patch-static-ip.py` | 第一阶段 | 目标镜像已删除 |
| `pcie-test.sh` | 第三阶段 | 由 `pcie-test3.sh` 取代 |
| `pcie-test2.sh` | 第三阶段 | 同上 |
| `gpio-set.py` | 第三阶段 | 改用 `gpiod` 的 `gpioset` |

## 调用示例

```bash
python3 scripts/dtbedit.py 输入.dtb 输出.dtb dump /pcie@f8000000
python3 scripts/ext4read.py 镜像.img /etc/hostname
scripts/cleanup-intermediate.sh
scripts/cleanup-intermediate.sh --yes
```

## 警告

警告：`old/build-gpt-image.sh` 等 3 个构建脚本默认在原目录写入镜像。在仓库根目录运行会在根目录产生 1.8 GiB 文件。

警告：`old/set-image-settings.sh` 与 `old/patch-static-ip.py` 的默认目标镜像已删除。运行前必须用参数指定镜像。

警告：`cleanup-intermediate.sh` 会按仓库根目录计算路径。在其他目录调用同样生效，不要误加 `--yes`。