#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_builder="${root}/scripts/build-image.sh"
bsp_preset="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-preset/80-thorch.preset"
bsp_install="${root}/packages/thorch-bsp/thorch-bsp.install"
bsp_pkgbuild="${root}/packages/thorch-bsp/PKGBUILD"
bsp_sudoers="${root}/packages/thorch-bsp/payload/etc/sudoers.d/20-thorch-wheel"
bsp_mkinitcpio="${root}/packages/thorch-bsp/payload/etc/mkinitcpio.conf.d/90-thorch.conf"
desktop_preset="${root}/packages/thorch-kde-defaults/payload/usr/lib/systemd/system-preset/80-thorch-desktop.preset"
user_preset="${root}/packages/thorch-kde-defaults/payload/usr/lib/systemd/user-preset/80-thorch-desktop.preset"
input_preset="${root}/packages/thorch-inputplumber/payload/usr/lib/systemd/system-preset/80-thorch-input.preset"
fex_preset="${root}/packages/thorch-fex-bin/payload/usr/lib/systemd/system-preset/80-thorch-fex.preset"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for specification in \
  "${bsp_preset}:thorch-boot-confirm.service" \
  "${bsp_preset}:thorch-debug-report.service" \
  "${bsp_preset}:thorch-fancontrol.service" \
  "${bsp_preset}:thorch-hw-defaults.service" \
  "${bsp_preset}:thorch-inputd.service" \
  "${bsp_preset}:thorch-rgb.service" \
  "${desktop_preset}:NetworkManager.service" \
  "${desktop_preset}:sddm.service" \
  "${desktop_preset}:thorch-session-recovery.service" \
  "${desktop_preset}:thorch-touchscreen-setup.service" \
  "${user_preset}:thorch-audio-init.service" \
  "${input_preset}:inputplumber.service" \
  "${fex_preset}:systemd-binfmt.service"; do
  preset="${specification%%:*}"
  service="${specification#*:}"
  grep -qx "enable ${service}" "${preset}" ||
    fail "$(basename "${preset}") does not own the ${service} default"
done

for unit in \
  systemd-networkd.service \
  systemd-networkd-wait-online.service \
  systemd-networkd.socket \
  systemd-networkd-varlink.socket \
  systemd-networkd-varlink-metrics.socket \
  systemd-networkd-resolve-hook.socket; do
  grep -qx "disable ${unit}" "${bsp_preset}" ||
    fail "$(basename "${bsp_preset}") does not disable ${unit}"
done
grep -q '^configure_network_policy()' "${bsp_install}" ||
  fail "BSP upgrade migration does not maintain the NetworkManager-only policy"
grep -q '%wheel ALL=(ALL:ALL) ALL' "${bsp_sudoers}" ||
  fail "BSP does not own the wheel sudo policy"
grep -q 'etc/sudoers.d/20-thorch-wheel' "${bsp_pkgbuild}" ||
  fail "administrator sudo policy is not declared as package backup configuration"
grep -q '^migrate_legacy_sudoers()' "${bsp_install}" ||
  fail "BSP does not migrate the formerly image-owned sudo policy"
grep -q 'etc/mkinitcpio.conf.d/90-thorch.conf' "${bsp_pkgbuild}" ||
  fail "administrator mkinitcpio policy is not declared as package backup configuration"
grep -q 'thorch-sd-prefer' "${bsp_mkinitcpio}" ||
  fail "BSP mkinitcpio policy does not own the Thorch root-selection hook"

sudo_migration="$(mktemp -d)"
trap 'rm -rf "${sudo_migration}"' EXIT
install -d "${sudo_migration}/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > \
  "${sudo_migration}/etc/sudoers.d/10-thorch-wheel"
THORCH_INSTALL_ROOT="${sudo_migration}" bash -c \
  'source "$1"; migrate_legacy_sudoers' _ "${bsp_install}"
[[ ! -e "${sudo_migration}/etc/sudoers.d/10-thorch-wheel" ]] ||
  fail "exact legacy image sudo policy was not migrated"
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > \
  "${sudo_migration}/etc/sudoers.d/10-thorch-wheel"
THORCH_INSTALL_ROOT="${sudo_migration}" bash -c \
  'source "$1"; migrate_legacy_sudoers' _ "${bsp_install}" 2>/dev/null
grep -q 'NOPASSWD' "${sudo_migration}/etc/sudoers.d/10-thorch-wheel" ||
  fail "modified administrator sudo policy was not preserved"

grep -q 'systemctl --root "${rootfs_dir}" preset-all' "${image_builder}" ||
  fail "image composition does not apply packaged system presets"
grep -q 'systemctl --root "${rootfs_dir}" --global preset-all' "${image_builder}" ||
  fail "image composition does not apply packaged user presets"
! grep -q 'rootfs_services=' "${image_builder}" ||
  fail "image composition still duplicates the package service inventory"
! grep -Eq 'systemctl --root .* enable ' "${image_builder}" ||
  fail "image composition directly enables updateable package services"
! grep -Eq 'systemctl (disable|mask) systemd-networkd' "${image_builder}" ||
  fail "image composition still embeds the package-owned network policy"
! grep -q 'etc/sudoers.d/10-thorch-wheel' "${image_builder}" ||
  fail "image composition still writes package-owned sudo policy"
! grep -q 'prepare_mkinitcpio_config' "${image_builder}" ||
  fail "image composition still rewrites package-owned mkinitcpio policy"

printf 'thorch package-owned service preset checks passed\n'
