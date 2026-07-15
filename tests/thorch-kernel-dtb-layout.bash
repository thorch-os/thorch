#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="${root}/scripts/build-thorch-kernel.sh"
validator="${root}/scripts/check-thorch-image.sh"
syncer="${root}/scripts/sync-rocknix-kernel.sh"
importer="${root}/scripts/import-rocknix-kernel.sh"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
boot_check="${root}/packages/thorch-bsp/payload/usr/bin/thorch-check-boot"
boot_tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"
kernel_pkgbuild="${root}/packages/linux-thorch/PKGBUILD"
manifest_cli="${root}/scripts/package-manifest.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'find "${dts_abs}/qcom"' "${builder}" ||
  fail "kernel builder does not derive its DTB manifest from ROCKNIX overlays"

grep -q 'DTC_FLAGS=-@ Image "${dtb_targets\[@\]}" modules' "${builder}" ||
  fail "kernel builder does not preserve ROCKNIX DTB overlay symbols"

grep -q '"${boot_tool}" replace-kernel' "${builder}" ||
  fail "kernel builder does not use the canonical boot-image repacker"

grep -q '"${dtb_paths\[@\]}"' "${builder}" ||
  fail "Android boot image is not packed from the explicit ROCKNIX DTB manifest"

grep -q 'rm -rf "${dest_abs}/usr/lib/modules" "${dest_abs}/boot/dtb/qcom"' "${builder}" ||
  fail "kernel builder does not remove stale DTBs from the artifact directory"

! grep -q 'dtb_dir.glob("qcs8550-\*\.dtb")' "${builder}" ||
  fail "kernel builder can still package stale or generic qcs8550 DTBs"

[[ -f "${boot_tool}" ]] || fail "canonical boot-image parser is missing"
grep -q 'decompressobj(16 + zlib.MAX_WBITS)' "${boot_tool}" ||
  fail "canonical boot-image parser does not parse the gzip/DTB boundary"
grep -q 'DTB without ROCKNIX overlay symbols' "${boot_tool}" ||
  fail "canonical boot-image validator does not reject symbol-less DTBs"
grep -q 'generic AIM300 DTB' "${boot_tool}" ||
  fail "canonical boot-image validator does not reject the generic AIM300 DTB"
grep -q 'ROCKNIX Thor DTBs, expected 1' "${boot_tool}" ||
  fail "canonical boot-image validator does not require exactly one Thor DTB"

grep -q '/usr/lib/thorch/boot_image.py check-config' "${kernel_pkgbuild}" ||
  fail "linux-thorch does not use the packaged canonical kernel-config parser"
grep -q "depends=.*thorch-bsp" "${kernel_pkgbuild}" ||
  fail "linux-thorch does not declare the BSP boot tool as a runtime dependency"
! grep -Eq 'IKCFG_ST|import gzip|config_text = gzip' "${kernel_pkgbuild}" ||
  fail "linux-thorch still embeds a private IKCONFIG parser"
bsp_order="$(python3 "${manifest_cli}" --repo "${root}" profile build | grep -n '^thorch-bsp$' | cut -d: -f1)"
kernel_order="$(python3 "${manifest_cli}" --repo "${root}" profile build | grep -n '^linux-thorch$' | cut -d: -f1)"
[[ -n "${bsp_order}" && -n "${kernel_order}" && "${bsp_order}" -lt "${kernel_order}" ]] ||
  fail "package manifest does not build the BSP before linux-thorch"

callers=("${builder}" "${validator}" "${syncer}" "${importer}" "${repacker}" "${boot_check}")
for caller in "${callers[@]}"; do
  grep -q 'boot_image.py' "${caller}" ||
    fail "$(basename "${caller}") does not use the canonical boot-image module"
  ! grep -Eq 'decompressobj|ANDROID_MAGIC|b["'\'' ]ANDROID!' "${caller}" ||
    fail "$(basename "${caller}") still embeds a private Android boot parser"
done

for caller in "${validator}" "${repacker}" "${boot_check}"; do
  grep -q -- '--require-symbols' "${caller}" ||
    fail "$(basename "${caller}") does not require overlay symbols"
  grep -q -- '--require-thor' "${caller}" ||
    fail "$(basename "${caller}") does not require the Thor DTB"
  grep -q -- '--forbid-aim300' "${caller}" ||
    fail "$(basename "${caller}") does not reject the generic AIM300 DTB"
  grep -q 'allow_mismatched_32bit_el0' "${caller}" ||
    fail "$(basename "${caller}") drops ROCKNIX asymmetric CPU compatibility"
done

printf 'thorch kernel DTB layout checks passed\n'
