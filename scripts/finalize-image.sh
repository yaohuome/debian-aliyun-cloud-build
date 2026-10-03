#!/usr/bin/env bash
# 镜像文件层面的断言 + 压缩为 qcow2。由 build-image.sh 在卸载镜像后调用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

DISK_RAW="${1:?用法: finalize-image.sh <raw 镜像> <boot_mode> <输出目录>}"
BOOT_MODE="${2:?缺少 boot_mode}"
OUTPUT_DIR="${3:?缺少输出目录}"

case "${BOOT_MODE}" in
  both) BOOT_LABEL=bios-uefi ;;
  *)    BOOT_LABEL="${BOOT_MODE}" ;;
esac

assert_file "${DISK_RAW}"

PART_TABLE="$(sgdisk -p "${DISK_RAW}")"
printf '%s\n' "${PART_TABLE}"
printf '%s\n' "${PART_TABLE}" | grep -qE '\bEF02\b' || die "断言失败：缺少 bios_grub(EF02) 分区"
if [ "${BOOT_MODE}" != "bios" ]; then
  printf '%s\n' "${PART_TABLE}" | grep -qE '\bEF00\b' || die "断言失败：缺少 ESP(EF00) 分区"
elif printf '%s\n' "${PART_TABLE}" | grep -qE '\bEF00\b'; then
  warn "bios 模式下仍然存在 ESP 分区（预期不建，会白白占用空间）"
fi
if [ "${BOOT_MODE}" != "uefi" ]; then
  assert_nonzero_first_sector "${DISK_RAW}" 1
  log "断言通过：BIOS 引导代码已写入 bios_grub 分区"
fi

# 镜像版本从 rootfs 里读不到（已卸载），由调用方通过环境变量传入
IMAGE_VERSION="${IMAGE_VERSION:?需要设置 IMAGE_VERSION（来自 /etc/debian_version）}"

OUT="${OUTPUT_DIR}/debian-custom-${IMAGE_VERSION}-${BOOT_LABEL}.qcow2"
mkdir -p "${OUTPUT_DIR}"
log "压缩为 ${OUT}"
rm -f "${OUT}"
qemu-img convert -f raw -O qcow2 -c "${DISK_RAW}" "${OUT}"
qemu-img info "${OUT}"
ls -lh "${OUT}"
rm -f "${DISK_RAW}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "image_name=$(basename "${OUT}")"
    echo "image_version=${IMAGE_VERSION}"
    echo "boot_label=${BOOT_LABEL}"
  } >> "${GITHUB_OUTPUT}"
fi
log "完成：${OUT}"
