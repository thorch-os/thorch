#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-hardware-settings"
kcm_qml="${root}/packages/thorch-kde-defaults/kcm/ui/main.qml"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${tmp}/bin"
log="${tmp}/helper.log"
stderr_log="${tmp}/stderr.log"

cat > "${tmp}/bin/systemsettings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${THORCH_TEST_LAUNCH_LOG:?}"
EOF
chmod 755 "${tmp}/bin/systemsettings"

THORCH_TEST_LAUNCH_LOG="${tmp}/launcher.log" \
PATH="${tmp}/bin:${PATH}" \
  bash "${script}"

grep -qx 'kcm_thorch_hardware' "${tmp}/launcher.log" \
  || fail "hardware settings launcher did not open the System Settings KCM"

runner="$(command -v qmlscene6 || true)"
if [[ -z "${runner}" ]]; then
  if [[ "${THORCH_REQUIRE_QML_SMOKE:-0}" == "1" ]]; then
    fail "qmlscene6 is required by the CI QML smoke test"
  fi
  printf 'skip: qmlscene6 not available\n'
  exit 0
fi

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

set +e
QT_QPA_PLATFORM=offscreen \
PATH="${tmp}/bin:${PATH}" \
THORCH_TEST_LOG="${log}" \
  timeout 3 "${runner}" "${kcm_qml}" > /dev/null 2> "${stderr_log}"
qml_status=$?
set -e

if [[ "${qml_status}" -ne 0 && "${qml_status}" -ne 124 ]]; then
  cat "${stderr_log}" >&2
  fail "hardware settings KCM QML did not load"
fi

grep -qx 'status-json' "${log}" || fail "hardware settings UI did not query status-json"

if rg -n '(Error|ReferenceError|TypeError|is not installed|Cannot assign)' "${stderr_log}" >/dev/null 2>&1; then
  cat "${stderr_log}" >&2
  fail "hardware settings UI reported QML errors"
fi

printf 'ok\n'
