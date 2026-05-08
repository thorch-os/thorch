#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source="${root}/packages/thorch-bsp/inputd/thorch-inputd.rs"
tmp="$(mktemp -d)"
daemon_pid=""
trap '[[ -z "${daemon_pid}" ]] || kill "${daemon_pid}" 2>/dev/null || true; rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if ! command -v rustc >/dev/null 2>&1; then
  printf 'SKIP: rustc not available\n'
  exit 0
fi

script="${tmp}/thorch-inputd"
rustc "${source}" --edition=2021 -C opt-level=0 -o "${script}"

mkdir -p "${tmp}/sys/class/input" "${tmp}/dev/input"

cat > "${tmp}/backlight" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "$1" "$2" "$3" >> "${THORCH_FAKE_BACKLIGHT_LOG:?}"
EOF
chmod 755 "${tmp}/backlight"

cat > "${tmp}/rgb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${THORCH_FAKE_RGB_LOG:?}"
EOF
chmod 755 "${tmp}/rgb"

cat > "${tmp}/nmcli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nmcli %s\n' "$*" >> "${THORCH_FAKE_WIFI_LOG:?}"
EOF
chmod 755 "${tmp}/nmcli"

cat > "${tmp}/rfkill" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rfkill %s\n' "$*" >> "${THORCH_FAKE_WIFI_LOG:?}"
EOF
chmod 755 "${tmp}/rfkill"

cat > "${tmp}/volume" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'volume %s\n' "$*" >> "${THORCH_FAKE_VOLUME_LOG:?}"
EOF
chmod 755 "${tmp}/volume"

for command in screenshot mangohud screen-switch game-guide; do
  cat > "${tmp}/${command}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "${THORCH_FAKE_HOTKEY_LOG:?}"
EOF
  chmod 755 "${tmp}/${command}"
done

cat > "${tmp}/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'killall %s\n' "$*" >> "${THORCH_FAKE_HOTKEY_LOG:?}"
EOF
chmod 755 "${tmp}/killall"
printf 'fake-game\n' > "${tmp}/kill-data"

PATH="${tmp}:${PATH}" \
THORCH_INPUTD_INPUT_ROOT="${tmp}/sys/class/input" \
THORCH_INPUTD_EVENT_ROOT="${tmp}/dev/input" \
THORCH_INPUTD_BACKLIGHT="${tmp}/backlight" \
THORCH_INPUTD_RGB="${tmp}/rgb" \
THORCH_INPUTD_NMCLI="${tmp}/nmcli" \
THORCH_INPUTD_RFKILL="${tmp}/rfkill" \
THORCH_INPUTD_VOLUME="${tmp}/volume" \
THORCH_INPUTD_SCREENSHOT="${tmp}/screenshot" \
THORCH_INPUTD_MANGOHUD="${tmp}/mangohud" \
THORCH_INPUTD_SCREEN_SWITCH="${tmp}/screen-switch" \
THORCH_INPUTD_GAME_GUIDE="${tmp}/game-guide" \
THORCH_INPUTD_KILL_DATA="${tmp}/kill-data" \
THORCH_INPUTD_BRIGHTNESS_STEP_PERCENT=7 \
THORCH_INPUTD_REPEAT_SECONDS=0 \
THORCH_FAKE_BACKLIGHT_LOG="${tmp}/backlight.log" \
THORCH_FAKE_RGB_LOG="${tmp}/rgb.log" \
THORCH_FAKE_WIFI_LOG="${tmp}/wifi.log" \
THORCH_FAKE_VOLUME_LOG="${tmp}/volume.log" \
THORCH_FAKE_HOTKEY_LOG="${tmp}/hotkey.log" \
  "${script}" &
daemon_pid="$!"

mkdir -p "${tmp}/staged-event0/device"
printf 'AYN Odin2 Gamepad\n' > "${tmp}/staged-event0/device/name"
mkfifo "${tmp}/dev/input/event0"
mv "${tmp}/staged-event0" "${tmp}/sys/class/input/event0"

EVENT_FIFO="${tmp}/dev/input/event0" python3 - <<'PY'
import os
import struct

EV_KEY = 1
KEY_VOLUMEUP = 115
KEY_VOLUMEDOWN = 114
BTN_START = 315
BTN_MODE = 316
BTN_TL = 310
BTN_SELECT = 314
BTN_EAST = 305
BTN_NORTH = 307
BTN_WEST = 308
BTN_BACK = 278
BTN_DPAD_UP = 544
BTN_DPAD_DOWN = 545
BTN_DPAD_LEFT = 546
BTN_DPAD_RIGHT = 547

events = [
    (EV_KEY, BTN_MODE, 1),
    (EV_KEY, KEY_VOLUMEUP, 1),
    (EV_KEY, KEY_VOLUMEDOWN, 1),
    (EV_KEY, BTN_START, 1),
    (EV_KEY, KEY_VOLUMEUP, 1),
    (EV_KEY, KEY_VOLUMEDOWN, 1),
    (EV_KEY, BTN_MODE, 0),
    (EV_KEY, KEY_VOLUMEUP, 1),
    (EV_KEY, KEY_VOLUMEDOWN, 1),
    (EV_KEY, BTN_START, 0),
    (EV_KEY, KEY_VOLUMEUP, 1),
    (EV_KEY, BTN_MODE, 1),
    (EV_KEY, BTN_DPAD_UP, 1),
    (EV_KEY, BTN_DPAD_DOWN, 1),
    (EV_KEY, BTN_DPAD_RIGHT, 1),
    (EV_KEY, BTN_DPAD_LEFT, 1),
    (EV_KEY, BTN_MODE, 0),
    (EV_KEY, BTN_TL, 1),
    (EV_KEY, BTN_EAST, 1),
    (EV_KEY, BTN_WEST, 1),
    (EV_KEY, BTN_BACK, 1),
    (EV_KEY, BTN_NORTH, 1),
    (EV_KEY, BTN_SELECT, 1),
    (EV_KEY, BTN_START, 1),
]

with open(os.environ["EVENT_FIFO"], "wb", buffering=0) as f:
    for etype, code, value in events:
        f.write(struct.pack("llHHi", 0, 0, etype, code, value))
PY

for _ in {1..50}; do
  if [[ -r "${tmp}/backlight.log" ]] && [[ "$(wc -l < "${tmp}/backlight.log")" -ge 2 ]] &&
    [[ -r "${tmp}/rgb.log" ]] && [[ "$(wc -l < "${tmp}/rgb.log")" -ge 2 ]] &&
    [[ -r "${tmp}/wifi.log" ]] && [[ "$(wc -l < "${tmp}/wifi.log")" -ge 4 ]] &&
    [[ -r "${tmp}/volume.log" ]] && [[ "$(wc -l < "${tmp}/volume.log")" -ge 2 ]] &&
    [[ -r "${tmp}/hotkey.log" ]] && [[ "$(wc -l < "${tmp}/hotkey.log")" -ge 5 ]]; then
    break
  fi
  sleep 0.1
done

actual="$(cat "${tmp}/backlight.log" 2>/dev/null || true)"
expected=$'up all 7\ndown all 7\nup all 7\ndown all 7'
[[ "${actual}" == "${expected}" ]] || fail "unexpected backlight calls: ${actual}"

actual="$(cat "${tmp}/rgb.log" 2>/dev/null || true)"
expected=$'battery\noff'
[[ "${actual}" == "${expected}" ]] || fail "unexpected rgb calls: ${actual}"

actual="$(cat "${tmp}/wifi.log" 2>/dev/null || true)"
expected=$'rfkill unblock wifi\nnmcli radio wifi on\nnmcli radio wifi off\nrfkill block wifi'
[[ "${actual}" == "${expected}" ]] || fail "unexpected wifi calls: ${actual}"

actual="$(cat "${tmp}/volume.log" 2>/dev/null || true)"
expected=$'volume set-sink-mute @DEFAULT_SINK@ false\nvolume set-sink-volume @DEFAULT_SINK@ +5%\nvolume set-sink-mute @DEFAULT_SINK@ false\nvolume set-sink-volume @DEFAULT_SINK@ +5%\nvolume set-sink-volume @DEFAULT_SINK@ -5%'
[[ "${actual}" == "${expected}" ]] || fail "unexpected volume calls: ${actual}"

actual="$(cat "${tmp}/hotkey.log" 2>/dev/null || true)"
expected=$'screenshot \nmangohud toggle\nscreen-switch \ngame-guide \nkillall fake-game'
[[ "${actual}" == "${expected}" ]] || fail "unexpected hotkey calls: ${actual}"

printf 'ok\n'
