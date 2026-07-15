#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
waydroid_kernel_config="${root}/packages/linux-thorch/waydroid-kernel.config"
boot_tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 /path/to/thorch-arch.img [more-images...]" >&2
  exit 2
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}" >&2
    exit 1
  fi
}

for cmd in sfdisk mdir mcopy file grep awk blkid python3; do
  require_cmd "${cmd}"
done
[[ -f "${boot_tool}" ]] || { echo "missing canonical boot-image tool: ${boot_tool}" >&2; exit 1; }

tmpdirs=()
cleanup() {
  local dir
  for dir in "${tmpdirs[@]}"; do
    rm -rf "${dir}"
  done
}
trap cleanup EXIT

validate_image() {
  local image="$1"
  local boot_start root_start sector_size boot_offset root_offset boot_ref tmpdir failures
  local root_listing kernel_file_type root_uuid

  [[ -f "${image}" || -b "${image}" ]] || { echo "image/block device not found: ${image}" >&2; return 1; }
  printf 'validating: %s\n' "${image}"

  boot_start="$(
    sfdisk -d "${image}" |
      awk -F 'start=|,' '$1 ~ /1[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
  )"
  root_start="$(
    sfdisk -d "${image}" |
      awk -F 'start=|,' '$1 ~ /2[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
  )"
  sector_size="$(
    sfdisk -d "${image}" |
      awk -F ': ' '$1 == "sector-size" {print $2; exit}'
  )"

  if [[ -z "${boot_start}" || -z "${root_start}" || -z "${sector_size}" ]]; then
    echo "unable to find boot/root partition offsets in image" >&2
    return 1
  fi

  boot_offset=$((boot_start * sector_size))
  root_offset=$((root_start * sector_size))
  boot_ref="${image}@@${boot_offset}"
  root_uuid="$(blkid -p -o value -s UUID --offset "${root_offset}" "${image}" 2>/dev/null || true)"
  if [[ -z "${root_uuid}" ]]; then
    echo "unable to read root filesystem UUID from image" >&2
    return 1
  fi
  tmpdir="$(mktemp -d)"
  tmpdirs+=("${tmpdir}")
  failures=0

  check() {
    local label="$1"
    shift
    if "$@"; then
      printf 'ok: %s\n' "${label}"
    else
      printf 'FAIL: %s\n' "${label}" >&2
      failures=$((failures + 1))
    fi
  }

  has_fat_path() {
    local path="$1"
    mdir -i "${boot_ref}" "::${path}" >/dev/null 2>&1
  }

  root_listing="$(mdir -i "${boot_ref}" ::/)"
  check "boot partition keeps ROCKNIX compatibility label" grep -q 'is ROCKNIX' <<<"${root_listing}"
  check "Android boot image /KERNEL exists at FAT root" has_fat_path /KERNEL

  if has_fat_path /KERNEL; then
    mcopy -o -i "${boot_ref}" ::/KERNEL "${tmpdir}/KERNEL" >/dev/null
    kernel_file_type="$(file -b "${tmpdir}/KERNEL")"

    kernel_has_rocknix_thor_dtb() {
      python3 "${boot_tool}" validate "${tmpdir}/KERNEL" \
        --require-symbols --require-thor
    }

    kernel_cmdline_has() {
      python3 "${boot_tool}" validate "${tmpdir}/KERNEL" --require-cmdline "$1"
    }

    kernel_uses_image_root_uuid() {
      python3 "${boot_tool}" validate "${tmpdir}/KERNEL" \
        --expect-root-uuid "${root_uuid}"
    }

    kernel_excludes_generic_dtb() {
      python3 "${boot_tool}" validate "${tmpdir}/KERNEL" --forbid-aim300
    }

    kernel_supports_waydroid() {
      [[ "${THORCH_WAYDROID_KERNEL_REQUIRED:-1}" != "0" ]] || return 0
      python3 "${boot_tool}" check-config \
        "${tmpdir}/KERNEL" "${waydroid_kernel_config}" --boot-image
    }

    check "KERNEL is an Android boot image" grep -q '^Android bootimg' <<<"${kernel_file_type}"
    check "KERNEL command line uses the image root UUID" kernel_uses_image_root_uuid
    check "KERNEL command line rotates fbcon right" kernel_cmdline_has 'fbcon=rotate:1'
    check "KERNEL allows ROCKNIX asymmetric 32-bit CPU features" kernel_cmdline_has 'allow_mismatched_32bit_el0'
    check "KERNEL embeds the ROCKNIX Thor DTB with overlay symbols" kernel_has_rocknix_thor_dtb
    check "KERNEL excludes the generic AIM300 DTB" kernel_excludes_generic_dtb
    check "KERNEL supports Waydroid BinderFS" kernel_supports_waydroid
  fi

  if [[ "${failures}" -ne 0 ]]; then
    echo "Thorch image validation failed: ${failures} issue(s)" >&2
    return 1
  fi

  echo "Thorch image validation passed"
}

overall=0
for image in "$@"; do
  validate_image "${image}" || overall=1
done

exit "${overall}"
