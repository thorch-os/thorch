#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sleep_conf="${root}/packages/thorch-bsp/payload/etc/systemd/sleep.conf.d/50-thorch-native-suspend.conf"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
image_checker="${root}/scripts/check-thorch-image.sh"
usb_rule="${root}/packages/thorch-bsp/payload/usr/lib/udev/rules.d/99-thorch-sm8550-usb-autosuspend.rules"
sleep_hooks="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-sleep"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -qx 'MemorySleepMode=s2idle' "${sleep_conf}" ||
  fail "systemd does not select s2idle"
grep -q 'mem_sleep_default=s2idle' "${repacker}" ||
  fail "rebuilt boot images do not default to s2idle"
! grep -q 'mem_sleep_default=deep' "${repacker}" ||
  fail "rebuilt boot images still default to deep suspend"
grep -q "kernel_cmdline_has 'mem_sleep_default=s2idle'" "${image_checker}" ||
  fail "raw image validation does not enforce the s2idle kernel default"
if compgen -G "${sleep_hooks}/thorch-*" >/dev/null; then
  fail "BSP still installs a Thorch system-sleep hook"
fi

grep -q 'KERNEL=="a600000.usb"' "${usb_rule}" ||
  fail "USB autosuspend rule does not target the primary SM8550 controller"
grep -q 'ATTR{power/control}="auto"' "${usb_rule}" ||
  fail "USB autosuspend rule does not enable runtime PM"

printf 'thorch cluster sleep policy checks passed\n'
