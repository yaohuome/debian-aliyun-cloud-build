#!/usr/bin/env bash
# 生成 /etc/default/grub 与 /boot/grub/grub.cfg。
#
# 为什么不用 update-grub：
# 构建发生在 chroot 里，此时 grub-probe 无法把根分区解析成 UUID，会把「构建机上的
# 临时设备名」写进 grub.cfg，例如 root=/dev/loop2p3。镜像导入云平台后设备名变成
# /dev/vda3，initramfs 找不到根设备，实例会掉进 (initramfs) 救援 shell 起不来。
# 这里直接用真实根分区 UUID 生成，结果确定、可被断言校验。
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ ! -f /tmp/build-params.sh ]; then
  echo "错误：缺少 /tmp/build-params.sh，本脚本需由 build-image.sh/guest-setup.sh 调用" >&2
  exit 1
fi
# shellcheck source=/dev/null
. /tmp/build-params.sh

KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)"
INITRD="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)"
[ -n "${KERNEL}" ] || { echo "错误：找不到内核镜像" >&2; exit 1; }
[ -n "${INITRD}" ] || { echo "错误：找不到 initramfs" >&2; exit 1; }
[ -n "${ROOT_UUID}" ] || { echo "错误：ROOT_UUID 为空" >&2; exit 1; }

# 这份配置留给实例内的 update-grub 使用（那时设备解析是正常的）
cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="Debian"
GRUB_CMDLINE_LINUX_DEFAULT=""
# console=ttyS0 让阿里云控制台/串口能看到启动过程；net.ifnames=0 固定网卡名为 eth0
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0"
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_LINUX_UUID=false
EOF

mkdir -p /boot/grub
cat > /boot/grub/grub.cfg <<EOF
# 由 debian-cloud-build 生成（构建期不使用 update-grub，原因见 guest-grub.sh 顶部）
set default=0
set timeout=1

menuentry 'Debian GNU/Linux' {
  search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
  linux /${KERNEL#/} root=UUID=${ROOT_UUID} ro console=tty0 console=ttyS0,115200n8 net.ifnames=0
  initrd /${INITRD#/}
}
EOF

echo "[guest] 已生成 grub.cfg（root=UUID=${ROOT_UUID}，内核 ${KERNEL##*/}）"
