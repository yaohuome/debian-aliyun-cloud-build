#!/usr/bin/env bash
# 从零构建可导入阿里云 ECS 的 Debian 云镜像（debootstrap + 最小化裁剪 + BIOS/UEFI 双引导）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

DEBIAN_RELEASE="${DEBIAN_RELEASE:?需要设置 DEBIAN_RELEASE（trixie/bookworm/bullseye/buster）}"
BOOT_MODE="${BOOT_MODE:-both}"
DISK_SIZE="${DISK_SIZE:-1G}"
ESP_SIZE="${ESP_SIZE:-64M}"
INITRAMFS_MODULES="${INITRAMFS_MODULES:-most}"
NODOC="${NODOC:-1}"
CLOUD_INIT="${CLOUD_INIT:-1}"
# 构建时在 chroot 内执行的自定义命令；留空则执行仓库里的 scripts/customize.sh
CUSTOMIZE_COMMANDS="${CUSTOMIZE_COMMANDS:-}"
DEFAULT_USER="${DEFAULT_USER:-debian}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-${PWD}/dist}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/tmp/build-ssh-pubkey}"
SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE:-/tmp/build-password}"

case "${BOOT_MODE}" in
  both|bios|uefi) ;;
  *) die "boot_mode 只能是 both / bios / uefi，当前为 ${BOOT_MODE}" ;;
esac

# cloud_init 开关：关掉后不再安装 cloud-init 及其 python3 运行时（约省 60MB），
# 代价是实例创建时绑定密钥对不再生效，必须依赖构建时烤进镜像的公钥/密码。
case "$(printf '%s' "${CLOUD_INIT}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)   CLOUD_INIT=1 ;;
  0|false|no|off)  CLOUD_INIT=0 ;;
  *) die "CLOUD_INIT 只能是 1/0（true/false），当前为 ${CLOUD_INIT}" ;;
esac

resolve_release "${DEBIAN_RELEASE}"
case "${BOOT_MODE}" in
  both) BOOT_LABEL=bios-uefi ;;
  *)    BOOT_LABEL="${BOOT_MODE}" ;;
esac

require_root
for c in debootstrap losetup qemu-img sgdisk mkfs.ext4 mkfs.vfat blkid chroot curl dpkg find grep tune2fs; do
  require_cmd "${c}"
done

# 防护：CRLF 换行会让 guest 内的脚本解析失败（例如 set -o pipefail 变成非法选项名），
# 在 Windows 上本地编辑过脚本时很容易踩到。
for f in "${SCRIPT_DIR}/guest-setup.sh" "${SCRIPT_DIR}/guest-finalize.sh" \
         "${SCRIPT_DIR}/guest-grub.sh" "${SCRIPT_DIR}/customize.sh"; do
  assert_file "${f}"
  if grep -qU $'\r' "${f}" 2>/dev/null; then
    die "脚本 ${f} 含 CRLF 换行，在 guest 内会解析失败，请先转成 LF（dos2unix 或 sed -i 's/\\r$//'）"
  fi
done

ensure_debootstrap_suite "${SUITE}"
install_latest_archive_keyring

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
DISK_RAW="${WORK_DIR}/debian-${SUITE}-${BOOT_LABEL}.raw"
ROOTFS="${WORK_DIR}/rootfs"
LOOP=""

log "目标：Debian ${DEB_NUM} (${SUITE})｜引导=${BOOT_MODE}｜磁盘=${DISK_SIZE}｜ESP=${ESP_SIZE}"

cleanup() {
  set +e
  umount -R "${ROOTFS}/dev" 2>/dev/null
  umount -R "${ROOTFS}/sys" 2>/dev/null
  umount "${ROOTFS}/proc" 2>/dev/null
  umount "${ROOTFS}/boot/efi" 2>/dev/null
  umount "${ROOTFS}" 2>/dev/null
  [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null
  return 0
}

log "创建 ${DISK_SIZE} 磁盘镜像"
rm -f "${DISK_RAW}"
qemu-img create -f raw "${DISK_RAW}" "${DISK_SIZE}" >/dev/null

LOOP="$(losetup --show -P -f "${DISK_RAW}")"
trap cleanup EXIT

# bios 模式不需要 ESP：省下的 64MiB 在 1GiB 整机上就是实打实的可用空间
if [ "${BOOT_MODE}" = "bios" ]; then
  ROOT_PART_NUM=2
  log "分区：p1 bios_grub(EF02) / p2 root（bios 模式不建 ESP）"
else
  ROOT_PART_NUM=3
  log "分区：p1 bios_grub(EF02) / p2 ESP(EF00, ${ESP_SIZE}) / p3 root"
fi

sgdisk --zap-all "${LOOP}" >/dev/null
sgdisk -n 1:2048:+2048 -t 1:ef02 -c 1:"BIOS boot" "${LOOP}" >/dev/null
if [ "${ROOT_PART_NUM}" = "2" ]; then
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "${LOOP}" >/dev/null
else
  sgdisk -n 2:0:"+${ESP_SIZE}" -t 2:ef00 -c 2:"EFI System" "${LOOP}" >/dev/null
  sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "${LOOP}" >/dev/null
fi

# 重新挂载一次，确保内核读到新的分区表
losetup -d "${LOOP}"
LOOP="$(losetup --show -P -f "${DISK_RAW}")"
ROOT_PART="${LOOP}p${ROOT_PART_NUM}"
ESP_PART=""
ESP_UUID=""
[ "${ROOT_PART_NUM}" = "3" ] && ESP_PART="${LOOP}p2"

# 关闭两个「新版 mke2fs 默认开启、老版本工具认不出」的 ext4 特性：
#   - metadata_csum_seed：Debian 10/11 的 grub 2.06 认不出，grub-install 会报
#     "unknown filesystem" 直接让构建失败（实测 bullseye）
#   - orphan_file：Debian 10/11 的 e2fsprogs（1.46/1.44）认不出，实例启动时
#     initramfs 里的 fsck 会判定文件系统损坏并掉进 (initramfs) 救援 shell
#     （实测 bullseye 镜像构建成功但起不来）
# 两个都只是性能优化，关掉没有任何功能损失。
# 旧版 mke2fs 不认识这些选项时自动退回默认参数。
if ! mkfs.ext4 -F -q -m 0 -L root -O ^metadata_csum_seed,^orphan_file "${ROOT_PART}" 2>/dev/null; then
  warn "本机 mke2fs 不支持 ^metadata_csum_seed/^orphan_file，改用默认特性"
  mkfs.ext4 -F -q -m 0 -L root "${ROOT_PART}" || die "mkfs.ext4 创建根文件系统失败"
fi

# 断言：根文件系统不能带这两个特性，否则老版本 grub / e2fsck 会出问题
FS_FEATURES="$(tune2fs -l "${ROOT_PART}" 2>/dev/null | sed -n 's/^Filesystem features: *//p')"
for bad in metadata_csum_seed orphan_file; do
  case " ${FS_FEATURES} " in
    *" ${bad} "*)
      die "根分区带有 ${bad} 特性，Debian 10/11 的 grub/e2fsck 无法处理，会导致构建失败或实例起不来" ;;
  esac
done
log "根分区特性：${FS_FEATURES}"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
[ -n "${ROOT_UUID}" ] || die "无法获取根分区 UUID"
if [ -n "${ESP_PART}" ]; then
  mkfs.vfat -F 32 -n EFI "${ESP_PART}" >/dev/null
  ESP_UUID="$(blkid -s UUID -o value "${ESP_PART}")"
  [ -n "${ESP_UUID}" ] || die "无法获取 ESP UUID"
fi

mount_esp() {
  [ -n "${ESP_PART}" ] || return 0
  mkdir -p "${ROOTFS}/boot/efi"
  mount "${ESP_PART}" "${ROOTFS}/boot/efi"
}
umount_esp() {
  [ -n "${ESP_PART}" ] || return 0
  umount "${ROOTFS}/boot/efi" 2>/dev/null || true
}

reset_rootfs() {
  umount_esp
  umount "${ROOTFS}" 2>/dev/null || true
  rm -rf "${ROOTFS}"
  mkdir -p "${ROOTFS}"
  mount "${ROOT_PART}" "${ROOTFS}"
  mount_esp
}
reset_rootfs

KEYRING_ARGS=()
[ -f /usr/share/keyrings/debian-archive-keyring.gpg ] \
  && KEYRING_ARGS=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)

bootstrapped=0
for cand in ${CANDIDATES}; do
  main="${cand%%|*}"
  log "debootstrap ${SUITE} <- ${main}"
  if debootstrap --arch=amd64 --variant=minbase --components=main \
      "${KEYRING_ARGS[@]}" "${SUITE}" "${ROOTFS}" "${main}"; then
    bootstrapped=1
    break
  fi
  warn "debootstrap 失败，换下一个候选源"
  reset_rootfs
done
[ "${bootstrapped}" = "1" ] || die "debootstrap 在所有候选源上都失败了"

# ---------- 进入 chroot 完成配置 ----------
log "挂载伪文件系统"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount --rbind /dev "${ROOTFS}/dev"
mount --make-rslave "${ROOTFS}/dev"

PUBKEY_IN_IMAGE=/tmp/build-ssh-pubkey
PW_IN_IMAGE=/tmp/build-password
install -m 0755 "${SCRIPT_DIR}/guest-setup.sh"    "${ROOTFS}/tmp/guest-setup.sh"
install -m 0755 "${SCRIPT_DIR}/guest-finalize.sh" "${ROOTFS}/tmp/guest-finalize.sh"
install -m 0755 "${SCRIPT_DIR}/guest-grub.sh"     "${ROOTFS}/tmp/guest-grub.sh"
install -m 0755 "${SCRIPT_DIR}/customize.sh"      "${ROOTFS}/tmp/customize.sh"

: > "${ROOTFS}${PUBKEY_IN_IMAGE}"
if [ -s "${SSH_PUBKEY_FILE}" ]; then
  cp "${SSH_PUBKEY_FILE}" "${ROOTFS}${PUBKEY_IN_IMAGE}"
  chmod 600 "${ROOTFS}${PUBKEY_IN_IMAGE}"
else
  warn "未提供 SSH 公钥：镜像内不含任何 authorized_keys"
fi
: > "${ROOTFS}${PW_IN_IMAGE}"
if [ -s "${SSH_PASSWORD_FILE}" ]; then
  cp "${SSH_PASSWORD_FILE}" "${ROOTFS}${PW_IN_IMAGE}"
  chmod 600 "${ROOTFS}${PW_IN_IMAGE}"
fi

{
  printf 'DEB_NUM=%q\n'          "${DEB_NUM}"
  printf 'SUITE=%q\n'            "${SUITE}"
  printf 'SEC_SUITE=%q\n'        "${SEC_SUITE}"
  printf 'EOL=%q\n'              "${EOL}"
  printf 'CANDIDATES=%q\n'       "${CANDIDATES}"
  printf 'BOOT_MODE=%q\n'        "${BOOT_MODE}"
  printf 'DISK_DEV=%q\n'         "${LOOP}"
  printf 'ROOT_UUID=%q\n'        "${ROOT_UUID}"
  printf 'ESP_UUID=%q\n'         "${ESP_UUID}"
  printf 'DEFAULT_USER=%q\n'     "${DEFAULT_USER}"
  printf 'TIMEZONE=%q\n'         "${TIMEZONE}"
  printf 'INITRAMFS_MODULES=%q\n' "${INITRAMFS_MODULES}"
  printf 'NODOC=%q\n'            "${NODOC}"
  printf 'CLOUD_INIT=%q\n'       "${CLOUD_INIT}"
  printf 'CUSTOMIZE_COMMANDS=%q\n' "${CUSTOMIZE_COMMANDS}"
  printf 'PUBKEY_FILE=%q\n'      "${PUBKEY_IN_IMAGE}"
  printf 'PW_FILE=%q\n'          "${PW_IN_IMAGE}"
} > "${ROOTFS}/tmp/build-params.sh"

log "在 chroot 内安装并配置系统（这一步最慢，请耐心等待）"
chroot "${ROOTFS}" /bin/bash /tmp/guest-setup.sh

# ---------- 卸载前断言 ----------
IMAGE_VERSION="$(cat "${ROOTFS}/etc/debian_version" 2>/dev/null || true)"
[ -n "${IMAGE_VERSION}" ] || die "无法读取 /etc/debian_version"
USED_PCT="$(df -P "${ROOTFS}" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
log "镜像内 Debian 版本：${IMAGE_VERSION}｜根分区占用：${USED_PCT}%"
[ "${USED_PCT}" -lt 95 ] || die "根分区占用 ${USED_PCT}%，空间不足，无法保证首启扩容"

GRUB_CFG="${ROOTFS}/boot/grub/grub.cfg"
assert_file "${GRUB_CFG}"
grep -qE '^[[:space:]]*linux' "${GRUB_CFG}" || die "断言失败：grub.cfg 中没有内核启动项"
grep -q 'root=UUID=' "${GRUB_CFG}" || die "断言失败：grub.cfg 的 root= 不是 UUID（chroot 里 grub-probe 会解析失败）"
if grep -qE 'root=/dev/(loop|sd|vd|hd)' "${GRUB_CFG}"; then
  die "断言失败：grub.cfg 里写入了构建机的设备名，导入云平台后会找不到根设备"
fi
ls "${ROOTFS}"/boot/vmlinuz-*    >/dev/null 2>&1 || die "断言失败：缺少内核镜像"
ls "${ROOTFS}"/boot/initrd.img-* >/dev/null 2>&1 || die "断言失败：缺少 initramfs"
assert_file "${ROOTFS}/etc/ssh/sshd_config"
[ -s "${ROOTFS}/etc/network/interfaces" ] || die "断言失败：缺少 /etc/network/interfaces"
if [ "${CLOUD_INIT}" = "1" ]; then
  [ -e "${ROOTFS}/etc/cloud/cloud.cfg.d/99-cloud-build.cfg" ] || die "断言失败：缺少 cloud-init 配置"
else
  [ ! -e "${ROOTFS}/usr/bin/cloud-init" ] || warn "CLOUD_INIT=0 但镜像里仍然存在 cloud-init"
fi

# 镜像内的默认软件源：正常应已切换为阿里云内网源；
# 若自定义钩子把源改成了别的（既非内网也非公网阿里云），只提示不报错。
if grep -rq 'mirrors.cloud.aliyuncs.com' \
     "${ROOTFS}/etc/apt/sources.list" "${ROOTFS}/etc/apt/sources.list.d/" 2>/dev/null; then
  :
elif grep -rq 'mirrors.aliyun.com' \
       "${ROOTFS}/etc/apt/sources.list" "${ROOTFS}/etc/apt/sources.list.d/" 2>/dev/null; then
  die "断言失败：镜像内源仍指向公网 mirrors.aliyun.com，说明内网源切换没生效"
else
  warn "镜像内源不是阿里云（可能被自定义钩子改过），跳过内网源断言"
fi
# 构建期临时脚本不能残留在镜像的 /tmp 里
for leftover in /tmp/guest-setup.sh /tmp/guest-finalize.sh /tmp/guest-grub.sh \
                /tmp/customize.sh /tmp/build-params.sh; do
  if [ -e "${ROOTFS}${leftover}" ]; then
    die "断言失败：/tmp 里残留了构建脚本 ${leftover}"
  fi
done

assert_file "${ROOTFS}/root/switch-apt-mirror.sh"
[ -x "${ROOTFS}/root/switch-apt-mirror.sh" ] || die "断言失败：/root/switch-apt-mirror.sh 不可执行"
[ ! -s "${ROOTFS}/etc/machine-id" ] || die "断言失败：/etc/machine-id 未清空"
case "${BOOT_MODE}" in
  uefi|both)
    assert_file "${ROOTFS}/boot/efi/EFI/BOOT/BOOTX64.EFI"
    assert_file "${ROOTFS}/boot/efi/EFI/debian/grubx64.efi"
    ;;
esac

log "回收已删除的数据块（决定最终镜像大小）"
trim_fs "${ROOTFS}"
trim_fs "${ROOTFS}/boot/efi"

log "卸载镜像（第一轮）"
cleanup
trap - EXIT

# 重新挂载做第二轮回收：第一轮若因回写竞争没生效，这一轮基本必然生效。
# 实测 raw 从 ~700MB 降到 ~345MB，最终 qcow2 从 347MB 降到 153MB。
log "重新挂载做第二轮回收"
LOOP="$(losetup --show -P -f "${DISK_RAW}")"
mount "${ROOT_PART}" "${ROOTFS}"
mount_esp
trim_fs "${ROOTFS}"
trim_fs "${ROOTFS}/boot/efi"
umount_esp
umount "${ROOTFS}"
losetup -d "${LOOP}"
LOOP=""

RAW_ALLOC_MB="$(du -m "${DISK_RAW}" | cut -f1)"
log "raw 实际占用：${RAW_ALLOC_MB} MB"
[ "${RAW_ALLOC_MB}" -lt 600 ] \
  || warn "raw 占用 ${RAW_ALLOC_MB}MB 偏大，说明块回收没完全生效（不影响使用，只是镜像更大）"

# ---------- 镜像文件层面的断言 + 压缩（独立脚本，便于单独调试） ----------
IMAGE_VERSION="${IMAGE_VERSION}" \
  bash "${SCRIPT_DIR}/finalize-image.sh" "${DISK_RAW}" "${BOOT_MODE}" "${OUTPUT_DIR}"
