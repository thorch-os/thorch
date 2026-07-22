#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rebuild="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
boot_tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"
work="$(mktemp -d)"

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

install -d "${work}/bin" "${work}/boot"
python3 - "${work}/candidate" <<'PY'
import gzip
import pathlib
import struct
import sys

out = pathlib.Path(sys.argv[1])
page = 2048

def pad4(data: bytes) -> bytes:
    return data + b"\0" * ((-len(data)) % 4)

def thor_dtb() -> bytes:
    names = b"model\0compatible\0"
    structure = struct.pack(">I", 1) + b"\0\0\0\0"
    for name_offset, value in (
        (0, b"AYN Thor\0"),
        (len(b"model\0"), b"ayn,thor\0"),
    ):
        structure += struct.pack(">III", 3, len(value), name_offset) + pad4(value)
    structure += struct.pack(">I", 1) + pad4(b"__symbols__\0")
    structure += struct.pack(">I", 2)
    structure += struct.pack(">II", 2, 9)
    reserve = b"\0" * 16
    structure_offset = 40 + len(reserve)
    strings_offset = structure_offset + len(structure)
    total_size = strings_offset + len(names)
    header = struct.pack(
        ">10I", 0xD00DFEED, total_size, structure_offset, strings_offset,
        40, 17, 16, 0, len(names), len(structure),
    )
    return header + reserve + structure + names

image = bytearray(128)
image[:21] = b"synthetic-arm64-image"
image[56:60] = b"ARM\x64"
kernel = gzip.compress(bytes(image), mtime=0) + thor_dtb()
ramdisk = b"test-initramfs\n"
header = bytearray(page)
header[:8] = b"ANDROID!"
struct.pack_into("<10I", header, 8, len(kernel), 0x1000, len(ramdisk), 0x2000, 0, 0x3000, 0x4000, page, 0, 0)
cmdline = b"root=UUID=11111111-2222-3333-4444-555555555555 fbcon=rotate:1 allow_mismatched_32bit_el0"
header[64:64 + len(cmdline)] = cmdline
pad = lambda value: value + b"\0" * ((page - len(value) % page) % page)
out.write_bytes(bytes(header) + pad(kernel) + pad(ramdisk))
PY
printf 'not-an-android-image\n' > "${work}/bad-candidate"
printf 'old-live-payload\n' > "${work}/boot/KERNEL"
printf 'test-initramfs\n' > "${work}/boot/initramfs-linux-thorch.img"

cat > "${work}/bin/mkbootimg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${output}" ]]
cp "${THORCH_TEST_CANDIDATE}" "${output}"
EOF
chmod 755 "${work}/bin/mkbootimg"

PATH="${work}/bin:${PATH}" \
THORCH_BOOT_IMAGE_TOOL="${boot_tool}" \
THORCH_TEST_CANDIDATE="${work}/candidate" \
  "${rebuild}" \
    --boot-dir "${work}/boot" \
    --root-uuid 11111111-2222-3333-4444-555555555555 \
    --rootfstype ext4 \
    --source-kernel "${work}/candidate" >/dev/null

grep -q old-live-payload "${work}/boot/KERNEL.previous" ||
  fail "successful rebuild did not retain the old live payload"
python3 "${boot_tool}" validate "${work}/boot/KERNEL" \
  --expect-root-uuid 11111111-2222-3333-4444-555555555555 \
  --require-symbols --require-thor

live_hash="$(file_sha256 "${work}/boot/KERNEL")"
previous_hash="$(file_sha256 "${work}/boot/KERNEL.previous")"
if PATH="${work}/bin:${PATH}" \
  THORCH_BOOT_IMAGE_TOOL="${boot_tool}" \
  THORCH_TEST_CANDIDATE="${work}/bad-candidate" \
    "${rebuild}" \
      --boot-dir "${work}/boot" \
      --root-uuid 11111111-2222-3333-4444-555555555555 \
      --rootfstype ext4 \
      --source-kernel "${work}/candidate" >/dev/null 2>&1; then
  fail "rebuild accepted an invalid candidate"
fi
[[ "$(file_sha256 "${work}/boot/KERNEL")" == "${live_hash}" ]] ||
  fail "failed rebuild changed live KERNEL"
[[ "$(file_sha256 "${work}/boot/KERNEL.previous")" == "${previous_hash}" ]] ||
  fail "failed rebuild changed KERNEL.previous"

if find "${work}/boot" -maxdepth 1 -name '.KERNEL.new.*' | grep -q .; then
  fail "failed rebuild left a candidate file on the boot filesystem"
fi

printf 'thorch atomic boot rebuild checks passed\n'
