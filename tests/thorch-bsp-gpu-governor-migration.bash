#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_script="${root}/packages/thorch-bsp/thorch-bsp.install"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1"
  exit 1
}

run_upgrade() {
  local installed_version="$1"

  THORCH_INSTALL_ROOT="${work}/root" \
    "${BASH}" -s -- "${install_script}" "${installed_version}" <<'EOF'
source "$1"

  vercmp() {
    case "$1:$2" in
    1-27:1-32|1-30:1-32|1-31:1-32) printf '%s\n' -1 ;;
    1-32:1-32) printf '%s\n' 0 ;;
    1-33:1-32) printf '%s\n' 1 ;;
    *) return 1 ;;
    esac
  }

  post_upgrade '1-32' "$2" >/dev/null 2>&1
EOF
}

mkdir -p "${work}/root/etc/thorch"
config="${work}/root/etc/thorch/hardware.conf"
expected="${work}/expected"

cat >"${config}" <<'EOF'
# Thorch Thor custom settings
THORCH_CPU_GOVERNOR=performance
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=msm-adreno-tz
THORCH_EXTRA_VALUE='preserve = exactly'
EOF
cat >"${expected}" <<'EOF'
# Thorch Thor custom settings
THORCH_CPU_GOVERNOR=performance
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=simple_ondemand
THORCH_EXTRA_VALUE='preserve = exactly'
EOF

run_upgrade '1-27'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the upgrade did not replace only the legacy GPU governor default'

run_upgrade '1-27'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the legacy GPU governor migration is not idempotent'

cat >"${config}" <<'EOF'
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=ondemand
EOF
cat >"${expected}" <<'EOF'
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=simple_ondemand
EOF
run_upgrade '1-31'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the upgrade did not replace the invalid ondemand GPU governor'

cat >"${config}" <<'EOF'
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=powersave
EOF
cp "${config}" "${expected}"
run_upgrade '1-27'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the migration changed a custom GPU governor'

cat >"${config}" <<'EOF'
THORCH_FAN_PROFILE=quiet
THORCH_GPU_GOVERNOR=msm-adreno-tz
EOF
cp "${config}" "${expected}"
run_upgrade '1-32'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the migration changed a GPU governor set after the 1-32 upgrade'
run_upgrade '1-33'
cmp "${expected}" "${config}" >/dev/null ||
  fail 'the migration ran for a newer package version'

printf 'thorch BSP GPU governor migration checks passed\n'
