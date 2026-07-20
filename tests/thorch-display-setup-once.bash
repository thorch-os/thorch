#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
display_setup="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-display-setup"
autostart_template="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/autostart/thorch-display-setup.desktop"
manual_launcher="${root}/packages/thorch-kde-defaults/payload/usr/share/applications/thorch-display-setup.desktop"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
steamos_mode="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-steamos-mode"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fqx 'Exec=/usr/bin/thorch-display-setup --initial' "${autostart_template}" ||
  fail "display setup autostart is not explicitly one-shot"
grep -Fqx 'Exec=/usr/bin/thorch-display-setup' "${manual_launcher}" ||
  fail "manual display reset launcher no longer performs an explicit reset"
if grep -Fq 'thorch-display-setup' "${steamos_mode}"; then
  fail "SteamOS mode still resets the display layout"
fi

mkdir -p "${tmp}/bin" "${tmp}/runtime"
cat >"${tmp}/bin/kscreen-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == -o ]]; then
  printf 'Output: 7 DSI-2 top-panel\n'
  printf 'Output: 9 DSI-1 bottom-panel\n'
  exit 0
fi

printf '%s\n' "$*" >>"${THORCH_TEST_APPLY_LOG}"
if [[ "${THORCH_TEST_APPLY_FAIL:-0}" == 1 ]]; then
  exit 1
fi
EOF
cat >"${tmp}/bin/thorch-kwin-touch-map" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mapped\n' >>"${THORCH_TEST_TOUCH_LOG}"
EOF
chmod +x "${tmp}/bin/kscreen-doctor" "${tmp}/bin/thorch-kwin-touch-map"

run_setup() {
  local home="$1"
  shift
  HOME="${home}" \
    XDG_CONFIG_HOME="${home}/.config" \
    XDG_STATE_HOME="${home}/.local/state" \
    XDG_RUNTIME_DIR="${tmp}/runtime" \
    WAYLAND_DISPLAY=wayland-0 \
    PATH="${tmp}/bin:${PATH}" \
    THORCH_TEST_APPLY_LOG="${home}/apply.log" \
    THORCH_TEST_TOUCH_LOG="${home}/touch.log" \
    "${display_setup}" "$@"
}

initial_home="${tmp}/initial"
mkdir -p "${initial_home}/.config/autostart"
cp "${autostart_template}" "${initial_home}/.config/autostart/thorch-display-setup.desktop"
run_setup "${initial_home}" --initial || fail "successful initial setup returned an error"
[[ -f "${initial_home}/.local/state/thorch/display-layout-v1.complete" ]] ||
  fail "successful initial setup did not record completion"
[[ ! -e "${initial_home}/.config/autostart/thorch-display-setup.desktop" ]] ||
  fail "successful initial setup left its vendor autostart entry behind"
[[ "$(wc -l <"${initial_home}/apply.log")" -eq 1 ]] ||
  fail "initial setup did not apply the layout exactly once"
grep -Fq 'output.7.priority.2' "${initial_home}/apply.log" ||
  fail "initial setup did not configure DSI-2 priority"
grep -Fq 'output.9.priority.1' "${initial_home}/apply.log" ||
  fail "initial setup did not configure DSI-1 priority"

run_setup "${initial_home}" --initial || fail "completed initial setup did not become a no-op"
[[ "$(wc -l <"${initial_home}/apply.log")" -eq 1 ]] ||
  fail "completed initial setup reapplied the display layout"

run_setup "${initial_home}" || fail "manual display reset returned an error"
[[ "$(wc -l <"${initial_home}/apply.log")" -eq 2 ]] ||
  fail "manual display reset did not remain available"

failure_home="${tmp}/failure"
mkdir -p "${failure_home}/.config/autostart"
cp "${autostart_template}" "${failure_home}/.config/autostart/thorch-display-setup.desktop"
if THORCH_TEST_APPLY_FAIL=1 run_setup "${failure_home}" --initial; then
  fail "failed initial setup reported success"
fi
[[ ! -e "${failure_home}/.local/state/thorch/display-layout-v1.complete" ]] ||
  fail "failed initial setup recorded completion"
[[ -e "${failure_home}/.config/autostart/thorch-display-setup.desktop" ]] ||
  fail "failed initial setup removed its retry entry"

legacy_home="${tmp}/homes/legacy/.config/autostart"
custom_home="${tmp}/homes/custom/.config/autostart"
current_home="${tmp}/homes/current/.config/autostart"
mkdir -p "${legacy_home}" "${custom_home}" "${current_home}"
cat >"${legacy_home}/thorch-display-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Thorch Display Setup
Exec=/usr/bin/thorch-display-setup
OnlyShowIn=KDE;
NoDisplay=true
X-KDE-autostart-phase=1
EOF
cp "${legacy_home}/thorch-display-setup.desktop" "${custom_home}/thorch-display-setup.desktop"
printf 'Comment=Keep this customized entry\n' >>"${custom_home}/thorch-display-setup.desktop"
cp "${autostart_template}" "${current_home}/thorch-display-setup.desktop"

THORCH_HOME_ROOT="${tmp}/homes" bash -c \
  'source "$1"; remove_legacy_display_setup_autostart' _ "${install_script}"
[[ ! -e "${legacy_home}/thorch-display-setup.desktop" ]] ||
  fail "upgrade did not remove the exact legacy recurring entry"
[[ -e "${custom_home}/thorch-display-setup.desktop" ]] ||
  fail "upgrade removed a customized display setup entry"
[[ -e "${current_home}/thorch-display-setup.desktop" ]] ||
  fail "upgrade removed the current one-shot entry"

printf 'thorch one-shot display setup checks passed\n'
