#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desktop="${root}/packages/thorch-kde-defaults/payload/usr/share/applications/thorch-plasma-keyboard.desktop"
kwinrc="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/kwinrc"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q '^Exec=env PLASMA_KEYBOARD_OUTPUT=DSI-1 ' "${desktop}" ||
  fail "virtual keyboard is missing its DSI-1 output fallback"
grep -q '^InputPanelPlacement=Auto$' "${kwinrc}" ||
  fail "virtual keyboard placement does not default to Auto"
grep -q '^VirtualKeyboardMode=2$' "${kwinrc}" ||
  fail "virtual keyboard does not accept mouse-triggered activation by default"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${desktop}" ||
    fail "virtual keyboard desktop entry is invalid"
fi

printf 'thorch Plasma keyboard integration config checks passed\n'
