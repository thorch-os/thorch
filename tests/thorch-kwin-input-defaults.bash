#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/kwinrc"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

ini_value() {
  local file="$1"
  local wanted_group="$2"
  local wanted_key="$3"

  awk -F= -v wanted_group="${wanted_group}" -v wanted_key="${wanted_key}" '
    /^\[[^]]+\]$/ {
      group = $0
      next
    }
    group == wanted_group && $1 == wanted_key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "${file}"
}

[[ "$(ini_value "${defaults}" '[Plugins]' gamecontrollerEnabled)" == true ]] ||
  fail "game-controller pointer and keyboard navigation is not enabled by default"
[[ "$(ini_value "${defaults}" '[TouchEdges]' Right)" == KRunner ]] ||
  fail "right-edge touchscreen swipe does not open KRunner"
[[ "$(ini_value "${defaults}" '[Effect-overview]' TouchBorderActivate)" == 6 ]] ||
  fail "left-edge touchscreen swipe does not open Overview"

fake_root="${tmp}/root"
unset_config="${fake_root}/home/unset/.config/kwinrc"
custom_config="${fake_root}/home/custom/.config/kwinrc"
effect_config="${fake_root}/home/effect/.config/kwinrc"
mkdir -p "$(dirname "${unset_config}")" "$(dirname "${custom_config}")" "$(dirname "${effect_config}")"

cat >"${unset_config}" <<'EOF'
[Wayland]
VirtualKeyboardEnabled=true
EOF

cat >"${custom_config}" <<'EOF'
[Plugins]
gamecontrollerEnabled=false

[TouchEdges]
Left=LockScreen
EOF

cat >"${effect_config}" <<'EOF'
[Effect-overview]
TouchBorderActivate=2
EOF

chmod 0640 "${unset_config}" "${custom_config}" "${effect_config}"

THORCH_INSTALL_ROOT="${fake_root}" \
THORCH_HOME_ROOT="${fake_root}/home" \
  bash -c 'source "$1"; post_upgrade' _ "${install_script}"

[[ "$(ini_value "${unset_config}" '[Plugins]' gamecontrollerEnabled)" == true ]] ||
  fail "upgrade did not enable game-controller navigation when unset"
[[ "$(ini_value "${unset_config}" '[TouchEdges]' Right)" == KRunner ]] ||
  fail "upgrade did not add the right-edge KRunner gesture when gestures were unset"
[[ "$(ini_value "${unset_config}" '[Effect-overview]' TouchBorderActivate)" == 6 ]] ||
  fail "upgrade did not add the left-edge Overview gesture when gestures were unset"

[[ "$(ini_value "${custom_config}" '[Plugins]' gamecontrollerEnabled)" == false ]] ||
  fail "upgrade overwrote an explicit game-controller setting"
[[ "$(ini_value "${custom_config}" '[TouchEdges]' Left)" == LockScreen ]] ||
  fail "upgrade overwrote a custom touchscreen gesture"
[[ -z "$(ini_value "${custom_config}" '[TouchEdges]' Right)" ]] ||
  fail "upgrade added a default alongside custom touchscreen gestures"
[[ -z "$(ini_value "${custom_config}" '[Effect-overview]' TouchBorderActivate)" ]] ||
  fail "upgrade added Overview alongside custom touchscreen gestures"

[[ "$(ini_value "${effect_config}" '[Plugins]' gamecontrollerEnabled)" == true ]] ||
  fail "upgrade did not independently add the game-controller default"
[[ "$(ini_value "${effect_config}" '[Effect-overview]' TouchBorderActivate)" == 2 ]] ||
  fail "upgrade overwrote an existing effect gesture"
[[ -z "$(ini_value "${effect_config}" '[TouchEdges]' Right)" ]] ||
  fail "upgrade added a default alongside an existing effect gesture"

[[ "$(file_mode "${unset_config}")" == 640 ]] ||
  fail "upgrade did not preserve kwinrc mode"

printf 'thorch KWin input defaults checks passed\n'
