#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${root}/packages/thorch-kde-defaults"
defaults="${package_root}/payload/etc/skel/.config/powerdevilrc"
legacy_default="${package_root}/payload/etc/skel/.config/powermanagementprofilesrc"
install_script="${package_root}/thorch-kde-defaults.install"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

[[ ! -e "${legacy_default}" ]] ||
  fail "obsolete Plasma 5 power profile is still installed into new homes"
grep -Fqx 'AutoSuspendAction=0' "${defaults}" ||
  fail "AC profile does not disable automatic suspend"
grep -Fqx 'AutoSuspendIdleTimeoutSec=900' "${defaults}" ||
  fail "AC profile does not retain a valid 15-minute timeout"
[[ "$(grep -Fc 'AutoSuspendAction=1' "${defaults}")" -eq 2 ]] ||
  fail "battery profiles do not select sleep"
grep -Fqx 'AutoSuspendIdleTimeoutSec=600' "${defaults}" ||
  fail "battery profile does not suspend after 10 minutes"
grep -Fqx 'AutoSuspendIdleTimeoutSec=300' "${defaults}" ||
  fail "low-battery profile does not suspend after 5 minutes"
[[ "$(grep -Fc 'LidAction=1' "${defaults}")" -eq 3 ]] ||
  fail "lid close does not select sleep in every profile"
[[ "$(grep -Fc 'PowerButtonAction=1' "${defaults}")" -eq 3 ]] ||
  fail "power button does not select sleep in every profile"
! grep -Fq 'AutoSuspendWhenIdle=' "${defaults}" ||
  fail "unsupported Plasma 6 AutoSuspendWhenIdle keys are still shipped"

fake_root="${tmp}/root"
bad_home="${fake_root}/home/bad/.config"
custom_home="${fake_root}/home/custom/.config"
mkdir -p "${fake_root}/etc/skel/.config" "${bad_home}" "${custom_home}"
cp "${defaults}" "${fake_root}/etc/skel/.config/powerdevilrc"

cat >"${bad_home}/powermanagementprofilesrc" <<'EOF'
[AC][SuspendSession]
idleTime=0

[Battery][SuspendSession]
idleTime=0

[LowBattery][SuspendSession]
idleTime=0

[Migration]
MigratedProfilesToPlasma6=powerdevilrc
EOF

cat >"${bad_home}/powerdevilrc" <<'EOF'
[AC][Display]
DimDisplayWhenIdle=false
TurnOffDisplayWhenIdle=false

[AC][SuspendAndShutdown]
AutoSuspendAction=0
AutoSuspendIdleTimeoutSec=0
AutoSuspendWhenIdle=false
LidAction=0
PowerButtonAction=0
PowerDownAction=0

[Battery][Display]
DimDisplayWhenIdle=false
TurnOffDisplayWhenIdle=false

[Battery][SuspendAndShutdown]
AutoSuspendAction=1
AutoSuspendIdleTimeoutSec=0
AutoSuspendWhenIdle=true
LidAction=0
PowerButtonAction=0
PowerDownAction=0

[LowBattery][Display]
DimDisplayWhenIdle=false
TurnOffDisplayWhenIdle=false
UseProfileSpecificDisplayBrightness=false

[LowBattery][SuspendAndShutdown]
AutoSuspendAction=1
AutoSuspendIdleTimeoutSec=0
AutoSuspendWhenIdle=true
LidAction=0
PowerButtonAction=0
PowerDownAction=0
EOF
chmod 0600 "${bad_home}/powerdevilrc"

cp "${bad_home}/powermanagementprofilesrc" \
  "${custom_home}/powermanagementprofilesrc"
cp "${bad_home}/powerdevilrc" "${custom_home}/powerdevilrc"
awk '
  !updated && $0 == "AutoSuspendIdleTimeoutSec=0" {
    print "AutoSuspendIdleTimeoutSec=120"
    updated = 1
    next
  }
  { print }
' "${custom_home}/powerdevilrc" >"${custom_home}/powerdevilrc.updated"
mv "${custom_home}/powerdevilrc.updated" "${custom_home}/powerdevilrc"
custom_before="$(sha256sum "${custom_home}/powerdevilrc" | awk '{print $1}')"

THORCH_INSTALL_ROOT="${fake_root}" \
THORCH_HOME_ROOT="${fake_root}/home" \
  bash -c 'source "$1"; post_upgrade' _ "${install_script}"

cmp -s "${bad_home}/powerdevilrc" "${defaults}" ||
  fail "known-bad migrated profile was not restored to Thorch defaults"
[[ "$(file_mode "${bad_home}/powerdevilrc")" == 600 ]] ||
  fail "profile repair did not preserve file mode"
[[ ! -e "${bad_home}/powermanagementprofilesrc" ]] ||
  fail "profile repair did not remove the obsolete migration input"

custom_after="$(sha256sum "${custom_home}/powerdevilrc" | awk '{print $1}')"
[[ "${custom_before}" == "${custom_after}" ]] ||
  fail "profile repair overwrote a customized power profile"
[[ -e "${custom_home}/powermanagementprofilesrc" ]] ||
  fail "profile repair removed legacy state for an unmodified custom profile"

printf 'thorch PowerDevil defaults checks passed\n'
