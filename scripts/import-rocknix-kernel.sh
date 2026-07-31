#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/import-rocknix-kernel.sh --from-dir <dir> [--boot-dir <dir>] [--root-dir <dir>] [--dest <dir>] [--ref <label>]

Imports prebuilt ROCKNIX kernel artifacts for Thorch. The input may be a mounted
ROCKNIX boot/root filesystem, an extracted ROCKNIX image tree, or separate boot
and root directories.

Required artifacts:
  KERNEL
  usr/lib/modules/<kernel-release>/ or ROCKNIX kernel-overlays/base/lib/modules
  usr/lib/firmware/qcom/a740_sqe.fw or ROCKNIX kernel-overlays/base/lib/firmware/qcom/a740_sqe.fw
  usr/lib/firmware/qcom/gmu_gen70200.bin or ROCKNIX kernel-overlays/base/lib/firmware/qcom/gmu_gen70200.bin
  usr/lib/firmware/qcom/sm8550/a740_zap.mbn or ROCKNIX kernel-overlays/base/lib/firmware/qcom/sm8550/a740_zap.mbn

Thorch preserves the imported ROCKNIX boot-image kernel payload, generates its
own Arch initramfs, and repacks /boot/KERNEL during image creation.
EOF
}

require_value() {
  local opt="$1" value="${2:-}"
  [[ -n "${value}" ]] || {
    usage
    die "${opt} requires a value"
  }
}

from_dir=""
boot_dir=""
root_dir=""
dest="${THORCH_ROCKNIX_KERNEL_DIR}"
ref_label="${ROCKNIX_REF}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --from-dir)
      require_value "$1" "${2:-}"
      from_dir="$2"
      shift 2
      ;;
    --boot-dir)
      require_value "$1" "${2:-}"
      boot_dir="$2"
      shift 2
      ;;
    --root-dir)
      require_value "$1" "${2:-}"
      root_dir="$2"
      shift 2
      ;;
    --dest)
      require_value "$1" "${2:-}"
      dest="$2"
      shift 2
      ;;
    --ref)
      require_value "$1" "${2:-}"
      ref_label="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "${from_dir}" ]]; then
  boot_dir="${boot_dir:-${from_dir}}"
  root_dir="${root_dir:-${from_dir}}"
fi
[[ -n "${boot_dir}" && -n "${root_dir}" ]] || {
  usage
  die "provide --from-dir or both --boot-dir and --root-dir"
}

require_cmd find install python3 rsync

root="$(repo_root)"
boot_tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"
[[ -f "${boot_tool}" ]] || die "missing canonical boot-image tool: ${boot_tool}"
if [[ "${dest}" == /* ]]; then
  dest_abs="$(abspath "${dest}")"
else
  dest_abs="$(abspath "${root}/${dest}")"
fi
boot_dir_abs="$(abspath "${boot_dir}")"
root_dir_abs="$(abspath "${root_dir}")"

case "${boot_dir_abs}:${root_dir_abs}" in
  *"${root}/packages/"*"/pkg"*|*"${root}/packages/"*"/src"*)
    die "refusing to import kernel artifacts from local makepkg pkg/src outputs; use a mounted or extracted ROCKNIX image"
    ;;
esac

find_first() {
  local base="$1"
  shift
  find "${base}" "$@" 2>/dev/null | sort | head -n1
}

find_firmware_root() {
  local base="$1" candidate fallback firmware complete
  for candidate in \
    "${base}/usr/lib/firmware" \
    "${base}/lib/firmware" \
    "${base}/usr/lib/kernel-overlays/base/lib/firmware" \
    "${base}/lib/kernel-overlays/base/lib/firmware" \
    "${base}/system/usr/lib/kernel-overlays/base/lib/firmware" \
    "${base}/system/lib/kernel-overlays/base/lib/firmware"; do
    [[ -d "${candidate}" ]] || continue
    fallback="${fallback:-${candidate}}"
    complete=1
    for firmware in "${required_firmware[@]}"; do
      if [[ ! -f "${candidate}/${firmware}" ]]; then
        complete=0
        break
      fi
    done
    if [[ "${complete}" -eq 1 ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if [[ -n "${fallback:-}" ]]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  return 1
}

find_modules_root() {
  local base="$1" candidate
  for candidate in \
    "${base}/usr/lib/modules" \
    "${base}/lib/modules" \
    "${base}/usr/lib/kernel-overlays/base/lib/modules" \
    "${base}/lib/kernel-overlays/base/lib/modules" \
    "${base}/system/usr/lib/kernel-overlays/base/lib/modules" \
    "${base}/system/lib/kernel-overlays/base/lib/modules"; do
    if [[ -d "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

image="$(find_first "${boot_dir}" -type f -name Image)"
kernel_boot="$(find_first "${boot_dir}" -maxdepth 3 -type f -name KERNEL)"
modules_root="$(find_modules_root "${root_dir_abs}" || true)"
required_firmware=(
  qcom/a740_sqe.fw
  qcom/gmu_gen70200.bin
  qcom/sm8550/a740_zap.mbn
)
firmware_root="$(find_firmware_root "${root_dir_abs}" || true)"

extract_android_boot_image() {
  local kernel_boot="$1" image_out="$2"
  python3 "${boot_tool}" extract-kernel \
    "${kernel_boot}" "${image_out}" --require-thor
}

[[ -n "${kernel_boot}" && -f "${kernel_boot}" ]] || die "could not find ROCKNIX KERNEL under ${boot_dir}"
[[ -n "${modules_root}" && -d "${modules_root}" ]] || die "could not find ROCKNIX modules under ${root_dir}"
[[ -n "${firmware_root}" && -d "${firmware_root}" ]] || die "could not find ROCKNIX firmware under ${root_dir}"
for firmware in "${required_firmware[@]}"; do
  [[ -f "${firmware_root}/${firmware}" ]] || die "could not find ROCKNIX firmware ${firmware} under ${root_dir}"
done
rm -rf "${dest_abs}"
install -d "${dest_abs}/usr/lib/modules"
if [[ -n "${image}" && -f "${image}" ]]; then
  install -Dm644 "${image}" "${dest_abs}/boot/Image"
else
  extract_android_boot_image "${kernel_boot}" "${dest_abs}/boot/Image"
fi
rsync -a "${modules_root}/" "${dest_abs}/usr/lib/modules/"
if [[ -n "${firmware_root}" && -d "${firmware_root}" ]]; then
  install -d "${dest_abs}/usr/lib/firmware"
  rsync -a "${firmware_root}/" "${dest_abs}/usr/lib/firmware/"
fi
install -Dm644 "${kernel_boot}" "${dest_abs}/boot/KERNEL"

{
  printf 'ROCKNIX_REPO=%s\n' "${ROCKNIX_REPO}"
  printf 'ROCKNIX_REF=%s\n' "${ref_label}"
  printf 'SOURCE_BOOT_DIR=%s\n' "${boot_dir_abs}"
  printf 'SOURCE_ROOT_DIR=%s\n' "${root_dir_abs}"
  if [[ -n "${image}" && -f "${image}" ]]; then
    printf 'SOURCE_IMAGE=%s\n' "${image}"
  else
    printf 'SOURCE_IMAGE=derived-from-KERNEL\n'
  fi
  printf 'SOURCE_ROCKNIX_BOOT_PAYLOAD=%s\n' "${kernel_boot}"
  printf 'SOURCE_MODULES=%s\n' "${modules_root}"
  printf 'SOURCE_FIRMWARE_ROOT=%s\n' "${firmware_root}"
  printf 'SOURCE_REQUIRED_FIRMWARE=%s\n' "${required_firmware[*]}"
  date -u '+IMPORTED_AT=%Y-%m-%dT%H:%M:%SZ'
} > "${dest_abs}/PROVENANCE"
chmod 0644 "${dest_abs}/PROVENANCE"

log "ROCKNIX kernel artifacts imported to ${dest_abs}"
