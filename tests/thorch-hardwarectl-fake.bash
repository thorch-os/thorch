#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-bsp/payload/usr/bin/thorch-hardwarectl"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${tmp}/hardware.conf" <<'EOF'
THORCH_CPU_BOOST=1
THORCH_DISABLE_CPU0_IDLE_STATE1=0
THORCH_CPU_GOVERNOR=performance
THORCH_GPU_GOVERNOR=performance
THORCH_FAN_PROFILE=moderate
THORCH_FAN_SENSOR_MODE=max
THORCH_RGB_MODE=battery
THORCH_RGB_BRIGHTNESS=255
THORCH_RGB_STATIC_R=0
THORCH_RGB_STATIC_G=128
THORCH_RGB_STATIC_B=255
EOF

cat > "${tmp}/hw-defaults" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'hw-defaults %s boost=%s idle=%s cpu=%s gpu=%s\n' "$*" "${THORCH_CPU_BOOST:-unset}" "${THORCH_DISABLE_CPU0_IDLE_STATE1:-unset}" "${THORCH_CPU_GOVERNOR:-unset}" "${THORCH_GPU_GOVERNOR:-unset}" >> "${THORCH_TEST_LOG:?}"
EOF

cat > "${tmp}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "${THORCH_TEST_LOG:?}"
EOF

cat > "${tmp}/rgb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rgb %s\n' "$*" >> "${THORCH_TEST_LOG:?}"
EOF

cat > "${tmp}/fancontrol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fancontrol %s\n' "$*" >> "${THORCH_TEST_LOG:?}"
EOF

chmod 755 "${tmp}/hw-defaults" "${tmp}/systemctl" "${tmp}/rgb" "${tmp}/fancontrol"
log="${tmp}/actions.log"

run_ctl() {
  THORCH_HARDWARE_CONFIG="${tmp}/hardware.conf" \
  THORCH_HARDWARE_DEFAULTS="${tmp}/hw-defaults" \
  THORCH_HARDWARE_SYSTEMCTL="${tmp}/systemctl" \
  THORCH_HARDWARE_RGB="${tmp}/rgb" \
  THORCH_HARDWARE_FANCONTROL="${tmp}/fancontrol" \
  THORCH_HARDWARE_SKIP_PKEXEC=1 \
  THORCH_TEST_LOG="${log}" \
    "${script}" "$@"
}

run_ctl set cpu-boost off
grep -qx 'THORCH_CPU_BOOST=0' "${tmp}/hardware.conf" || fail "cpu boost was not updated"
grep -qx 'hw-defaults apply boost=0 idle=0 cpu=performance gpu=performance' "${log}" || fail "cpu boost did not apply hardware defaults with saved config"

: > "${log}"
run_ctl set governors schedutil simple_ondemand
grep -qx 'THORCH_CPU_GOVERNOR=schedutil' "${tmp}/hardware.conf" || fail "cpu governor was not updated"
grep -qx 'THORCH_GPU_GOVERNOR=simple_ondemand' "${tmp}/hardware.conf" || fail "gpu governor was not updated"
grep -qx 'hw-defaults apply boost=0 idle=0 cpu=schedutil gpu=simple_ondemand' "${log}" || fail "governors did not apply hardware defaults with saved config"

: > "${log}"
run_ctl set cpu-governor powersave
grep -qx 'THORCH_CPU_GOVERNOR=powersave' "${tmp}/hardware.conf" || fail "cpu governor was not updated by single-governor setter"
grep -qx 'hw-defaults apply boost=0 idle=0 cpu=powersave gpu=simple_ondemand' "${log}" || fail "cpu governor setter did not apply hardware defaults with saved config"

: > "${log}"
run_ctl set gpu-governor auto
grep -qx 'THORCH_GPU_GOVERNOR=auto' "${tmp}/hardware.conf" || fail "gpu governor was not updated by single-governor setter"
grep -qx 'hw-defaults apply boost=0 idle=0 cpu=powersave gpu=auto' "${log}" || fail "gpu governor setter did not apply hardware defaults with saved config"

: > "${log}"
run_ctl set fan-profile aggressive
grep -qx 'THORCH_FAN_PROFILE=aggressive' "${tmp}/hardware.conf" || fail "fan profile was not updated"
grep -qx 'systemctl try-restart thorch-fancontrol.service' "${log}" || fail "fan profile did not restart fancontrol"

: > "${log}"
run_ctl set fan-state quiet average
grep -qx 'THORCH_FAN_PROFILE=quiet' "${tmp}/hardware.conf" || fail "fan state did not update profile"
grep -qx 'THORCH_FAN_SENSOR_MODE=average' "${tmp}/hardware.conf" || fail "fan state did not update sensor mode"
grep -qx 'systemctl try-restart thorch-fancontrol.service' "${log}" || fail "fan state did not restart fancontrol"

: > "${log}"
run_ctl set rgb-state static 200 1 2 3
grep -qx 'THORCH_RGB_MODE=static' "${tmp}/hardware.conf" || fail "rgb mode was not switched to static"
grep -qx 'THORCH_RGB_BRIGHTNESS=200' "${tmp}/hardware.conf" || fail "rgb brightness was not updated"
grep -qx 'THORCH_RGB_STATIC_R=1' "${tmp}/hardware.conf" || fail "static red was not updated"
grep -qx 'THORCH_RGB_STATIC_G=2' "${tmp}/hardware.conf" || fail "static green was not updated"
grep -qx 'THORCH_RGB_STATIC_B=3' "${tmp}/hardware.conf" || fail "static blue was not updated"
grep -qx 'rgb set 1 2 3' "${log}" || fail "rgb static apply did not run"

status_output="$(run_ctl status)"
grep -q '^cpu_boost: 0$' <<< "${status_output}" || fail "status did not report cpu boost"
grep -q '^disable_cpu0_idle_state1: 0$' <<< "${status_output}" || fail "status did not report CPU0 idle workaround"
grep -q '^cpu_governor: powersave$' <<< "${status_output}" || fail "status did not report cpu governor"
grep -q '^gpu_governor: auto$' <<< "${status_output}" || fail "status did not report gpu governor"
grep -q '^fan_profile: quiet$' <<< "${status_output}" || fail "status did not report fan profile"
grep -q '^rgb_mode: static$' <<< "${status_output}" || fail "status did not report rgb mode"

status_json="$(run_ctl status-json)"
python - "${status_json}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["cpu_boost_enabled"] is False
assert data["disable_cpu0_idle_state1"] == "0"
assert data["cpu_governor"] == "powersave"
assert data["gpu_governor"] == "auto"
assert data["fan_profile"] == "quiet"
assert data["fan_sensor_mode"] == "average"
assert data["rgb_mode"] == "static"
assert data["rgb_brightness"] == 200
assert data["rgb_static"] == [1, 2, 3]
assert data["rgb_static_hex"] == "#010203"
PY

printf 'ok\n'
