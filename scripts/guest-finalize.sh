#!/usr/bin/env bash
# 收尾：启用系统服务 + 清理裁剪。由 guest-setup.sh 调用，也可单独用于调试。
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;34m[guest]\033[0m %s\n' "$*"; }

# shellcheck source=/dev/null
if [ ! -f /tmp/build-params.sh ]; then
  echo "错误：缺少 /tmp/build-params.sh，本脚本需要由 build-image.sh/guest-setup.sh 调用" >&2
  exit 1
fi
. /tmp/build-params.sh

# ---------- 1. 启用服务 ----------
# systemctl enable 会拒绝操作「别名软链」单元（例如 chronyd.service -> chrony.service），
# 这里统一解析成规范名；单元不存在时返回 1，由调用方决定是否容忍。
enable_unit() {
  local unit="$1" path="" resolved
  for path in "/etc/systemd/system/${unit}" "/lib/systemd/system/${unit}" "/usr/lib/systemd/system/${unit}"; do
    [ -e "${path}" ] && break
  done
  [ -e "${path}" ] || return 1
  resolved="$(readlink -f "${path}" 2>/dev/null || true)"
  if [ -n "${resolved}" ]; then
    unit="$(basename "${resolved}")"
  fi
  systemctl enable "${unit}" >/dev/null 2>&1
}

for u in networking.service ssh.service ssh-host-keys.service chrony.service; do
  enable_unit "${u}" || warn "无法启用 ${u}（可能该版本里单元名不同）"
done

if [ "${CLOUD_INIT}" = "1" ]; then
# cloud-init 的服务名随版本变化：
#   Debian 10/11/12：cloud-init-local / cloud-init / cloud-config / cloud-final
#   Debian 13（cloud-init 25.x）：cloud-init-local / cloud-init-network / cloud-init-main + cloud-init.target
# 做法：存在就启用，最后断言确实有 cloud-init 单元被 target 拉起。
for u in cloud-init-local.service cloud-init-network.service cloud-init-main.service \
         cloud-init.service cloud-config.service cloud-final.service cloud-init.target; do
  enable_unit "${u}" || true
done

shopt -s nullglob
ci_units=(/etc/systemd/system/multi-user.target.wants/cloud-init* \
          /etc/systemd/system/cloud-init.target.wants/*)
if [ "${#ci_units[@]}" -eq 0 ]; then
  echo "错误：cloud-init 没有被任何 systemd target 拉起，实例首启不会自动初始化" >&2
  exit 1
fi
info "cloud-init 已挂到 systemd target（${#ci_units[@]} 个单元）"
else
  info "CLOUD_INIT=0：跳过 cloud-init 服务启用"
fi

# 与 chrony / ifupdown 冲突的服务
systemctl disable systemd-timesyncd.service >/dev/null 2>&1 || true
systemctl disable systemd-networkd.service >/dev/null 2>&1 || true

# ---------- 2. 清理与裁剪 ----------
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/lib/cloud/*
rm -f /var/log/cloud-init* /var/log/*.log
rm -rf /var/log/journal/*
rm -f /etc/machine-id /var/lib/dbus/machine-id
: > /etc/machine-id

if [ "${NODOC}" = "1" ]; then
  # 保留每个包的 copyright（许可证声明），删掉其余文档
  find /usr/share/doc -mindepth 1 -maxdepth 1 -type d -exec bash -c '
    for d in "$@"; do
      find "$d" -mindepth 1 -maxdepth 1 ! -name copyright -exec rm -rf {} + 2>/dev/null || true
    done' _ {} + 2>/dev/null || true
  # /usr/share/i18n 是 locales 包的编译源（约 17MB），运行时不需要
  rm -rf /usr/share/man /usr/share/info /usr/share/locale /usr/share/i18n /var/cache/man
fi

rm -f /tmp/guest-setup.sh /tmp/guest-finalize.sh /tmp/guest-grub.sh /tmp/customize.sh \
      /tmp/build-params.sh "${PUBKEY_FILE}" "${PW_FILE}"
info "guest 侧收尾完成"
