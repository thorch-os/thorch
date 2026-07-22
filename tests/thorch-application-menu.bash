#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kde_payload="${root}/packages/thorch-kde-defaults/payload"
gaming_payload="${root}/packages/thorch-gaming-installers/payload"
desktop_layout="${kde_payload}/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

desktop_value() {
  local file="$1" key="$2"
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${file}"
}

for name in thorch-display-setup.desktop thorch-switch-to-desktop.desktop thorch-switch-to-mobile.desktop; do
  [[ ! -e "${kde_payload}/etc/skel/Desktop/${name}" ]] ||
    fail "${name} is still copied to new users' desktops"
  [[ -f "${kde_payload}/usr/share/applications/${name}" ]] ||
    fail "${name} is missing from the application menu"
done

[[ ! -e "${gaming_payload}/etc/skel/Desktop/thorch-switch-to-steamos.desktop" ]] ||
  fail "SteamOS mode is still copied to new users' desktops"
[[ -f "${gaming_payload}/usr/share/applications/thorch-switch-to-steamos.desktop" ]] ||
  fail "SteamOS mode is missing from the application menu"
if grep -Fq 'desktop:/thorch-' "${desktop_layout}"; then
  fail "default Plasma screen mappings still reference removed desktop shortcuts"
fi

gaming_installer="${gaming_payload}/usr/share/applications/thorch-install-gaming-stack.desktop"
[[ "$(desktop_value "${gaming_installer}" Name)" == 'Install Gaming Stack' ]] ||
  fail "gaming stack menu entry has the wrong name"
[[ "$(desktop_value "${gaming_installer}" Exec)" == 'thorch-install-gaming-stack' ]] ||
  fail "gaming stack menu entry does not launch the installer"
[[ "$(desktop_value "${gaming_installer}" Terminal)" == true ]] ||
  fail "gaming stack installer does not open an interactive terminal"
[[ "$(desktop_value "${gaming_installer}" Categories)" == 'Game;' ]] ||
  fail "gaming stack installer is not in the Gaming menu"

for name in thorch-steamos-mode.desktop thorch-steamos-mode-enable.desktop thorch-steamos-mode-disable.desktop thorch-steamos-mode-stop.desktop; do
  launcher="${gaming_payload}/usr/share/applications/${name}"
  [[ "$(desktop_value "${launcher}" Categories)" == 'Game;' ]] ||
    fail "${name} declares more than one main application-menu category"
done

fake_root="${tmp}/root"
legacy_home="${fake_root}/home/legacy"
custom_home="${fake_root}/home/custom"
mkdir -p "${fake_root}/usr/share/applications" "${legacy_home}/Desktop" "${custom_home}/Desktop"

for source in \
  "${kde_payload}/usr/share/applications/thorch-display-setup.desktop" \
  "${kde_payload}/usr/share/applications/thorch-switch-to-desktop.desktop" \
  "${kde_payload}/usr/share/applications/thorch-switch-to-mobile.desktop" \
  "${gaming_payload}/usr/share/applications/thorch-switch-to-steamos.desktop"; do
  name="${source##*/}"
  cp "${source}" "${fake_root}/usr/share/applications/${name}"
  cp "${source}" "${legacy_home}/Desktop/${name}"
  cp "${source}" "${custom_home}/Desktop/${name}"
  printf 'X-User-Keep=true\n' >>"${custom_home}/Desktop/${name}"
done

THORCH_INSTALL_ROOT="${fake_root}" \
THORCH_HOME_ROOT="${fake_root}/home" \
  bash -c '
    vercmp() { printf -- "-1\n"; }
    source "$1"
    remove_legacy_desktop_launchers "1-31"
  ' _ "${install_script}"

for name in thorch-display-setup.desktop thorch-switch-to-desktop.desktop thorch-switch-to-mobile.desktop thorch-switch-to-steamos.desktop; do
  [[ ! -e "${legacy_home}/Desktop/${name}" ]] ||
    fail "upgrade retained the unmodified vendor shortcut ${name}"
  [[ -e "${custom_home}/Desktop/${name}" ]] ||
    fail "upgrade removed the customized shortcut ${name}"
done

printf 'thorch application menu checks passed\n'
