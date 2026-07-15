#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_pkgbuild="${root}/packages/linux-thorch/PKGBUILD"
firmware_pkgbuild="${root}/packages/thorch-firmware-rocknix/PKGBUILD"
image_builder="${root}/scripts/build-image.sh"
package_builder="${root}/scripts/build-packages.sh"
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
for package in "${stock_firmware[@]}"; do
  for field in provides conflicts replaces; do
    field_value="$(bash -c 'source "$1"; declare -p "$2"' _ "${firmware_pkgbuild}" "${field}")"
    grep -Eq "(^|[=\" ])${package}([\" ]|$)" <<< "${field_value}" || \
      fail "thorch-firmware-rocknix ${field} is missing ${package}"
  done
done
grep -Eq 'makedepends=.*patchelf.*python' <<< "${firmware_metadata}" || \
  fail "firmware package does not declare its ICD rewrite tool"

! grep -Eq '"\$\{pkgdir\}/usr/lib/libvulkan_freedreno\.so"|"\$\{pkgdir\}/usr/lib/libdisplay-info' \
  "${firmware_pkgbuild}" || fail "firmware package still writes system-owned library paths"
grep -Eq '/usr/lib/thorch/freedreno/libvulkan_freedreno\.so' "${firmware_pkgbuild}" || \
  fail "firmware package does not use a private Vulkan driver path"
grep -Eq '/usr/lib/thorch/freedreno/libdisplay-info\.so\.0\.2\.0' "${firmware_pkgbuild}" || \
  fail "firmware package does not keep its compatibility library private"
grep -Fq "patchelf --set-rpath '\$ORIGIN'" "${firmware_pkgbuild}" || \
  fail "private Vulkan driver does not resolve its matching compatibility library"
grep -Eq 'thorch_freedreno_icd\.json' "${firmware_pkgbuild}" || \
  fail "firmware package does not use a uniquely owned ICD manifest"

! grep -Eq -- '-Rdd|--overwrite|pacman[[:space:]]+-U' \
  "${image_builder}" "${package_builder}" ||
  fail "normal image/package composition still uses a conflict bypass"
grep -q 'stage_image_repository' "${image_builder}" ||
  fail "image composition does not stage the local pacman repository"
grep -q 'pacman --config /etc/pacman-thorch-build.conf -Syu' "${image_builder}" ||
  fail "image composition does not use a full repository transaction"
grep -q 'configure_pacman_for_emulated_build "${pacman_build_conf}"' "${image_builder}" ||
  fail "image composition does not isolate emulation-only pacman settings"
grep -q '^unstage_image_repository$' "${image_builder}" ||
  fail "image composition does not remove its temporary repository configuration"
alarm_pacman_body="$(awk '
  /^configure_alarm_pacman\(\)/ {printing=1}
  printing {print}
  printing && /^}/ {exit}
' "${common}")"
! grep -Eq 'DisableSandbox|CheckSpace' <<< "${alarm_pacman_body}" ||
  fail "normal image pacman configuration still receives build-only settings"
grep -q 'configure_pacman_for_emulated_build "${base_root}/etc/pacman.conf"' "${package_builder}" ||
  fail "package builds do not scope their emulation-only pacman exception"
grep -q 'extract_alarm_rootfs ' "${image_builder}" ||
  fail "image composition does not extract a coherent ALARM rootfs"
grep -q 'bsdtar -xpf "${rootfs_tar}" -C "${dest}"$' "${common}" ||
  fail "ALARM extraction still removes package-owned files or database entries"
! grep -q 'extract_alarm_rootfs_without_stock_kernel_firmware' \
  "${common}" "${image_builder}" "${package_builder}" ||
  fail "legacy package-database surgery is still reachable"
! grep -q 'rm -f "${rootfs_dir}/etc/mkinitcpio.d/linux-aarch64.preset"' "${image_builder}" ||
  fail "image composition still conceals stock-kernel ownership metadata errors"
grep -q 'archive-package-repo.sh' "${package_builder}" ||
  fail "package builds discard the previous local repository bytes before pruning"
grep -q -- '--candidate "${pkgfile}"' "${package_builder}" ||
  fail "package builds can replace an existing pacman identity with different bytes"
grep -q 'SHA256SUMS' "${root}/scripts/archive-package-repo.sh" ||
  fail "retained local repository bytes are not integrity-recorded"

printf 'thorch package upgrade metadata checks passed\n'
