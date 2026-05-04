#!/usr/bin/env bash
set -euo pipefail

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

for cmd in sfdisk mdir mcopy file strings grep awk python3; do
  require_cmd "${cmd}"
done

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
  local boot_start sector_size boot_offset boot_ref tmpdir failures
  local root_listing kernel_file_type kernel_strings

  [[ -f "${image}" || -b "${image}" ]] || { echo "image/block device not found: ${image}" >&2; return 1; }
  printf 'validating: %s\n' "${image}"

  boot_start="$(
    sfdisk -d "${image}" |
      awk -F 'start=|,' '$1 ~ /1[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
  )"
  sector_size="$(
    sfdisk -d "${image}" |
      awk -F ': ' '$1 == "sector-size" {print $2; exit}'
  )"

  if [[ -z "${boot_start}" || -z "${sector_size}" ]]; then
    echo "unable to find boot partition offset in image" >&2
    return 1
  fi

  boot_offset=$((boot_start * sector_size))
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

  has_fat_path() {
    local path="$1"
    mdir -i "${boot_ref}" "::${path}" >/dev/null 2>&1
  }

  root_listing="$(mdir -i "${boot_ref}" ::/)"
  check "boot partition is labelled ROCKNIX" grep -q 'is ROCKNIX' <<<"${root_listing}"
  check "Android boot image /KERNEL exists at FAT root" has_fat_path /KERNEL

  if has_fat_path /KERNEL; then
    mcopy -o -i "${boot_ref}" ::/KERNEL "${tmpdir}/KERNEL" >/dev/null
    kernel_file_type="$(file -b "${tmpdir}/KERNEL")"
    kernel_strings="${tmpdir}/KERNEL.strings"
    strings -n 8 "${tmpdir}/KERNEL" > "${kernel_strings}"

    kernel_embeds_dtb() {
      python3 - "${tmpdir}/KERNEL" <<'PY'
import pathlib
import struct
import sys

kernel = pathlib.Path(sys.argv[1]).read_bytes()
magic = b"\xd0\r\xfe\xed"
pos = 0

while True:
    at = kernel.find(magic, pos)
    if at < 0:
        sys.exit(1)
    if len(kernel) < at + 8:
        sys.exit(1)
    size = struct.unpack_from(">I", kernel, at + 4)[0]
    if size < 8 or len(kernel) < at + size:
        pos = at + 4
        continue
    dtb = kernel[at:at + size]
    if b"AYN Thor\x00" in dtb and b"ayn,thor\x00" in dtb:
        sys.exit(0)
    pos = at + size
PY
    }

    check "KERNEL is an Android boot image" grep -q '^Android bootimg' <<<"${kernel_file_type}"
    check "KERNEL command line uses root UUID" grep -q 'root=UUID=' "${kernel_strings}"
    check "KERNEL command line rotates fbcon right" grep -q 'fbcon=rotate:1' "${kernel_strings}"
    check "KERNEL embeds the Thor DTB" kernel_embeds_dtb
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
