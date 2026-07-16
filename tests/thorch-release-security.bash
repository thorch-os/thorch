#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
builder="${root}/scripts/build-image.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

defaults="$(
  env -u THORCH_PASSWORD -u THORCH_ENABLE_SSH -u ALARM_MIRRORS -u ALARM_MIRROR THORCH_KERNEL_JOBS=1 \
    bash -c 'source "$1"; printf "password=%s\nssh=%s\nmirrors=%s\nmirror=%s\n" "$THORCH_PASSWORD" "$THORCH_ENABLE_SSH" "$ALARM_MIRRORS" "$ALARM_MIRROR"' \
    bash "${config}"
)"

grep -qx 'password=' <<< "${defaults}" ||
  fail "default image password is not empty"
grep -qx 'ssh=0' <<< "${defaults}" ||
  fail "default image enables SSH"

mirrors="$(sed -n 's/^mirrors=//p' <<< "${defaults}")"
[[ -n "${mirrors}" ]] || fail "default ALARM mirror list is empty"
for mirror in ${mirrors}; do
  [[ "${mirror}" == https://* ]] || fail "default ALARM mirror is not HTTPS: ${mirror}"
done

mirror="$(sed -n 's/^mirror=//p' <<< "${defaults}")"
[[ "${mirror}" == https://* ]] || fail "default ALARM single mirror is not HTTPS: ${mirror}"

! grep -HnE 'http://[^ ]*archlinuxarm' "${config}" "${root}/scripts/lib/common.sh" ||
  fail "an ALARM mirror fallback still uses plain HTTP"

grep -q 'run_rootfs_cmd /usr/bin/usermod --lock "${THORCH_USER}"' "${builder}" ||
  fail "image builder does not lock the initial user when no password is supplied"
grep -q 'run_rootfs_cmd /usr/bin/usermod --lock root' "${builder}" ||
  fail "image builder does not lock root when no password is supplied"
grep -q 'systemctl --root "${rootfs_dir}" disable sshd.service' "${builder}" ||
  fail "image builder does not explicitly disable SSH"
grep -q "printf 'enable sshd.service" "${builder}" ||
  fail "image builder does not support explicit local SSH enablement through presets"
grep -q 'THORCH_ENABLE_SSH requires a non-empty THORCH_PASSWORD' "${builder}" ||
  fail "image builder permits SSH without an explicit password"

service_block="$(sed -n '/^rootfs_services=(/,/^)/p' "${builder}")"
! grep -q 'sshd.service' <<< "${service_block}" ||
  fail "image builder still enables SSH by default"

if grep -RInE 'default(ing|s)? to `?1234|THORCH_PASSWORD.*1234' \
  "${config}" "${builder}" "${root}/README.md" "${root}/docs" "${root}/SECURITY.md"; then
  fail "release-facing source still documents or installs the shared 1234 credential"
fi

if grep -RInE 'thorch-rgb-ambient|ambient desktop color' "${root}/README.md" "${root}/docs"; then
  fail "documentation still claims the nonexistent ambient RGB service"
fi

printf 'thorch release security checks passed\n'
