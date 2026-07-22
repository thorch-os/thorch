#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-fex-binfmt"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

binfmt_dir="${tmp}/binfmt_misc"
systemctl_log="${tmp}/systemctl.log"
mkdir -p "${binfmt_dir}" "${tmp}/bin"
printf 'enabled\n' > "${binfmt_dir}/FEX-x86_64"
printf 'enabled\n' > "${binfmt_dir}/FEX-x86"
printf 'leave-me-alone\n' > "${binfmt_dir}/x86_64"

cat > "${tmp}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${THORCH_FAKE_SYSTEMCTL_LOG:?}"
printf 'enabled\n' > "${THORCH_FEX_BINFMT_DIR:?}/FEX-x86_64"
printf 'enabled\n' > "${THORCH_FEX_BINFMT_DIR:?}/FEX-x86"
EOF
chmod 755 "${tmp}/bin/systemctl"

run_helper() {
  THORCH_FEX_BINFMT_DIR="${binfmt_dir}" \
  THORCH_FEX_BINFMT_SYSTEMCTL="${tmp}/bin/systemctl" \
  THORCH_FAKE_SYSTEMCTL_LOG="${systemctl_log}" \
    "${script}" "$@"
}

status="$(run_helper status)"
grep -qx 'FEX-x86_64: enabled' <<< "${status}" ||
  fail "status did not report the registered FEX-x86_64 handler"
grep -qx 'FEX-x86: enabled' <<< "${status}" ||
  fail "status did not report the registered FEX-x86 handler"

run_helper disable
[[ "$(<"${binfmt_dir}/FEX-x86_64")" == "0" ]] ||
  fail "disable did not target FEX-x86_64"
[[ "$(<"${binfmt_dir}/FEX-x86")" == "0" ]] ||
  fail "disable did not target FEX-x86"
[[ "$(<"${binfmt_dir}/x86_64")" == "leave-me-alone" ]] ||
  fail "disable changed an unrelated handler"

run_helper enable
grep -qx 'restart systemd-binfmt.service' "${systemctl_log}" ||
  fail "enable did not restart systemd-binfmt"
[[ "$(<"${binfmt_dir}/FEX-x86_64")" == "enabled" ]] ||
  fail "enable did not restore FEX-x86_64"
[[ "$(<"${binfmt_dir}/FEX-x86")" == "enabled" ]] ||
  fail "enable did not restore FEX-x86"

rm "${binfmt_dir}/FEX-x86"
status="$(run_helper status)"
grep -qx 'FEX-x86: unavailable' <<< "${status}" ||
  fail "status did not report a missing FEX-x86 handler"

printf 'thorch FEX binfmt control checks passed\n'
