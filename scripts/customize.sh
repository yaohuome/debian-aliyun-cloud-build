#!/usr/bin/env bash
# 构建时的自定义初始化脚本 —— 在镜像的 chroot 内以 root 执行。
#
# 需要往镜像里烘焙内容时，把命令写在这里，构建时会自动执行。
# 简单命令也可以直接用构建输入 customize 传（传了就覆盖本脚本，不会执行这里）。
#
# 适合做：
#   apt-get install -y 某包     写配置文件      建用户      铺业务文件      预下载内容
# 不适合（这里是 chroot，不是真的开机）：
#   systemctl start（没有 systemd 在跑，用 systemctl enable）
#   modprobe / 依赖镜像内核的操作（内核是构建机的）
#   往 /proc、/sys 写东西（那是构建机的）
#
# 执行时机：项目自身配置（用户/sshd/网络/cloud-init/grub）都做完之后，
#           切换内网源与清理裁剪之前 —— 此时 apt 源还是公网，可以正常装包。
set -euo pipefail

echo "[customize] 这是默认的自定义脚本，当前没有做任何额外操作。"
echo "[customize] 要往镜像里烘焙内容：把命令写进 scripts/customize.sh，"
echo "[customize] 或者构建时用 customize 输入直接传命令（适合简单场景）。"
