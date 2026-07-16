#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapper="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-kwin-touch-map"
legacy_autostart="${root}/packages/thorch-kde-defaults/payload/etc/skel/.config/autostart/thorch-kwin-touch-map.desktop"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${tmp}/bin" "${tmp}/dev/input" "${tmp}/input" "${tmp}/runtime"
: >"${tmp}/dev/input/event4"
: >"${tmp}/dev/input/event5"
ln -s "${tmp}/dev/input/event4" "${tmp}/input/bottom"
ln -s "${tmp}/dev/input/event5" "${tmp}/input/top"

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
  *Properties.Get*calibrationMatrix*)
    printf '1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1\n'
    ;;
  *Properties.Get*rotation*)
    printf '0\n'
    ;;
  *Properties.Get*orientationDBus*)
    printf '1\n'
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
    THORCH_BOTTOM_TOUCH_PATH="${tmp}/input/bottom" \
    THORCH_TOP_TOUCH_PATH="${tmp}/input/top" \
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

printf 'thorch KWin touch mapper fake DBus tests passed\n'
