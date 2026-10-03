#!/usr/bin/env bash
# 公共函数与版本/软件源映射表。被 build-image.sh source，不单独执行。

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限运行（workflow 里用 sudo 调用本脚本）"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1（请先安装对应软件包）"
}

assert_file() { [ -e "$1" ] || die "断言失败：缺少 $1"; }
assert_nonzero_first_sector() {
  # 断言 $2（分区号）的起始扇区不是全 0，用于确认引导代码真的写进去了
  local img="$1" part="$2" tmp
  tmp="$(mktemp -d)"
  local start
  start="$(sgdisk -i "${part}" "${img}" | awk '/First sector:/ {print $3}')"
  [ -n "${start}" ] || { rm -rf "${tmp}"; die "断言失败：无法解析分区 ${part} 的起始扇区"; }
  dd if="${img}" of="${tmp}/sec" bs=512 skip="${start}" count=1 2>/dev/null
  dd if=/dev/zero of="${tmp}/zero" bs=512 count=1 2>/dev/null
  if cmp -s "${tmp}/sec" "${tmp}/zero"; then
    rm -rf "${tmp}"
    die "断言失败：分区 ${part} 内容全为 0，引导代码未写入"
  fi
  rm -rf "${tmp}"
}

# resolve_release <trixie|bookworm|bullseye|buster>
# 导出：DEB_NUM SUITE SEC_SUITE EOL CANDIDATES
#   CANDIDATES：候选源列表，格式 "主源|安全源"，按顺序尝试（用空格分隔）
resolve_release() {
  local rel="$1"
  local aliyun_main="http://mirrors.aliyun.com/debian"
  local aliyun_sec="http://mirrors.aliyun.com/debian-security"
  local aliyun_arch_main="http://mirrors.aliyun.com/debian-archive/debian"
  local aliyun_arch_sec="http://mirrors.aliyun.com/debian-archive/debian-security"

  case "${rel}" in
    13|trixie)
      DEB_NUM=13; SUITE=trixie; SEC_SUITE=trixie-security; EOL=0
      CANDIDATES="${aliyun_main}|${aliyun_sec}"
      ;;
    12|bookworm)
      DEB_NUM=12; SUITE=bookworm; SEC_SUITE=bookworm-security; EOL=0
      CANDIDATES="${aliyun_main}|${aliyun_sec}"
      ;;
    11|bullseye)
      # bullseye 已于 2026-08-31 EOL，它的安全套件已经彻底不可用：
      #   - security.debian.org 已移除
      #   - archive.debian.org / 阿里云 debian-archive 都没有 bullseye 安全归档
      #   - 阿里云 debian-security 只剩 Packages 索引，索引里引用的 .deb 全部 404
      #     （实测 90 个包下载失败，Actions 上就是这么挂的）
      # 所以 bullseye 只用主源、不带安全源；主源先试主镜像，失败再退到 archive。
      # 两个候选源都已实测能完整下载全部依赖包。
      DEB_NUM=11; SUITE=bullseye; SEC_SUITE=""; EOL=1
      CANDIDATES="${aliyun_main}| ${aliyun_arch_main}|"
      ;;
    10|buster)
      # buster 已于 2024-06-30 EOL：阿里云主源已下架，只能用 archive
      DEB_NUM=10; SUITE=buster; SEC_SUITE="buster/updates"; EOL=1
      CANDIDATES="${aliyun_arch_main}|${aliyun_arch_sec}"
      ;;
    *)
      die "不支持的 debian_release：${rel}（可选 trixie / bookworm / bullseye / buster）"
      ;;
  esac
}

# 检查 debootstrap 是否认识目标 suite；不认识时退回 debian-common / sid 脚本
ensure_debootstrap_suite() {
  local suite="$1"
  local dir=/usr/share/debootstrap/scripts
  [ -d "${dir}" ] || die "找不到 ${dir}，debootstrap 安装不完整"
  if [ -e "${dir}/${suite}" ]; then
    log "debootstrap 已支持 ${suite}"
    return 0
  fi
  warn "当前 debootstrap 不认识 ${suite}，尝试复用通用脚本"
  if [ -e "${dir}/debian-common" ]; then
    ln -sf debian-common "${dir}/${suite}"
  elif [ -e "${dir}/sid" ]; then
    ln -sf sid "${dir}/${suite}"
  else
    die "debootstrap 无法处理 ${suite}，请升级 debootstrap"
  fi
  log "已为 ${suite} 创建脚本软链"
}

# 把文件系统里已删除的块真正还给底层镜像文件。
# ext4 删除文件不会通知 loop 设备的后端文件，若不回收，raw 里会残留大量
# 「已删除但仍被占用」的块（实测能差出一倍），压缩后的 qcow2 也就小不下来。
trim_fs() {
  local mp="$1" out
  [ -d "${mp}" ] || return 0
  # 必须先 sync：删除文件后可能仍有脏页在回写，不等它落盘就 fstrim，
  # 回写会把刚打洞释放的块重新分配掉——表现为「fstrim 报告成功、镜像却依然很大」
  # （实测 raw 700MB vs 345MB，最终 qcow2 347MB vs 153MB）。
  sync -f "${mp}" 2>/dev/null || sync
  if out="$(fstrim -v "${mp}" 2>&1)"; then
    log "已回收 ${mp}：${out}"
  else
    warn "fstrim ${mp} 失败（镜像会偏大，但不影响引导）：${out}"
  fi
}

# Ubuntu runner 自带的 keyring 往往缺少新版本 Debian 的签名密钥（如 trixie），
# 缺少时 debootstrap 会因为验签失败而报错。
install_latest_archive_keyring() {
  local pool="http://deb.debian.org/debian/pool/main/d/debian-archive-keyring"
  local deb
  deb="$(curl -fsSL "${pool}/" 2>/dev/null \
    | grep -oE 'debian-archive-keyring_[0-9][0-9.]*_all\.deb' \
    | sort -V | tail -n1 || true)"
  if [ -z "${deb}" ]; then
    warn "无法从 Debian 源解析 debian-archive-keyring 版本，沿用系统自带的 keyring"
    return 0
  fi
  curl -fsSL -o /tmp/debian-archive-keyring.deb "${pool}/${deb}" || {
    warn "下载 ${deb} 失败，沿用系统自带的 keyring"
    return 0
  }
  if dpkg -i /tmp/debian-archive-keyring.deb >/dev/null 2>&1; then
    log "已安装 ${deb}"
  else
    warn "安装 ${deb} 失败，沿用系统自带的 keyring"
  fi
  rm -f /tmp/debian-archive-keyring.deb
}
