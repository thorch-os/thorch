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
  local -a disk_metadata=()

  local rocknix_boot_start=32768
  local rocknix_boot_type="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
  local linux_root_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

  [[ -f "${image}" || -b "${image}" ]] || { echo "image/block device not found: ${image}" >&2; return 1; }
  printf 'validating: %s\n' "${image}"

  mapfile -t disk_metadata < <(
    sfdisk --json "${image}" | python3 -c '
import json
import sys

table = json.load(sys.stdin).get("partitiontable", {})
partitions = table.get("partitions", [])
boot = partitions[0] if len(partitions) > 0 else {}
root = partitions[1] if len(partitions) > 1 else {}
for value in (
    table.get("label", ""),
    table.get("sectorsize", ""),
    len(partitions),
    boot.get("start", ""),
    boot.get("type", ""),
    boot.get("name", ""),
    boot.get("attrs", ""),
    root.get("start", ""),
    root.get("type", ""),
    root.get("name", ""),
):
    print(value)
'
  )

  if [[ "${#disk_metadata[@]}" -ne 10 ]]; then
    echo "unable to parse partition metadata from image" >&2
    return 1
  fi

  boot_start="${disk_metadata[3]}"
  root_start="${disk_metadata[7]}"
  sector_size="${disk_metadata[1]}"

  if [[ -z "${boot_start}" || -z "${root_start}" || -z "${sector_size}" ]]; then
    echo "unable to find boot/root partition offsets in image" >&2
    return 1
  fi

  boot_offset=$((boot_start * sector_size))
  root_offset=$((root_start * sector_size))
  boot_ref="${image}@@${boot_offset}"
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

  check "disk uses a GPT with exactly two partitions" \
    test "${disk_metadata[0]}:${disk_metadata[2]}" = "gpt:2"
  check "boot partition starts at the ROCKNIX 16 MiB offset" \
    test "${boot_start}" = "${rocknix_boot_start}"
  check "boot partition uses the ROCKNIX Basic Data type" \
    test "${disk_metadata[4],,}" = "${rocknix_boot_type,,}"
  check "boot partition is named system" \
    test "${disk_metadata[5]}" = "system"
  check "boot partition carries the legacy boot attribute" \
    grep -qw LegacyBIOSBootable <<<"${disk_metadata[6]}"
  check "root partition uses the Linux type and storage name" \
    test "${disk_metadata[8],,}:${disk_metadata[9]}" = "${linux_root_type,,}:storage"

  has_fat_path() {
    local path="$1"
    mdir -i "${boot_ref}" "::${path}" >/dev/null 2>&1
  }

  root_listing="$(mdir -i "${boot_ref}" ::/)"
  check "boot partition keeps ROCKNIX compatibility label" grep -q 'is ROCKNIX' <<<"${root_listing}"
  check "Android boot image /KERNEL exists at FAT root" has_fat_path /KERNEL

  if has_fat_path /KERNEL; then
    root_uuid="$(blkid -p -o value -s UUID --offset "${root_offset}" "${image}" 2>/dev/null || true)"
    if [[ -z "${root_uuid}" ]]; then
      echo "unable to read root filesystem UUID from image" >&2
      return 1
    fi
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
    check "KERNEL defaults to s2idle" kernel_cmdline_has 'mem_sleep_default=s2idle'
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
