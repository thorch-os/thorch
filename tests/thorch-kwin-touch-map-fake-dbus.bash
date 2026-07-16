#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapper="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-kwin-touch-map"
legacy_autostart="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/autostart/thorch-kwin-touch-map.desktop"
package_install="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
udev_rule="${root}/packages/thorch-kde-defaults/payload/usr/lib/udev/rules.d/90-thorch-touchscreen-calibration.rules"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${tmp}/bin" "${tmp}/dev/input" "${tmp}/input" "${tmp}/runtime"
: >"${tmp}/dev/input/event4"
: >"${tmp}/dev/input/event5"
ln -s "${tmp}/dev/input/event4" "${tmp}/input/top"
ln -s "${tmp}/dev/input/event5" "${tmp}/input/bottom"

cat >"${tmp}/bin/qdbus6" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if [[ "${THORCH_TEST_DBUS_MODE:-correct}" == hung ]]; then
  sleep 10
fi
case "${args}" in
  *InputDeviceManager.ListTouch*)
    printf 'event4\nevent5\n'
    ;;
  *Properties.Get*outputName*)
    if [[ "${THORCH_TEST_DBUS_MODE:-correct}" == wrong ]]; then
      printf 'wrong-output\n'
    elif [[ "${args}" == *event4* ]]; then
      printf 'DSI-2\n'
    else
      printf 'DSI-1\n'
    fi
    ;;
  *Properties.Set*)
    printf '%s\n' "${args}" >>"${THORCH_TEST_DBUS_LOG}"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${tmp}/bin/qdbus6"

run_mapper() {
  PATH="${tmp}/bin:${PATH}" \
    WAYLAND_DISPLAY=wayland-0 \
    XDG_RUNTIME_DIR="${tmp}/runtime" \
    THORCH_TOP_TOUCH_PATH="${tmp}/input/top" \
    THORCH_BOTTOM_TOUCH_PATH="${tmp}/input/bottom" \
    THORCH_TOUCH_MAP_DBUS_TIMEOUT=1s \
    THORCH_TOUCH_MAP_READY_ATTEMPTS=1 \
    THORCH_TEST_DBUS_LOG="${tmp}/dbus.log" \
    timeout 5s "${mapper}" --watch
}

: >"${tmp}/dbus.log"
run_mapper || fail "legacy --watch invocation did not terminate as a bounded one-shot"
[[ ! -s "${tmp}/dbus.log" ]] || fail "mapper rewrote properties that were already correct"

: >"${tmp}/dbus.log"
THORCH_TEST_DBUS_MODE=wrong run_mapper || fail "mapper failed while correcting stale output mappings"
[[ "$(grep -c 'Properties.Set.*outputName' "${tmp}/dbus.log")" -eq 2 ]] ||
  fail "mapper did not correct exactly the two stale output mappings"
[[ "$(wc -l <"${tmp}/dbus.log")" -eq 2 ]] ||
  fail "mapper rewrote unchanged input properties"

[[ "$(grep -c 'LIBINPUT_CALIBRATION_MATRIX.*0 -1 1 1 0 0' "${udev_rule}")" -eq 2 ]] ||
  fail "touch rotation is not a static libinput default for both panels"
grep -q 'platform-a90000.i2c.*WL_OUTPUT}="DSI-2"' "${udev_rule}" ||
  fail "top touchscreen is not routed to DSI-2"
grep -q 'platform-98c000.i2c.*WL_OUTPUT}="DSI-1"' "${udev_rule}" ||
  fail "bottom touchscreen is not routed to DSI-1"

THORCH_TEST_DBUS_MODE=hung run_mapper ||
  fail "mapper did not bound an unresponsive KWin DBus call"

: >"${tmp}/dbus.log"
flock "${tmp}/runtime/thorch-kwin-touch-map.lock" sleep 3 &
locker_pid=$!
sleep 0.1
run_mapper || fail "second mapper failed instead of yielding to the active instance"
kill "${locker_pid}" 2>/dev/null || true
wait "${locker_pid}" 2>/dev/null || true
[[ ! -s "${tmp}/dbus.log" ]] || fail "second mapper called DBus while the mapper lock was held"

[[ ! -e "${legacy_autostart}" ]] ||
  fail "redundant perpetual touch mapper autostart is still packaged"

legacy_home="${tmp}/home/legacy/.config/autostart"
custom_home="${tmp}/home/custom/.config/autostart"
mkdir -p "${legacy_home}" "${custom_home}"
printf '%s\n' \
  '[Desktop Entry]' \
  'Name=Thorch KWin touch mapping' \
  'Exec=/usr/bin/thorch-kwin-touch-map --watch' \
  >"${legacy_home}/thorch-kwin-touch-map.desktop"
printf '%s\n' \
  '[Desktop Entry]' \
  'Name=Custom touch mapping' \
  'Exec=/usr/local/bin/custom-touch-map' \
  >"${custom_home}/thorch-kwin-touch-map.desktop"
THORCH_HOME_ROOT="${tmp}/home" bash -c \
  'source "$1"; remove_legacy_touch_mapper_autostart' _ "${package_install}"
[[ ! -e "${legacy_home}/thorch-kwin-touch-map.desktop" ]] ||
  fail "package upgrade did not remove the legacy watch autostart"
[[ -e "${custom_home}/thorch-kwin-touch-map.desktop" ]] ||
  fail "package upgrade removed a custom touch mapper autostart"

bash -c 'while :; do read -r -t 30 || :; done' \
  /usr/bin/thorch-kwin-touch-map --watch &
legacy_mapper_pid=$!
sleep 0.1
THORCH_HOME_ROOT="${tmp}/home" bash -c \
  'source "$1"; stop_legacy_touch_mapper' _ "${package_install}"
for _ in {1..20}; do
  kill -0 "${legacy_mapper_pid}" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "${legacy_mapper_pid}" 2>/dev/null; then
  kill "${legacy_mapper_pid}" 2>/dev/null || true
  wait "${legacy_mapper_pid}" 2>/dev/null || true
  fail "package upgrade did not stop the running legacy touch mapper"
fi
wait "${legacy_mapper_pid}" 2>/dev/null || true

legacy_config="${tmp}/home/legacy/.config/kcminputrc"
custom_config="${tmp}/home/custom/.config/kcminputrc"
cat >"${legacy_config}" <<'EOF'
[Libinput][111][222][top_touchscreen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
NaturalScroll=true
Orientation=1
Rotation=0

[Libinput][111][222][bottom_touchscreen]
CalibrationMatrix=1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1
Orientation=1
OutputName=DSI-1
Rotation=0

[Libinput][333][444][Unrelated device]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
Orientation=1
Rotation=0
EOF
cat >"${custom_config}" <<'EOF'
[Libinput][111][222][Custom touchscreen]
CalibrationMatrix=0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,1
Orientation=2
OutputName=DSI-1
Rotation=90
EOF

THORCH_HOME_ROOT="${tmp}/home" bash -c \
  'source "$1"; remove_legacy_touch_input_overrides' _ "${package_install}"

grep -Fqx '[Libinput][111][222][top_touchscreen]' "${legacy_config}" ||
  fail "package upgrade removed the top touchscreen group"
grep -Fqx 'OutputName=DSI-1' "${legacy_config}" ||
  fail "package upgrade removed the bottom panel output mapping"
grep -Fqx 'NaturalScroll=true' "${legacy_config}" ||
  fail "package upgrade removed an unrelated touchscreen setting"
[[ "$(grep -c '^CalibrationMatrix=' "${legacy_config}")" -eq 1 ]] ||
  fail "package upgrade did not remove only the legacy touch matrices"
[[ "$(grep -c '^Orientation=1$' "${legacy_config}")" -eq 1 ]] ||
  fail "package upgrade did not remove only the legacy touch orientations"
[[ "$(grep -c '^Rotation=0$' "${legacy_config}")" -eq 1 ]] ||
  fail "package upgrade did not remove only the legacy touch rotations"
grep -Fqx 'CalibrationMatrix=0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,1' "${custom_config}" ||
  fail "package upgrade removed a custom touchscreen matrix"
grep -Fqx 'Orientation=2' "${custom_config}" ||
  fail "package upgrade removed a custom touchscreen orientation"
grep -Fqx 'Rotation=90' "${custom_config}" ||
  fail "package upgrade removed a custom touchscreen rotation"

printf 'thorch KWin touch mapper fake DBus tests passed\n'
