#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_pkgbuild="${root}/packages/linux-thorch/PKGBUILD"
firmware_pkgbuild="${root}/packages/thorch-firmware-rocknix/PKGBUILD"
common="${root}/scripts/lib/common.sh"
bsp_pkgbuild="${root}/packages/thorch-bsp/PKGBUILD"
marker_pkgbuild="${root}/packages/thorch-boot-bootstrap-ready/PKGBUILD"
bootstrap_protocol="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot-bootstrap-protocol"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${bootstrap_protocol}"
# shellcheck source=../scripts/lib/common.sh
source "${common}"

linux_metadata="$(
  bash -c 'source "$1"; declare -p depends makedepends provides conflicts replaces' \
    _ "${linux_pkgbuild}"
)"
grep -q 'linux-aarch64=' <<< "${linux_metadata}" || \
  fail "linux-thorch does not provide versioned linux-aarch64"
grep -q 'declare -a conflicts=.*linux-aarch64' <<< "${linux_metadata}" || \
  fail "linux-thorch does not conflict with linux-aarch64"
grep -q 'declare -a replaces=.*linux-aarch64' <<< "${linux_metadata}" || \
  fail "linux-thorch does not replace linux-aarch64"
grep -Fq "${THORCH_BOOTSTRAP_MARKER_REQUIREMENT}" <<< "${linux_metadata}" || \
  fail "linux-thorch does not require the activated bootstrap marker"
grep -Fq "${THORCH_BOOTSTRAP_BSP_REQUIREMENT}" <<< "${linux_metadata}" || \
  fail "linux-thorch does not keep its transaction-hook BSP installed"
! grep -Eq 'makedepends=.*thorch-bsp' <<< "${linux_metadata}" || \
  fail "linux-thorch incorrectly treats its boot transaction runtime as build-only"

bsp_metadata="$(bash -c 'source "$1"; declare -p depends' _ "${bsp_pkgbuild}")"
grep -Eq 'depends=.*diffutils' <<< "${bsp_metadata}" || \
  fail "thorch-bsp does not declare the diff command used by boot transactions"
marker_metadata="$(
  bash -c 'source "$1"; declare -p pkgver pkgrel depends' _ "${marker_pkgbuild}"
)"
grep -Fq "${THORCH_BOOTSTRAP_BSP_REQUIREMENT}" <<< "${marker_metadata}" || \
  fail "the bootstrap marker does not keep the activated BSP installed"
grep -Fq "pkgver=\"${THORCH_BOOTSTRAP_MARKER_PKGVER}\"" <<< "${marker_metadata}" || \
  fail "the bootstrap marker pkgver differs from the shared protocol"
grep -Fq "pkgrel=\"${THORCH_BOOTSTRAP_MARKER_PKGREL}\"" <<< "${marker_metadata}" || \
  fail "the bootstrap marker pkgrel differs from the shared protocol"
grep -Fq 'source "${protocol}"' \
  "${root}/packages/thorch-bsp/payload/usr/lib/thorch/create-bootstrap-ready-package" || \
  fail "the locally generated marker does not use the shared protocol"
grep -Fq 'pacman -T "${THORCH_BOOTSTRAP_MARKER_REQUIREMENT}"' \
  "${root}/packages/thorch-bsp/payload/usr/bin/thorch-update-bootstrap" || \
  fail "bootstrap updater accepts a marker by name without checking its version"

firmware_metadata="$(
  bash -c 'source "$1"; declare -p depends makedepends provides conflicts replaces' \
    _ "${firmware_pkgbuild}"
)"
stock_firmware=(
  linux-firmware
  linux-firmware-amdgpu
  linux-firmware-atheros
  linux-firmware-broadcom
  linux-firmware-cirrus
  linux-firmware-intel
  linux-firmware-liquidio
  linux-firmware-marvell
  linux-firmware-mediatek
  linux-firmware-mellanox
  linux-firmware-nfp
  linux-firmware-nvidia
  linux-firmware-other
  linux-firmware-qcom
  linux-firmware-qlogic
  linux-firmware-radeon
  linux-firmware-realtek
  linux-firmware-whence
)
build_stock_firmware=()
while IFS= read -r package; do
  build_stock_firmware+=("${package}")
done < <(thorch_stock_firmware_packages)
[[ "$(printf '%s\n' "${stock_firmware[@]}")" == "$(printf '%s\n' "${build_stock_firmware[@]}")" ]] ||
  fail "package build stock firmware list differs from the replacement metadata"
for package in "${stock_firmware[@]}"; do
  for field in provides conflicts replaces; do
    field_value="$(bash -c 'source "$1"; declare -p "$2"' _ "${firmware_pkgbuild}" "${field}")"
    grep -Eq "(^|[=\" ])${package}([\" ]|$)" <<< "${field_value}" || \
      fail "thorch-firmware-rocknix ${field} is missing ${package}"
  done
done
grep -Eq 'makedepends=.*patchelf.*python' <<< "${firmware_metadata}" || \
  fail "firmware package does not declare its ICD rewrite tool"

printf 'thorch package upgrade metadata checks passed\n'
