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

mkdir -p "${tmp}/etc/thorch"

cat > "${tmp}/etc/thorch/hardware.conf" <<'EOF'
THORCH_CPU_BOOST=1
THORCH_FAN_PROFILE=moderate
THORCH_FAN_SENSOR_MODE=max
THORCH_RGB_MODE=battery
THORCH_RGB_BRIGHTNESS=255
THORCH_RGB_STATIC_R=0
THORCH_RGB_STATIC_G=128
THORCH_RGB_STATIC_B=255
EOF

cat > "${tmp}/etc/thorch/hw-defaults.conf" <<'EOF'
THORCH_CPU_BOOST=0
EOF

cat > "${tmp}/etc/thorch/fancontrol.conf" <<'EOF'
THORCH_FAN_PROFILE=quiet
THORCH_FAN_SENSOR_MODE=average
THORCH_FAN_POLL_SECONDS=5
EOF

cat > "${tmp}/etc/thorch/rgb.conf" <<'EOF'
THORCH_RGB_MODE=static
THORCH_RGB_BRIGHTNESS=180
THORCH_RGB_STATIC_R=9
THORCH_RGB_STATIC_G=8
THORCH_RGB_STATIC_B=7
EOF

THORCH_HARDWARE_CONFIG="${tmp}/etc/thorch/hardware.conf" \
THORCH_HARDWARE_LEGACY_DIR="${tmp}/etc/thorch" \
THORCH_HARDWARE_SKIP_PKEXEC=1 \
  "${script}" migrate

grep -qx 'THORCH_CPU_BOOST=0' "${tmp}/etc/thorch/hardware.conf" || fail "cpu boost was not migrated"
grep -qx 'THORCH_FAN_PROFILE=quiet' "${tmp}/etc/thorch/hardware.conf" || fail "fan profile was not migrated"
grep -qx 'THORCH_FAN_SENSOR_MODE=average' "${tmp}/etc/thorch/hardware.conf" || fail "fan sensor mode was not migrated"
grep -qx 'THORCH_FAN_POLL_SECONDS=5' "${tmp}/etc/thorch/hardware.conf" || fail "fan poll seconds were not migrated"
grep -qx 'THORCH_RGB_MODE=static' "${tmp}/etc/thorch/hardware.conf" || fail "rgb mode was not migrated"
grep -qx 'THORCH_RGB_BRIGHTNESS=180' "${tmp}/etc/thorch/hardware.conf" || fail "rgb brightness was not migrated"
grep -qx 'THORCH_RGB_STATIC_R=9' "${tmp}/etc/thorch/hardware.conf" || fail "rgb red was not migrated"
grep -qx 'THORCH_RGB_STATIC_G=8' "${tmp}/etc/thorch/hardware.conf" || fail "rgb green was not migrated"
grep -qx 'THORCH_RGB_STATIC_B=7' "${tmp}/etc/thorch/hardware.conf" || fail "rgb blue was not migrated"

for file in hw-defaults.conf fancontrol.conf rgb.conf; do
  [[ -f "${tmp}/etc/thorch/${file}.migrated-to-hardware.conf" ]] || fail "${file} was not renamed after migration"
done

printf 'ok\n'
