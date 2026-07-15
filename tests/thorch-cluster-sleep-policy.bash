#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sleep_conf="${root}/packages/thorch-bsp/payload/etc/systemd/sleep.conf.d/50-thorch-native-suspend.conf"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
usb_rule="${root}/packages/thorch-bsp/payload/usr/lib/udev/rules.d/99-thorch-sm8550-usb-autosuspend.rules"

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

grep -q 'KERNEL=="a600000.usb"' "${usb_rule}" ||
  fail "USB autosuspend rule does not target the primary SM8550 controller"
grep -q 'ATTR{power/control}="auto"' "${usb_rule}" ||
  fail "USB autosuspend rule does not enable runtime PM"

printf 'thorch cluster sleep policy checks passed\n'
