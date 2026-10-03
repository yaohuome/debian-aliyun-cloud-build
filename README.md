# Debian for Alibaba Cloud (ECS)

面向阿里云 ECS 的 **Debian 自定义镜像**构建项目。与姊妹项目 [alpine-cloud-build](https://github.com/haoduck/alpine-cloud-build)
思路一致（产出可直接导入的 `qcow2`），但实现方式不同：Alpine 版是「下载官方镜像再改」，
本项目是 **debootstrap 从零构建**——因为要同时满足「体积尽量小」「能跑在 1GB 系统盘」
「覆盖 Debian 10/11/12/13」，官方镜像改不动（虚拟盘 2~3GiB、ESP 固定占 512MiB）。

## 特性

| 项目 | 说明 |
|---|---|
| 支持版本 | Debian **10 (buster) / 11 (bullseye) / 12 (bookworm) / 13 (trixie)**，可一次全出 |
| 镜像体积 | 实测 Debian 13：`both`+cloud-init **154 MiB**，`bios`+无 cloud-init **124 MiB**（官方 genericcloud 是 326 MB） |
| 磁盘占用 | 虚拟盘默认 **1 GiB**。1 GiB 整机上实测根分区可用：**583 MiB**（both+cloud-init）→ **726 MiB**（bios+无 cloud-init） |
| 引导方式 | 默认 **BIOS + UEFI 双引导**；`boot_mode=bios` 时**不建 ESP**，在 1GiB 整机上多出 64 MiB 可用空间 |
| 初始化 | 默认内置 cloud-init（阿里云 datasource 自动识别）；`cloud_init=no` 省约 60 MB，代价是实例创建时绑定密钥对不再生效 |
| 软件源 | 全部切换为阿里云镜像源（含 EOL 版本的 archive 源） |
| 时区 | `Asia/Shanghai`，chrony 使用 `ntp.aliyun.com` |

## 使用说明（阿里云）

1. 从 Releases 下载镜像，文件名形如 `debian-custom-<版本>-<引导标签>.qcow2`，
   例如 `debian-custom-13.7-bios-uefi.qcow2`
2. 在阿里云导入自定义镜像（镜像格式选 **QCOW2**）：
   - 默认产出的镜像 **BIOS 和 UEFI 都能启动**，「启动模式」选哪个都行
   - 如果构建时选了单一模式（`boot_mode=bios` / `uefi`），导入时「启动模式」必须与之一致
3. 创建 ECS 实例：
   - 可绑定 SSH 密钥对（镜像内已内置公钥，非必需；cloud-init 会把绑定的公钥追加进去）
   - **系统盘建议 ≥ 20 GiB**：阿里云控制台一般选不到 1 GiB 的系统盘。镜像虚拟盘是 1 GiB，
     实例系统盘更大完全没问题——cloud-init 首启会自动 `growpart` + `resize2fs` 扩到整盘
   - 登录用户：`debian`（可 sudo 免密）或 `root`
4. 首次登录：

   ```bash
   ssh -i <你的私钥> debian@<ECS公网IP>
   sudo -i
   # 或直接用 root
   ssh -i <你的私钥> root@<ECS公网IP>
   ```

## 构建镜像（GitHub Actions）

镜像由 `.github/workflows/build-debian-image.yml` 构建，触发方式二选一：

- 推送 `v*` 形式的 tag：
  ```bash
  git tag v1.0.0 && git push origin v1.0.0
  ```
- 在仓库 Actions 页面选择 `Build Debian Cloud Image` → **Run workflow** 手动触发：

| 输入项 | 说明 |
|---|---|
| `debian_release` | `all`（默认，10/11/12/13 全出）/ `trixie` / `bookworm` / `bullseye` / `buster` |
| `boot_mode` | `both`（默认，BIOS+UEFI）/ `bios` / `uefi` |
| `ssh_pubkey` | 注入镜像的 SSH 公钥（`root` 与 `debian` 用户都写入）。填 `none` 则不注入 |
| `password` | 同时为 `root` 与 `debian` 设置的登录密码，留空则不设密码 |
| `disk_size` | 镜像虚拟磁盘大小，默认 `1G`。**不能大于实例的系统盘**，否则导入会失败 |
| `cloud_init` | `yes`（默认）/ `no`。`no` 省约 60 MB，但绑定密钥对不再生效，密钥必须在构建时烤进镜像 |
| `release_tag` | 要发布的 release tag，留空则用 `manual-<run number>` |

构建完成后：

- Release tag 带引导方式后缀：`<tag>-bios-uefi` / `<tag>-bios` / `<tag>-uefi`
- 镜像文件名带具体版本号与引导标签：`debian-custom-13.7-bios-uefi.qcow2`
  （版本号取自镜像内的 `/etc/debian_version`）
- 同时作为 workflow artifact 保留 14 天


## 本地构建

需要 Linux（root 权限 + loop 设备）以及 `debootstrap`、`qemu-utils`、`gdisk`、
`dosfstools`、`e2fsprogs`、`parted`、`xz-utils`：

```bash
sudo apt-get install -y debootstrap debian-archive-keyring gdisk parted \
  dosfstools e2fsprogs util-linux qemu-utils xz-utils curl

# 不注入公钥/密码时，先创建两个空文件（脚本按文件读取，避免密码出现在命令行里）
: > /tmp/build-ssh-pubkey
: > /tmp/build-password

sudo env DEBIAN_RELEASE=trixie BOOT_MODE=both DISK_SIZE=1G bash scripts/build-image.sh
# 产物：dist/debian-custom-<版本>-<引导标签>.qcow2
```

可用的环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DEBIAN_RELEASE` | 必填 | `trixie` / `bookworm` / `bullseye` / `buster` |
| `BOOT_MODE` | `both` | `both` / `bios` / `uefi` |
| `DISK_SIZE` | `1G` | 镜像虚拟磁盘大小 |
| `ESP_SIZE` | `64M` | EFI 系统分区大小；**只在 `boot_mode` 含 uefi 时才创建**（官方镜像是 512M） |
| `CLOUD_INIT` | `1` | 置 `0` 不装 cloud-init（省约 60 MB，但实例创建时绑定密钥对不再生效） |
| `INITRAMFS_MODULES` | `most` | 改成 `dep` 能再省十几 MB，但个别虚拟化平台可能起不来 |
| `NODOC` | `1` | 删除文档/手册/locale/i18n，只保留各包 `copyright` |
| `DEFAULT_USER` | `debian` | 默认普通用户 |
| `TIMEZONE` | `Asia/Shanghai` | 时区 |
| `SSH_PUBKEY_FILE` | `/tmp/build-ssh-pubkey` | 要注入的公钥文件（空文件 = 不注入） |
| `SSH_PASSWORD_FILE` | `/tmp/build-password` | 要设置的密码文件（空文件 = 不设密码） |
| `WORK_DIR` / `OUTPUT_DIR` | `./work` / `./dist` | 工作目录 / 产物目录 |

## 目录结构

```
.github/workflows/build-debian-image.yml   # 流水线：矩阵构建多个版本 + 发布 Release
scripts/lib.sh                             # 版本/软件源映射表、日志、断言、fstrim 回收
scripts/build-image.sh                     # 建盘 → 分区 → debootstrap → chroot 配置 → 回收 → 压缩
scripts/guest-setup.sh                     # 在 chroot 内执行：装包 + 系统配置 + 引导程序
scripts/guest-grub.sh                      # 在 chroot 内执行：用真实 UUID 生成 grub.cfg
scripts/guest-finalize.sh                  # 在 chroot 内执行：启用服务 + 清理裁剪
scripts/finalize-image.sh                  # 镜像级断言 + 转 qcow2 压缩
```

## 镜像已做的定制

- 使用 `debootstrap --variant=minbase` 从零安装，只装必需组件
- 分区布局：GPT + `bios_grub`(1 MiB) +［ESP，仅 UEFI 需要，默认 64 MiB］+ root（剩余全部）。
  `boot_mode=bios` 时**不创建 ESP**，那 64 MiB 直接归根分区
- 预装：`systemd`、`openssh-server`、`chrony`、`ifupdown` + `isc-dhcp-client`、`sudo`、
  `ca-certificates`、`tzdata`；`cloud_init=yes` 时另装 `cloud-init`、`cloud-guest-utils`、
  `gdisk`/`fdisk`（growpart 需要）、`dmidecode`（云平台识别需要）
- 内核使用体积更小的 `linux-image-cloud-amd64`（缺失时自动回退 `linux-image-amd64`）
- 默认软件源切换为阿里云（EOL 版本自动使用 `debian-archive` 并关闭 `Valid-Until` 校验）
- **镜像内最终的 apt 源指向阿里云内网源 `mirrors.cloud.aliyuncs.com`**（在 ECS 上走 VPC，
  更快且不计流量）。构建期仍用公网源 `mirrors.aliyun.com`——构建机不在 VPC 里，内网源连不通
- 镜像 `/root/switch-apt-mirror.sh`：一键切源（默认切到公网 `mirrors.aliyun.com`，
  加 `internal` 参数切回内网源），不在阿里云上运行时先执行它
- cloud-init 已启用，**不改动 `datasource_list`**，沿用内置默认表：
  阿里云 ECS 通过 DMI `product_name = Alibaba Cloud ECS` 被自动识别为 `AliYun`，
  首启自动注入密钥/主机名并 `growpart` + 扩容根分区
- SSH：允许 root 登录与密码登录、禁止空密码、`UseDNS no`
- 网卡固定为 `eth0`（内核参数 `net.ifnames=0`），网络由 ifupdown 走 DHCP
- 控制台可用：内核参数带 `console=tty0 console=ttyS0,115200n8`（阿里云 VNC/串口能看到启动日志）
- **grub.cfg 用真实根分区 UUID 直接生成**，而不是在 chroot 里跑 `update-grub`
  （原因见下方常见问题），BIOS 与 UEFI 共用同一份 `grub.cfg`
- 首启重新生成 SSH host key（`ssh-host-keys.service`），避免所有实例共用同一份密钥
- 清空 `/etc/machine-id` 与 `/var/lib/cloud/*`，确保 cloud-init 在首启重新初始化
- 卸载前先 `sync` 再 `fstrim`（并做两轮）回收已删除的块：删除文件后脏页还在回写，
  不等它落盘就 trim，回写会重新占用刚释放的块，镜像会大一倍以上（349MB vs 700MB）

## 镜像未包含内容

- 阿里云官方 Agent（云助手等）
- 额外业务软件栈（Docker / K8s / 监控等）
- `systemd-resolved` / `systemd-networkd`（网络交给 ifupdown，避免与 cloud-init 抢配置）

如有需要，请在实例初始化后自行安装。

---

## 常见问题

### 实例启动卡在 `Booting from Hard Disk...`

引导方式不匹配。这句提示是传统 BIOS（SeaBIOS）输出的，说明实例按 Legacy BIOS 启动，
但磁盘上没有 BIOS 引导程序。

默认的 `boot_mode=both` 镜像两种模式都支持，不会出现这个问题。看到这个提示说明用的是
单一模式的镜像、且导入时「启动模式」选错了——阿里云 `ImportImage` 的 `BootMode` 参数
**默认是 `BIOS`**，所以导入 `boot_mode=uefi` 的镜像时如果不手动改成 UEFI 就会被卡住。

解决办法：

- 用默认的 `both` 重新构建，导入时选哪个模式都能启动
- 或者重新导入，把「启动模式」改成与镜像一致（选 UEFI 需要实例规格族支持 UEFI 启动）

### 登录不上，提示没有可用的密钥

镜像内是否内置公钥取决于构建时的 `ssh_pubkey` 输入：

- 填了公钥 → `root` 与 `debian` 都可用对应私钥登录
- 填了 `none` → 镜像内不含任何公钥，必须在创建实例时绑定密钥对
  （cloud-init 会把它追加进 `authorized_keys`），或用控制台 VNC 登录
- 镜像默认不预设密码，只有在构建时填了 `password` 才有密码
- **`cloud_init=no` 的镜像**：绑定密钥对不会生效，只能靠镜像内烤好的公钥或密码登录

### 系统盘没有自动扩容

**只有系统盘大于镜像虚拟盘时才有东西可扩**（1 GiB 系统盘 + 1 GiB 镜像时不会发生扩容）。
cloud-init 首启会执行 `growpart` + `resize_rootfs`；若没生效，登录后手动执行：

```bash
# boot_mode=both / uefi：根分区是 p3
sudo growpart /dev/vda 3 && sudo resize2fs /dev/vda3
# boot_mode=bios（没有 ESP）：根分区是 p2
sudo growpart /dev/vda 2 && sudo resize2fs /dev/vda2
```

（分区布局：p1 固定是 `bios_grub`；含 UEFI 时 p2 是 ESP、p3 是 root；纯 BIOS 时 p2 就是 root。）

### 想进一步压缩镜像体积

- `INITRAMFS_MODULES=dep`：initramfs 只带必要驱动，能再省十几 MB
- `ESP_SIZE=32M`：ESP 用不到 64M（引导文件只有几 MB）
- 不需要 UEFI 时用 `boot_mode=bios`，可以省掉整个 ESP
- 手动移除 `dbus`、`nano`、`less` 等非必需包（需自行改 `guest-setup.sh` 的包列表）

### Debian 10 / 11 已停止支持

- **Debian 10 (buster)**：2024-06-30 结束 LTS，**无任何安全更新**
- **Debian 11 (bullseye)**：2026-08-31 结束 LTS，**无任何安全更新**

这两个版本只能用于兼容性测试或隔离环境，不建议对外提供服务。它们的软件源配置：

| 版本 | 主源 | 安全源 |
|---|---|---|
| buster | 阿里云 `debian-archive/debian`（含 `buster-updates`） | 阿里云 `debian-archive/debian-security` 的 `buster/updates` |
| bullseye | 阿里云 `debian`（失败自动退到 `debian-archive/debian`） | **无**（见下） |

> **bullseye 为什么没有安全源**：EOL 后它的安全套件已彻底不可用——`security.debian.org` 已移除、
> `archive.debian.org` 与阿里云 `debian-archive` 都没有 bullseye 安全归档，而阿里云
> `debian-security` 只剩 Packages 索引、索引里引用的 `.deb` 文件全部 404（实测 90 个包下载失败，
> 会让整个构建失败）。所以 bullseye 只用主源、不带安全源，两个候选主源都已实测可完整安装依赖。
>
> EOL 版本同样不需要 `Acquire::Check-Valid-Until` 之外的额外处理，脚本会自动关闭该校验。

### apt 装不了包 / 提示连不上软件源（不在阿里云上运行）

镜像出厂把 apt 源指向了阿里云**内网源** `mirrors.cloud.aliyuncs.com`，它**只有在阿里云 ECS 上
才能连通**。在本地 QEMU 或其它云上运行时，先切回公网源：

```bash
sudo /root/switch-apt-mirror.sh            # 切到公网 mirrors.aliyun.com
sudo /root/switch-apt-mirror.sh internal   # 再切回内网源
```

脚本会先把原文件备份成 `*.bak` 再改写，最后自动跑一次 `apt-get update` 验证连通性；
若更新失败会明确提示用哪个参数切回去。

### 整机只有 1 GiB 空间，怎么留出最多可用空间？

阿里云要求**系统盘容量 ≥ 镜像虚拟大小**，所以 1 GiB 的实例系统盘只装得下虚拟盘 ≤ 1 GiB 的镜像：
`disk_size` **不能调大**（比如 2G），否则导入直接失败。1 GiB 整机的空间账本：

| 项目 | 大小 | 说明 |
|---|---|---|
| GPT + `bios_grub` | ~2 MiB | 必须 |
| ESP | 64 MiB | **`boot_mode=bios` 时不创建，直接省下** |
| root 文件系统 | 剩余全部 | 已用约 327 MiB |

按需组合（实测根分区可用空间）：

| 配置 | 可用空间 |
|---|---|
| `boot_mode=both` + `cloud_init=yes`（默认） | **583 MiB**（实测） |
| `boot_mode=bios` + `cloud_init=yes` | **约 661 MiB**（省下 ESP 的 64 MiB） |
| `boot_mode=bios` + `cloud_init=no` | **726 MiB**（实测） |

> ⚠️ 用 `cloud_init=no` 时，实例创建时**绑定密钥对不会生效**（没有 cloud-init 去拉取公钥），
> 必须用构建时的 `ssh_pubkey` 把公钥烤进镜像、或用 `password` 设密码，否则登不进去。
> 另外 1 GiB 盘本来也没有多余空间，cloud-init 的自动扩容在这里本来就不会做任何事。

### 老版本镜像构建失败或起不来（`unknown filesystem` / `requires a manual fsck`）

新版 `mke2fs`（e2fsprogs ≥ 1.47，例如 Ubuntu 24.04/26.04）默认会启用两个 ext4 特性，
而 **Debian 10/11 自带的工具认不出来**：

| 特性 | 症状 |
|---|---|
| `metadata_csum_seed` | grub 2.06 读不了该文件系统 → 构建时 `grub-install: error: unknown filesystem` |
| `orphan_file` | e2fsprogs 1.46/1.44 不认识 → 实例启动时 `fsck exited with status code 12`、`The root filesystem requires a manual fsck`，掉进 `(initramfs)` 救援 shell |

脚本在 `mkfs.ext4` 时用 `-O ^metadata_csum_seed,^orphan_file` 关掉两者，并加了断言防止回归
（根文件系统一旦带这两个特性就直接构建失败）。它们都只是性能优化，关掉没有任何功能损失。

Debian 12/13 的 grub 2.12 / e2fsprogs 认识它们，所以只有 buster / bullseye 会受影响。

### 为什么构建期不用 `update-grub`？

因为构建发生在 chroot 里，此时 `grub-probe` 无法把根分区解析成 UUID，会把**构建机上的
临时设备名**写进 `grub.cfg`，例如 `root=/dev/loop2p3`。镜像导入云平台后设备名变成
`/dev/vda3`，initramfs 找不到根设备，实例会掉进 `(initramfs)` 救援 shell 起不来。

所以构建期由 `scripts/guest-grub.sh` 用真实根分区 UUID 直接生成 `grub.cfg`，并在流水线里
加了断言：`grub.cfg` 必须包含 `root=UUID=`，且不得出现 `/dev/loop*` 之类的构建机设备名。

实例内后续升级内核时，内核包会正常调用 `update-grub`（那时设备解析是正确的），
`grub.cfg` 会被自动重建，无需人工干预。

### cloud-init 没有生效

镜像**不设置 `datasource_list`**，沿用 cloud-init 内置默认表（已包含 `AliYun`）。
阿里云 ECS 会依据 DMI `product_name = Alibaba Cloud ECS` 被自动识别为 `AliYun`。

在实例里检查：

```bash
sudo cloud-init status --long
sudo cat /run/cloud-init/cloud.cfg   # 正常应包含 datasource_list: [ AliYun, None ]
sudo cat /var/log/cloud-init.log
```

若 cloud-init 根本没跑，多半是导入的镜像不是本项目默认产物，或实例没有元数据服务可达
（阿里云内网需能访问 `100.100.100.200`）。

---

## 免责声明

本镜像为社区用途的自定义构建版本，请先在测试环境验证后再用于生产环境。
