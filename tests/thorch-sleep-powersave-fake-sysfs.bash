#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-sleep/thorch-sleep-powersave"
hw_defaults="${root}/packages/thorch-bsp/payload/usr/bin/thorch-hw-defaults"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

setup_state() {
  rm -rf "${tmp}/sys"
  rm -f "${tmp}/state"
  mkdir -p \
    "${tmp}/sys/class/devfreq/gpu0" \
    "${tmp}/sys/class/devfreq/1d84000.ufshc" \
    "${tmp}/sys/devices/platform/soc@0/1d84000.ufshc" \
    "${tmp}/sys/devices/system/cpu/cpufreq" \
    "${tmp}/sys/devices/system/cpu/cpufreq/policy0" \
    "${tmp}/sys/devices/system/cpu/cpufreq/policy4"

  printf '1\n' > "${tmp}/sys/devices/system/cpu/cpufreq/boost"
  printf 'performance\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
  printf 'performance schedutil powersave\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors"
  printf 'schedutil\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_governor"
  printf 'performance schedutil powersave\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_available_governors"

  printf 'simple_ondemand\n' > "${tmp}/sys/class/devfreq/gpu0/governor"
  printf 'performance simple_ondemand powersave\n' > "${tmp}/sys/class/devfreq/gpu0/available_governors"

  printf 'simple_ondemand\n' > "${tmp}/sys/class/devfreq/1d84000.ufshc/governor"
  printf 'performance simple_ondemand powersave\n' > "${tmp}/sys/class/devfreq/1d84000.ufshc/available_governors"
  printf '1\n' > "${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkscale_enable"
  printf '1\n' > "${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkgate_enable"
}

assert_powersave_state() {
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/boost")" == "0" ]] || fail "cpu boost was not disabled"
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" == "powersave" ]] || fail "policy0 governor was not powersave"
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_governor")" == "powersave" ]] || fail "policy4 governor was not powersave"
  [[ "$(<"${tmp}/sys/class/devfreq/gpu0/governor")" == "powersave" ]] || fail "gpu governor was not powersave"
  [[ "$(<"${tmp}/sys/class/devfreq/1d84000.ufshc/governor")" == "powersave" ]] || fail "ufs governor was not powersave"
  [[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkscale_enable")" == "0" ]] || fail "ufs clock scaling was not disabled"
  [[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkgate_enable")" == "0" ]] || fail "ufs clock gating was not disabled"
}

assert_restored_state() {
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/boost")" == "1" ]] || fail "cpu boost was not restored"
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" == "performance" ]] || fail "policy0 governor was not restored"
  [[ "$(<"${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_governor")" == "schedutil" ]] || fail "policy4 governor was not restored"
  [[ "$(<"${tmp}/sys/class/devfreq/gpu0/governor")" == "simple_ondemand" ]] || fail "gpu governor was not restored"
  [[ "$(<"${tmp}/sys/class/devfreq/1d84000.ufshc/governor")" == "simple_ondemand" ]] || fail "ufs governor was not restored"
  [[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkscale_enable")" == "1" ]] || fail "ufs clock scaling was not restored"
  [[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkgate_enable")" == "1" ]] || fail "ufs clock gating was not restored"
}

run_hook() {
  THORCH_SLEEP_POWERSAVE_SYSFS_ROOT="${tmp}/sys" \
  THORCH_SLEEP_POWERSAVE_HW_DEFAULTS="${hw_defaults}" \
  THORCH_SLEEP_POWERSAVE_STATE_FILE="${tmp}/state" \
    "${hook}" "$@"
}

setup_state
run_hook noop suspend
[[ "$(<"${tmp}/sys/class/devfreq/1d84000.ufshc/governor")" == "simple_ondemand" ]] || fail "unknown phase changed UFS governor"
[[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkgate_enable")" == "1" ]] || fail "unknown phase changed clock gating"

setup_state
run_hook pre hibernate
[[ "$(<"${tmp}/sys/class/devfreq/1d84000.ufshc/governor")" == "simple_ondemand" ]] || fail "non-suspend verb changed UFS governor"
[[ "$(<"${tmp}/sys/devices/platform/soc@0/1d84000.ufshc/clkgate_enable")" == "1" ]] || fail "non-suspend verb changed clock gating"

setup_state
run_hook pre suspend
assert_powersave_state
[[ -s "${tmp}/state" ]] || fail "pre suspend did not save state"

run_hook post suspend
assert_restored_state
[[ ! -e "${tmp}/state" ]] || fail "post suspend did not remove saved state"

setup_state
run_hook post suspend
assert_restored_state

printf 'ok\n'
