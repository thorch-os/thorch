#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
waydroid_kernel_config="${root}/packages/linux-thorch/waydroid-kernel.config"

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
  check "boot partition keeps ROCKNIX compatibility label" grep -q 'is ROCKNIX' <<<"${root_listing}"
  check "Android boot image /KERNEL exists at FAT root" has_fat_path /KERNEL

  if has_fat_path /KERNEL; then
    mcopy -o -i "${boot_ref}" ::/KERNEL "${tmpdir}/KERNEL" >/dev/null
    kernel_file_type="$(file -b "${tmpdir}/KERNEL")"
    kernel_strings="${tmpdir}/KERNEL.strings"
    strings -n 8 "${tmpdir}/KERNEL" > "${kernel_strings}"

    kernel_has_rocknix_thor_dtb() {
      python3 - "${tmpdir}/KERNEL" <<'PY'
import pathlib
import struct
import sys
import zlib

data = pathlib.Path(sys.argv[1]).read_bytes()
if data[:8] != b"ANDROID!":
    sys.exit(1)

kernel_size = struct.unpack_from("<I", data, 8)[0]
page_size = struct.unpack_from("<I", data, 36)[0]
payload = data[page_size:page_size + kernel_size]
try:
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    decompressor.decompress(payload)
    decompressor.flush()
    dtbs = decompressor.unused_data
except zlib.error:
    sys.exit(1)
if not decompressor.eof:
    sys.exit(1)

parsed = []
pos = 0
while pos < len(dtbs):
    if dtbs[pos:pos + 4] != b"\xd0\r\xfe\xed" or len(dtbs) < pos + 8:
        sys.exit(1)
    size = struct.unpack_from(">I", dtbs, pos + 4)[0]
    if size < 8 or len(dtbs) < pos + size:
        sys.exit(1)
    parsed.append(dtbs[pos:pos + size])
    pos += size

if not parsed or any(b"__symbols__\x00" not in dtb for dtb in parsed):
    sys.exit(1)
matches = [
    dtb for dtb in parsed
    if b"AYN Thor\x00" in dtb and b"ayn,thor\x00" in dtb
]
sys.exit(0 if len(matches) == 1 else 1)
PY
    }

    kernel_cmdline_has() {
      python3 - "${tmpdir}/KERNEL" "$1" <<'PY'
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
marker = sys.argv[2].encode("ascii")
if data[:8] != b"ANDROID!" or len(data) < 40:
    sys.exit(1)
page_size = struct.unpack_from("<I", data, 36)[0]
if page_size <= 0 or len(data) < page_size:
    sys.exit(1)
sys.exit(0 if marker in data[:page_size] else 1)
PY
    }

    kernel_excludes_generic_dtb() {
      ! grep -q 'qcom,qcs8550-aim300-aiot' "${kernel_strings}"
    }

    kernel_supports_waydroid() {
      [[ "${THORCH_WAYDROID_KERNEL_REQUIRED:-1}" != "0" ]] || return 0
      python3 - "${tmpdir}/KERNEL" "${waydroid_kernel_config}" <<'PY'
import gzip
import pathlib
import struct
import sys
import zlib

data = pathlib.Path(sys.argv[1]).read_bytes()
required_path = pathlib.Path(sys.argv[2])
if data[:8] != b"ANDROID!":
    sys.exit(1)

kernel_size = struct.unpack_from("<I", data, 8)[0]
page_size = struct.unpack_from("<I", data, 36)[0]
payload = data[page_size:page_size + kernel_size]
try:
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    image = decompressor.decompress(payload) + decompressor.flush()
except zlib.error:
    sys.exit(1)
if not decompressor.eof:
    sys.exit(1)

start = image.find(b"IKCFG_ST")
end = image.find(b"IKCFG_ED", start)
if start < 0 or end < 0:
    sys.exit(1)

try:
    config_text = gzip.decompress(image[start + len(b"IKCFG_ST"):end].lstrip(b"\x00\n")).decode("utf-8", "replace")
except OSError:
    sys.exit(1)

required = {}
for raw in required_path.read_text(encoding="utf-8").splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    key, value = line.split("=", 1)
    required[key] = value
config = {}
for line in config_text.splitlines():
    if line.startswith("CONFIG_") and "=" in line:
        key, value = line.split("=", 1)
        config[key] = value

sys.exit(0 if all(config.get(key) == value for key, value in required.items()) else 1)
PY
    }

    check "KERNEL is an Android boot image" grep -q '^Android bootimg' <<<"${kernel_file_type}"
    check "KERNEL command line uses root UUID" kernel_cmdline_has 'root=UUID='
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
