#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-hardware-settings"
app_dir="${root}/packages/thorch-kde-defaults/payload/usr/lib/thorch/hardware-settings"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

runner="$(command -v qmlscene6 || true)"
if [[ -z "${runner}" ]]; then
  if [[ "${THORCH_REQUIRE_QML_SMOKE:-0}" == "1" ]]; then
    fail "qmlscene6 is required by the CI QML smoke test"
  fi
  printf 'skip: qmlscene6 not available\n'
  exit 0
fi

probe_qml="${tmp}/probe.qml"
cat > "${probe_qml}" <<'EOF'
import QtQuick

Item {
    Timer {
        interval: 1
        running: true
        onTriggered: Qt.quit()
    }
}
EOF

if ! QT_QPA_PLATFORM=offscreen timeout 5 "${runner}" "${probe_qml}" >/dev/null 2>&1; then
  if [[ "${THORCH_REQUIRE_QML_SMOKE:-0}" == "1" ]]; then
    fail "qmlscene6 cannot run offscreen QML in the CI environment"
  fi
  printf 'skip: qmlscene6 cannot run offscreen QML in this environment\n'
  exit 0
fi

mkdir -p "${tmp}/bin"
log="${tmp}/helper.log"
stderr_log="${tmp}/stderr.log"

cat > "${tmp}/bin/thorch-hardwarectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${THORCH_TEST_LOG:?}"

case "${1:-}" in
  status-json)
    printf '%s\n' '{"cpu_boost":"1","cpu_boost_enabled":true,"cpu_governor":"performance","gpu_governor":"performance","fan_profile":"moderate","fan_profile_effective":"moderate","fan_sensor_mode":"max","rgb_mode":"battery","rgb_enabled":true,"rgb_brightness":255,"rgb_static_r":0,"rgb_static_g":128,"rgb_static_b":255,"rgb_static":[0,128,255],"rgb_static_hex":"#0080FF"}'
    ;;
  set)
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod 755 "${tmp}/bin/thorch-hardwarectl"

QT_QPA_PLATFORM=offscreen \
PATH="${tmp}/bin:${PATH}" \
THORCH_TEST_LOG="${log}" \
THORCH_HARDWARE_SETTINGS_APPDIR="${app_dir}" \
THORCH_HARDWARE_SETTINGS_RUNNER="${runner}" \
  timeout 10 bash "${script}" --quit-after-ms=1200 > /dev/null 2> "${stderr_log}" || {
    if [[ ! -s "${stderr_log}" ]]; then
      printf 'no stderr captured from hardware settings wrapper\n' >&2
    fi
    cat "${stderr_log}" >&2
    fail "hardware settings QML wrapper did not exit cleanly"
  }

grep -qx 'status-json' "${log}" || fail "hardware settings UI did not query status-json"

if rg -n '(Error|ReferenceError|TypeError|is not installed|Cannot assign)' "${stderr_log}" >/dev/null 2>&1; then
  cat "${stderr_log}" >&2
  fail "hardware settings UI reported QML errors"
fi

printf 'ok\n'
