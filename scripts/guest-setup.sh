#!/usr/bin/env bash
# 在目标 rootfs 内部（chroot）执行，完成软件安装与系统配置。
# 依赖 host 侧写入的 /tmp/build-params.sh（由 build-image.sh 生成）。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;34m[guest]\033[0m %s\n' "$*"; }

# shellcheck source=/dev/null
. /tmp/build-params.sh

info "开始配置 Debian ${DEB_NUM} (${SUITE})"

# ---------- 1. 阻止服务在 chroot 内被启动 ----------
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# ---------- 2. dpkg：不安装文档（只影响之后安装的包） ----------
if [ "${NODOC}" = "1" ]; then
  mkdir -p /etc/dpkg/dpkg.cfg.d
  cat > /etc/dpkg/dpkg.cfg.d/01-nodoc <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
EOF
fi

# ---------- 3. apt 基础配置 ----------
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-minimal <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

# EOL 版本的 Release 文件 Valid-Until 已过期，apt 默认会拒绝，必须关掉校验
if [ "${EOL}" = "1" ]; then
  cat > /etc/apt/apt.conf.d/99-eol <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
fi

# ---------- 4. 软件源（阿里云，http 免去 ca-certificates 的先有鸡先有蛋问题） ----------
write_sources() {
  local main="$1" sec="$2"
  # sec 为空表示该版本没有可用的安全源（例如 EOL 后的 bullseye）
  if [ "${DEB_NUM}" -ge 13 ]; then
    # Debian 13+ 默认使用 deb822 格式
    rm -f /etc/apt/sources.list
    mkdir -p /etc/apt/sources.list.d
    {
      cat <<EOF
Types: deb
URIs: ${main}
Suites: ${SUITE} ${SUITE}-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      if [ -n "${sec}" ]; then
        cat <<EOF

Types: deb
URIs: ${sec}
Suites: ${SEC_SUITE}
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      fi
    } > /etc/apt/sources.list.d/debian.sources
  else
    rm -f /etc/apt/sources.list.d/debian.sources
    {
      printf 'deb %s %s main\n'         "${main}" "${SUITE}"
      printf 'deb %s %s-updates main\n' "${main}" "${SUITE}"
      if [ -n "${sec}" ]; then
        printf 'deb %s %s main\n' "${sec}" "${SEC_SUITE}"
      fi
    } > /etc/apt/sources.list
  fi
}

# ---------- 5. chroot 内安装阶段需要能解析域名 ----------
cat > /etc/resolv.conf <<'EOF'
nameserver 223.5.5.5
nameserver 100.100.2.136
nameserver 8.8.8.8
EOF

# ---------- 6. 安装软件包（逐个候选源尝试） ----------
# 基础包（两种模式都需要）
PKGS="systemd-sysv dbus kmod e2fsprogs initramfs-tools xz-utils \
openssh-server libpam-systemd ifupdown isc-dhcp-client netbase \
iproute2 iputils-ping chrony tzdata ca-certificates sudo \
debian-archive-keyring less nano"

# cloud-init 及其依赖：growpart 需要 gdisk/fdisk，云平台识别需要 dmidecode
if [ "${CLOUD_INIT}" = "1" ]; then
  PKGS="${PKGS} cloud-init cloud-guest-utils gdisk fdisk dmidecode"
fi

# 只有需要 UEFI 时才装 EFI 引导模块；mtools 是 grub-install 往 ESP 写文件时用的
if [ "${BOOT_MODE}" != "bios" ]; then
  PKGS="${PKGS} mtools"
fi

case "${BOOT_MODE}" in
  bios) GRUB_PKGS="grub-common grub2-common grub-pc-bin" ;;
  uefi) GRUB_PKGS="grub-common grub2-common grub-efi-amd64-bin" ;;
  *)    GRUB_PKGS="grub-common grub2-common grub-pc-bin grub-efi-amd64-bin" ;;
esac

installed=0
WIN_MAIN=""
WIN_SEC=""
for cand in ${CANDIDATES}; do
  main="${cand%%|*}"
  sec="${cand##*|}"
  info "尝试软件源：${main}"
  write_sources "${main}" "${sec}"
  if ! apt-get update; then
    warn "apt-get update 失败，换下一个候选源"
    continue
  fi
  if apt-get install -y --no-install-recommends ${PKGS} ${GRUB_PKGS} linux-image-cloud-amd64; then
    installed=1; WIN_MAIN="${main}"; WIN_SEC="${sec}"
    break
  fi
  warn "cloud 内核安装失败，回退到 linux-image-amd64"
  if apt-get install -y --no-install-recommends ${PKGS} ${GRUB_PKGS} linux-image-amd64; then
    installed=1; WIN_MAIN="${main}"; WIN_SEC="${sec}"
    break
  fi
  warn "当前候选源安装失败，换下一个候选源"
done
[ "${installed}" = "1" ] || { echo "错误：所有候选源都安装失败" >&2; exit 1; }

# ---------- 6b. 镜像内默认软件源：阿里云内网源 ----------
# 构建期必须用公网源（构建机不在阿里云 VPC 里，内网源连不通），所以先按公网源把包装完，
# 再把最终写进镜像的源换成内网源：内网源在 ECS 上走 VPC，速度更快且不计流量。
# 不在阿里云上跑（或内网源不通）时，用 /root/switch-apt-mirror.sh 一键切回公网源。
FINAL_MAIN="${WIN_MAIN//mirrors.aliyun.com/mirrors.cloud.aliyuncs.com}"
FINAL_SEC="${WIN_SEC//mirrors.aliyun.com/mirrors.cloud.aliyuncs.com}"
write_sources "${FINAL_MAIN}" "${FINAL_SEC}"
info "镜像内默认软件源：${FINAL_MAIN}${FINAL_SEC:+  和  ${FINAL_SEC}}"

# ---------- 6c. /root 下的一键切源脚本 ----------
cat > /root/switch-apt-mirror.sh <<'SWITCH_EOF'
#!/bin/bash
# 一键切换 apt 软件源（需要 root）
#
#   sudo /root/switch-apt-mirror.sh            # 切到公网源 mirrors.aliyun.com
#   sudo /root/switch-apt-mirror.sh internal   # 切回内网源 mirrors.cloud.aliyuncs.com
#
# 镜像出厂默认是内网源，它只有在阿里云 ECS 上才能连通；在本地 QEMU 或其它云上运行时，
# 先执行本脚本切到公网源。
set -euo pipefail

INTERNAL_HOST="mirrors.cloud.aliyuncs.com"
PUBLIC_HOST="mirrors.aliyun.com"

TARGET="${1:-public}"
case "${TARGET}" in
  public|公网)   FROM="${INTERNAL_HOST}"; TO="${PUBLIC_HOST}"; BACK="internal" ;;
  internal|内网) FROM="${PUBLIC_HOST}";   TO="${INTERNAL_HOST}"; BACK="public" ;;
  *) echo "用法: $0 [public|internal]（默认 public，即切到 ${PUBLIC_HOST}）" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限，请用 sudo 运行" >&2; exit 1; }

FILES=""
if [ -f /etc/apt/sources.list ]; then FILES="${FILES} /etc/apt/sources.list"; fi
for f in /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  FILES="${FILES} ${f}"
done
[ -n "${FILES}" ] || { echo "找不到 apt 源文件" >&2; exit 1; }

changed=0
for f in ${FILES}; do
  if grep -q "${FROM}" "$f"; then
    cp -f "$f" "${f}.bak"
    sed -i "s|${FROM}|${TO}|g" "$f"
    echo "已更新 ${f}（备份为 ${f}.bak）"
    changed=1
  fi
done

if [ "${changed}" = "0" ]; then
  echo "这些文件里没有 ${FROM}，无需修改：${FILES}"
  exit 0
fi

echo
echo "当前源："
grep -hE '^(deb |URIs:)' ${FILES} | sed 's/^/  /' || true
echo
echo "执行 apt-get update 验证连通性 ..."
# 注意：apt-get update 在「所有源都拉不到」时也可能返回 0（只打 W: 警告），
# 所以必须同时检查退出码和输出里有没有失败信息。
# 限制超时与重试次数，切到不可达的源时快速失败，而不是卡住几分钟。
set +e
OUT="$(apt-get update -o Acquire::http::Timeout=10 -o Acquire::Retries=0 2>&1)"
RC=$?
set -e
printf '%s\n' "${OUT}"

if [ "${RC}" -eq 0 ] && ! printf '%s' "${OUT}" | grep -qE 'Failed to fetch|Unable to fetch|Could not resolve'; then
  echo
  echo "✅ 已切换到 ${TO}，apt 更新成功"
else
  echo
  echo "⚠️  已写入 ${TO}，但 apt-get update 没有成功拉取索引。" >&2
  echo "    如果你不在对应环境里，可以执行：sudo $0 ${BACK}" >&2
  exit 1
fi
SWITCH_EOF
chmod 0755 /root/switch-apt-mirror.sh
info "已放置 /root/switch-apt-mirror.sh（默认切公网源，internal 参数切回内网源）"

# ---------- 7. 时区 / locale ----------
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
printf '%s\n' "${TIMEZONE}" > /etc/timezone
if [ "${DEB_NUM}" -ge 11 ]; then
  # glibc 2.35+ 内置 C.UTF-8；更早的版本只有 C
  printf 'LANG=C.UTF-8\n' > /etc/default/locale
else
  printf 'LANG=C\n' > /etc/default/locale
fi

# ---------- 8. 用户 ----------
if ! id -u "${DEFAULT_USER}" >/dev/null 2>&1; then
  useradd -m -u 1000 -s /bin/bash -G sudo "${DEFAULT_USER}"
fi
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEFAULT_USER}" > "/etc/sudoers.d/90-${DEFAULT_USER}"
chmod 440 "/etc/sudoers.d/90-${DEFAULT_USER}"

# ---------- 9. SSH ----------
SSHD_CONF=/etc/ssh/sshd_config
ensure_sshd_directive() {
  local key="$1" value="$2"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "${SSHD_CONF}"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "${SSHD_CONF}"
  else
    printf '%s %s\n' "${key}" "${value}" >> "${SSHD_CONF}"
  fi
}

if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${SSHD_CONF}"; then
  # Debian 11+：sshd_config.d 里的文件在主配置之前被读取，且 sshd 取「先出现的值」，
  # 因此文件名必须排在 cloud-init 的 50-*.conf 之前，才能保证我们的策略生效。
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-cloud-build.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
UseDNS no
X11Forwarding no
EOF
else
  # Debian 10：openssh 7.9 不支持 Include sshd_config.d，直接改主配置
  ensure_sshd_directive PermitRootLogin yes
  ensure_sshd_directive PasswordAuthentication yes
  ensure_sshd_directive PermitEmptyPasswords no
  ensure_sshd_directive UseDNS no
  ensure_sshd_directive X11Forwarding no
fi

# 注入公钥（root 与默认用户）
if [ -n "${PUBKEY_FILE}" ] && [ -s "${PUBKEY_FILE}" ]; then
  for u in root "${DEFAULT_USER}"; do
    h="$(getent passwd "${u}" | cut -d: -f6)"
    mkdir -p "${h}/.ssh"
    cat "${PUBKEY_FILE}" >> "${h}/.ssh/authorized_keys"
    sort -u "${h}/.ssh/authorized_keys" -o "${h}/.ssh/authorized_keys"
    chmod 700 "${h}/.ssh"
    chmod 600 "${h}/.ssh/authorized_keys"
    chown -R "${u}":"${u}" "${h}/.ssh"
  done
  info "已注入 SSH 公钥"
fi

# 设置密码（root 与默认用户同一密码）
if [ -n "${PW_FILE}" ] && [ -s "${PW_FILE}" ]; then
  for u in root "${DEFAULT_USER}"; do
    printf '%s:%s\n' "${u}" "$(cat "${PW_FILE}")" | chpasswd
  done
  info "已为 root 与 ${DEFAULT_USER} 设置密码"
fi

# 构建期生成的 host key 不能随镜像分发（否则所有实例共用同一份），
# 删除后由 ssh-host-keys.service 在首启时重新生成。
rm -f /etc/ssh/ssh_host_*
cat > /etc/systemd/system/ssh-host-keys.service <<'EOF'
[Unit]
Description=Generate SSH host keys when missing
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

# ---------- 10. 网络：ifupdown + DHCP（内核参数 net.ifnames=0 保证网卡名为 eth0） ----------
cat > /etc/network/interfaces <<'EOF'
# 阿里云 ECS 单网卡 DHCP
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# ---------- 11. cloud-init ----------
# CLOUD_INIT=0 时镜像里根本没有 cloud-init，首启不会自动初始化：
# 密钥必须在构建时通过 ssh_pubkey 烤进镜像（实例创建时绑定密钥对不会生效）
if [ "${CLOUD_INIT}" = "1" ]; then
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-cloud-build.cfg <<EOF
# 由 debian-cloud-build 生成
#
# 刻意不设置 datasource_list：cloud-init 内置的默认列表已经覆盖 AliYun
# （阿里云 ECS 通过 DMI product_name="Alibaba Cloud ECS" 被自动识别）、
# ConfigDrive、NoCloud、Ec2、Azure、GCE 等。自己写一份反而容易拼错名字
# （ds-identify 与 Python 侧用的都是 "AliYun"，不是 "Aliyun"），
# 也会因为把探测范围收窄而影响在其它云平台上的可用性。

disable_root: false
ssh_pwauth: true

# 网络由 ifupdown 负责，避免 cloud-init 重写 /etc/network/interfaces
network:
  config: disabled

system_info:
  default_user:
    name: ${DEFAULT_USER}
    lock_passwd: false
    gecos: Debian
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

# 首启把根分区自动扩到系统盘大小
growpart:
  mode: auto
  devices: ["/"]
  ignore_growroot_disabled: false
resize_rootfs: true
EOF
else
  info "CLOUD_INIT=0：跳过 cloud-init 配置（首启不注入密钥/主机名，也不会自动扩容）"
fi

# ---------- 12. chrony ----------
mkdir -p /etc/chrony /var/log/chrony /var/lib/chrony
cat > /etc/chrony/chrony.conf <<'EOF'
pool ntp.aliyun.com iburst
driftfile /var/lib/chrony/chrony.drift
rtcsync
makestep 1.0 3
logdir /var/log/chrony
EOF

# ---------- 13. initramfs ----------
cat > /etc/initramfs-tools/initramfs.conf <<EOF
MODULES=${INITRAMFS_MODULES}
BUSYBOX=auto
COMPRESS=xz
EOF

# ---------- 14. fstab ----------
{
  printf '# 由 debian-cloud-build 生成\n'
  printf 'UUID=%s / ext4 errors=remount-ro 0 1\n' "${ROOT_UUID}"
  if [ -n "${ESP_UUID}" ]; then
    printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "${ESP_UUID}"
  fi
} > /etc/fstab

# ---------- 15. 主机名 ----------
printf 'debian\n' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 debian
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# ---------- 16. 生成 initramfs ----------
update-initramfs -u -k all

# ---------- 17. 安装引导程序 ----------
info "安装引导程序（boot_mode=${BOOT_MODE}）"
case "${BOOT_MODE}" in
  bios|both)
    grub-install --target=i386-pc --no-floppy --recheck "${DISK_DEV}"
    ;;
esac
case "${BOOT_MODE}" in
  uefi|both)
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=debian --no-nvram --recheck
    # 再写一份可移动介质路径（\EFI\BOOT\BOOTX64.EFI），
    # 云平台没有 NVRAM 启动项时靠它兜底
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --removable --no-nvram --recheck
    ;;
esac

# ---------- 18. 生成 /etc/default/grub 与 /boot/grub/grub.cfg ----------
# 刻意不用 update-grub：chroot 里 grub-probe 解析不出根分区 UUID，
# 会把构建机的临时设备名（/dev/loopXp3）写进 grub.cfg，导致实例起不来。
bash /tmp/guest-grub.sh

# ---------- 19. 启用服务 + 清理裁剪 ----------
# 拆到 guest-finalize.sh：逻辑独立，方便出问题时单独重跑
bash /tmp/guest-finalize.sh
