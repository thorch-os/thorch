#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/plasmashellrc"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

panel_thickness() {
  local config="$1"

  awk '
    /^\[/ { section = $0 }
    section == "[PlasmaViews][Panel 3][Defaults]" && /^thickness=/ {
      sub(/^thickness=/, "")
      print
      exit
    }
  ' "${config}"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

[[ "$(panel_thickness "${defaults}")" == 44 ]] ||
  fail "desktop panel is not touch-sized by default"

fake_root="${tmp}/root"
legacy="${fake_root}/home/legacy/.config/plasmashellrc"
custom="${fake_root}/home/custom/.config/plasmashellrc"
other_panel="${fake_root}/home/other/.config/plasmashellrc"
mkdir -p "$(dirname "${legacy}")" "$(dirname "${custom}")" "$(dirname "${other_panel}")"

cat >"${legacy}" <<'EOF'
[PlasmaViews][Panel 3]
floating=0

[PlasmaViews][Panel 3][Defaults]
thickness=18

[Unrelated]
keep=user-choice
EOF

cat >"${custom}" <<'EOF'
[PlasmaViews][Panel 3][Defaults]
thickness=32
EOF

cat >"${other_panel}" <<'EOF'
[PlasmaViews][Panel 23][Defaults]
thickness=18
EOF

chmod 0640 "${legacy}" "${custom}" "${other_panel}"

THORCH_INSTALL_ROOT="${fake_root}" \
THORCH_HOME_ROOT="${fake_root}/home" \
  bash -c '
    vercmp() {
      if [[ "$1" == "$2" ]]; then
        printf "0\n"
      else
        printf -- "-1\n"
      fi
    }
    source "$1"
    post_upgrade "1-32" "1-31"
  ' _ "${install_script}"

[[ "$(panel_thickness "${legacy}")" == 44 ]] ||
  fail "upgrade did not enlarge the exact legacy desktop panel default"
grep -Fqx 'keep=user-choice' "${legacy}" ||
  fail "upgrade discarded an unrelated Plasma setting"
[[ "$(file_mode "${legacy}")" == 640 ]] ||
  fail "upgrade did not preserve plasmashellrc permissions"
[[ "$(panel_thickness "${custom}")" == 32 ]] ||
  fail "upgrade overwrote a custom desktop panel size"
grep -Fqx 'thickness=18' "${other_panel}" ||
  fail "upgrade changed another panel"

current="${fake_root}/home/current/.config/plasmashellrc"
mkdir -p "$(dirname "${current}")"
cat >"${current}" <<'EOF'
[PlasmaViews][Panel 3][Defaults]
thickness=18
EOF

THORCH_INSTALL_ROOT="${fake_root}" \
THORCH_HOME_ROOT="${fake_root}/home" \
  bash -c '
    vercmp() { printf "0\n"; }
    source "$1"
    upgrade_legacy_desktop_panel_thickness "1-32"
  ' _ "${install_script}"

[[ "$(panel_thickness "${current}")" == 18 ]] ||
  fail "current-package upgrade rewrote a later user choice"

printf 'thorch Plasma panel default checks passed\n'
