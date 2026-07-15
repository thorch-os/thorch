#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="${root}/scripts/build-thorch-kernel.sh"
validator="${root}/scripts/check-thorch-image.sh"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
boot_check="${root}/packages/thorch-bsp/payload/usr/bin/thorch-check-boot"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'find "${dts_abs}/qcom"' "${builder}" ||
  fail "kernel builder does not derive its DTB manifest from ROCKNIX overlays"

grep -q 'DTC_FLAGS=-@ Image "${dtb_targets\[@\]}" modules' "${builder}" ||
  fail "kernel builder does not preserve ROCKNIX DTB overlay symbols"

grep -q 'boot_tmp="${build_abs}/thorch-boot.img"' "${builder}" ||
  fail "kernel builder boot-image temporary path can collide with the kernel object directory"

grep -q 'dtb_paths = \[pathlib.Path(path) for path in sys.argv\[4:\]\]' "${builder}" ||
  fail "Android boot image is not packed from the explicit ROCKNIX DTB manifest"

grep -q 'missing the ROCKNIX overlay symbol table' "${builder}" ||
  fail "kernel builder does not reject symbol-less DTBs"

grep -q 'rm -rf "${dest_abs}/usr/lib/modules" "${dest_abs}/boot/dtb/qcom"' "${builder}" ||
  fail "kernel builder does not remove stale DTBs from the artifact directory"

! grep -q 'dtb_dir.glob("qcs8550-\*\.dtb")' "${builder}" ||
  fail "kernel builder can still package stale or generic qcs8550 DTBs"

grep -q 'KERNEL embeds the ROCKNIX Thor DTB with overlay symbols' "${validator}" ||
  fail "image validator does not require the symbol-bearing ROCKNIX Thor DTB"

grep -q 'KERNEL excludes the generic AIM300 DTB' "${validator}" ||
  fail "image validator does not reject the generic AIM300 DTB"

grep -q 'KERNEL allows ROCKNIX asymmetric 32-bit CPU features' "${validator}" ||
  fail "image validator does not require ROCKNIX asymmetric CPU compatibility"

grep -q 'DTB without ROCKNIX overlay symbols' "${repacker}" ||
  fail "on-device boot repacker does not reject a symbol-less Thor DTB"

grep -q 'generic AIM300 DTB' "${repacker}" ||
  fail "on-device boot repacker does not reject the generic AIM300 DTB"

grep -q 'ROCKNIX Thor DTB with overlay symbols' "${boot_check}" ||
  fail "on-device boot checker does not require the symbol-bearing Thor DTB"

grep -q 'generic AIM300 DTB must be absent' "${boot_check}" ||
  fail "on-device boot checker does not reject the generic AIM300 DTB"

grep -q 'allow_mismatched_32bit_el0' "${repacker}" ||
  fail "on-device boot repacker drops ROCKNIX asymmetric CPU compatibility"

grep -q 'decompressobj(16 + zlib.MAX_WBITS)' "${repacker}" ||
  fail "on-device boot repacker does not parse the gzip/DTB boundary"

grep -q 'decompressobj(16 + zlib.MAX_WBITS)' "${boot_check}" ||
  fail "on-device boot checker does not parse the gzip/DTB boundary"

printf 'thorch kernel DTB layout checks passed\n'
