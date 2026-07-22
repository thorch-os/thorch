#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"
work="$(mktemp -d)"

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

python3 - "${work}" <<'PY'
import gzip
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
page = 2048

def pad4(data: bytes) -> bytes:
    return data + b"\0" * ((-len(data)) % 4)

def dtb(model: bytes, compatible: bytes, *, symbols: bool = True) -> bytes:
    names = b"model\0compatible\0"
    model_offset = 0
    compatible_offset = len(b"model\0")
    structure = struct.pack(">I", 1) + b"\0\0\0\0"
    for name_offset, value in (
        (model_offset, model + b"\0"),
        (compatible_offset, compatible + b"\0"),
    ):
        structure += struct.pack(">III", 3, len(value), name_offset) + pad4(value)
    if symbols:
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

thor = dtb(b"AYN Thor", b"ayn,thor")
generic = dtb(b"Generic", b"qcom,qcs8550-aim300-aiot")
symbol_less = dtb(b"AYN Thor", b"ayn,thor", symbols=False)
(root / "thor.dtb").write_bytes(thor)

def arm64_image() -> bytes:
    image = bytearray(128)
    image[:21] = b"synthetic-arm64-image"
    image[56:60] = b"ARM\x64"
    return bytes(image)

def boot(
    path: str,
    trailer: bytes,
    *,
    cmdline: bytes = b"root=UUID=test fbcon=rotate:1 allow_mismatched_32bit_el0",
    image=None,
    ramdisk: bytes = b"synthetic-initramfs",
    padding_marker: bytes = b"",
):
    image = arm64_image() if image is None else image
    payload = gzip.compress(image, mtime=0) + trailer
    header = bytearray(page)
    header[:8] = b"ANDROID!"
    struct.pack_into(
        "<10I", header, 8,
        len(payload), 0x1000, len(ramdisk), 0x2000, 0, 0x3000,
        0x4000, page, 0, 0,
    )
    header[64:64 + len(cmdline)] = cmdline
    header[1700:1700 + len(padding_marker)] = padding_marker
    pad = lambda blob: blob + b"\0" * ((page - len(blob) % page) % page)
    (root / path).write_bytes(bytes(header) + pad(payload) + pad(ramdisk))

boot("good", thor)
boot("duplicate-thor", thor + thor)
boot("generic", thor + generic)
boot("symbol-less", symbol_less)
boot("missing-cmdline", thor, cmdline=b"root=UUID=test")
boot("empty-kernel", thor, image=b"")
boot("empty-ramdisk", thor, ramdisk=b"")
boot("marker-in-padding", thor, cmdline=b"quiet", padding_marker=b"root=UUID=fake")
boot("marker-prefix", thor, cmdline=b"notroot=UUID=fake")
boot(
    "duplicate-root",
    thor,
    cmdline=b"root=UUID=test root=UUID=other fbcon=rotate:1 allow_mismatched_32bit_el0",
)
(root / "malformed.dtb").write_bytes(b"\xd0\r\xfe\xed\0\0\0\x08")
(root / "bad-magic").write_bytes(b"not a boot image")
truncated = (root / "good").read_bytes()[:-100]
(root / "truncated").write_bytes(truncated)
PY

python3 "${tool}" validate "${work}/good" \
  --expect-root-uuid test \
  --require-cmdline fbcon=rotate:1 \
  --require-symbols --require-thor --forbid-aim300 --json \
  | grep -q '"dtb_count": 1' || fail "valid image was not described"

python3 "${tool}" extract-kernel "${work}/good" "${work}/Image" --require-thor
grep -q 'synthetic-arm64-image' "${work}/Image" || fail "kernel extraction changed the image"

python3 "${tool}" prepare-repack "${work}/good" "${work}/sections"
[[ -s "${work}/sections/kernel" && -f "${work}/sections/bootimg.env" ]] ||
  fail "repack sections were not emitted"

python3 "${tool}" replace-kernel \
  "${work}/good" "${work}/Image" "${work}/replaced" "${work}/thor.dtb"
python3 "${tool}" validate "${work}/replaced" --require-symbols --require-thor --forbid-aim300
printf 'different-initramfs\n' > "${work}/different-initramfs"
if python3 "${tool}" validate "${work}/good" \
    --expect-ramdisk "${work}/different-initramfs" >/dev/null 2>&1; then
  fail "validator accepted a boot image with a different external initramfs"
fi
if python3 "${tool}" validate "${work}/good" \
    --expect-root-uuid wrong >/dev/null 2>&1; then
  fail "validator accepted the wrong expected root UUID"
fi
if python3 "${tool}" replace-kernel \
    "${work}/good" "${work}/Image" "${work}/malformed-output" \
    "${work}/malformed.dtb" >/dev/null 2>&1; then
  fail "kernel replacement accepted a structurally invalid FDT"
fi

expect_rejected() {
  local label="$1"
  shift
  if python3 "${tool}" validate "${work}/${label}" "$@" >/dev/null 2>&1; then
    fail "validator accepted ${label}"
  fi
}

expect_rejected bad-magic
expect_rejected truncated --require-thor
expect_rejected duplicate-thor --require-thor
expect_rejected generic --forbid-aim300
expect_rejected symbol-less --require-symbols
expect_rejected missing-cmdline --require-cmdline fbcon=rotate:1
expect_rejected empty-kernel --require-thor
expect_rejected empty-ramdisk --require-thor
expect_rejected marker-in-padding --require-cmdline root=UUID=
expect_rejected marker-prefix --require-cmdline root=UUID=
expect_rejected duplicate-root --expect-root-uuid test

printf 'thorch canonical boot-image library checks passed\n'
