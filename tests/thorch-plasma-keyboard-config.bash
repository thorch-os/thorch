#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desktop="${root}/packages/thorch-kde-defaults/payload/usr/share/applications/thorch-plasma-keyboard.desktop"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q '^Exec=env PLASMA_KEYBOARD_OUTPUT=DSI-1 ' "${desktop}" ||
  fail "virtual keyboard is not pinned to the bottom DSI-1 output"

layout="${root}/packages/plasma-keyboard/layouts/main.qml"
grep -q '^KeyboardLayoutLoader {' "${layout}" ||
  fail "keyboard layout does not use Qt Virtual Keyboard's multi-page extension point"
grep -q 'Qt.Key_F12' "${layout}" || fail "keyboard layout is missing function keys"
grep -q 'Qt.Key_Tab' "${layout}" || fail "keyboard layout is missing Tab"
grep -q 'Qt.ControlModifier' "${layout}" || fail "keyboard layout is missing Ctrl"
grep -q 'id: navigationLayout' "${layout}" || fail "keyboard layout is missing its navigation/numpad page"

printf 'thorch Plasma keyboard config checks passed\n'
