#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${root}/packages/thorch-bsp/payload/usr/lib/initcpio/install/thorch-firmware"
firmware_package="${root}/packages/thorch-firmware-rocknix/PKGBUILD"
build_docs="${root}/docs/build.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

hook_build="$(sed -n '/^build()/,/^}/p' "${hook}")"

for firmware in \
  qcom/a740_sqe.fw \
  qcom/gmu_gen70200.bin \
  qcom/sm8550/a740_zap.mbn; do
  ! grep -Fq "/usr/lib/firmware/${firmware}" <<<"${hook_build}" ||
    fail "GPU firmware ${firmware} is still copied into the initramfs"
  grep -Fq "${firmware}" "${firmware_package}" ||
    fail "GPU firmware ${firmware} is missing from the root filesystem package"
done

for firmware in \
  qcom/sm8550/ayn/cdsp.mbn \
  qcom/sm8550/ayn/cdsp_dtb.mbn \
  renesas_usb_fw.mem; do
  grep -Fq "/usr/lib/firmware/${firmware}" <<<"${hook_build}" ||
    fail "required early-boot firmware ${firmware} is missing from the initramfs hook"
done

grep -q 'matching ROCKNIX and keeping' "${build_docs}" ||
  fail "build documentation does not explain why GPU firmware is root-only"

printf 'thorch initramfs firmware checks passed\n'
