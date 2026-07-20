#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-bsp/payload/usr/bin/thorch-hw-defaults"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p \
  "${tmp}/sys/class/devfreq/gpu0" \
  "${tmp}/sys/devices/system/cpu/cpufreq" \
  "${tmp}/sys/devices/system/cpu/cpufreq/policy0" \
  "${tmp}/sys/devices/system/cpu/cpufreq/policy4" \
  "${tmp}/sys/devices/system/cpu/cpufreq/policy7" \
  "${tmp}/sys/devices/system/cpu/cpu0/cpuidle/state1"

printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/boost"
printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/boost"
printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/boost"
printf '0\n' > "${tmp}/sys/devices/system/cpu/cpu0/cpuidle/state1/disable"
ln -s /dev/full "${tmp}/sys/devices/system/cpu/cpufreq/policy7/boost"
printf 'schedutil\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
printf 'performance schedutil powersave\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors"
printf 'schedutil\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_governor"
printf 'performance schedutil powersave\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_available_governors"
printf 'schedutil\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_governor"
printf 'performance schedutil powersave\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_available_governors"
printf '1900800\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
printf '2016000\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
printf '2304000\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
printf '2419200 2803200\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_available_frequencies"
printf '2841600\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_boost_frequencies"
printf '2995200\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq"
printf '3187200\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq"
printf 'msm-adreno-tz\n' > "${tmp}/sys/class/devfreq/gpu0/governor"
printf 'performance msm-adreno-tz ondemand simple_ondemand powersave\n' > "${tmp}/sys/class/devfreq/gpu0/available_governors"

THORCH_HW_DEFAULTS_SYSFS_ROOT="${tmp}/sys" THORCH_CPU_BOOST=1 THORCH_CPU_GOVERNOR=performance THORCH_GPU_GOVERNOR=performance "${script}" apply

[[ "$(cat "${tmp}/sys/devices/system/cpu/cpu0/cpuidle/state1/disable")" == "1" ]] || fail "ROCKNIX CPU0 idle workaround was not applied"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/boost")" == "1" ]] || fail "global boost was not enabled"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy4/boost")" == "1" ]] || fail "policy4 boost was not enabled"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy0/boost")" == "0" ]] || fail "policy0 without boost frequencies should be left alone"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" == "2016000" ]] || fail "policy0 max freq was not raised"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq")" == "2841600" ]] || fail "policy4 boost max freq was not raised"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq")" == "3187200" ]] || fail "policy7 prime max freq was not raised"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" == "performance" ]] || fail "policy0 governor was not set"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy4/scaling_governor")" == "performance" ]] || fail "policy4 governor was not set"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_governor")" == "performance" ]] || fail "policy7 governor was not set"
[[ "$(cat "${tmp}/sys/class/devfreq/gpu0/governor")" == "performance" ]] || fail "gpu governor was not set"

printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/boost"
printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy0/boost"
printf '0\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy4/boost"
printf '2995200\n' > "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq"

THORCH_HW_DEFAULTS_SYSFS_ROOT="${tmp}/sys" THORCH_CPU_BOOST=0 "${script}" apply

[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/boost")" == "0" ]] || fail "global boost was not disabled"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy4/boost")" == "0" ]] || fail "policy4 boost was not disabled"
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq")" == "2995200" ]] || fail "boost-disabled apply should not raise max freq"

THORCH_HW_DEFAULTS_SYSFS_ROOT="${tmp}/sys" THORCH_CPU_BOOST=0 THORCH_DISABLE_CPU0_IDLE_STATE1=0 "${script}" apply
[[ "$(cat "${tmp}/sys/devices/system/cpu/cpu0/cpuidle/state1/disable")" == "0" ]] || fail "CPU0 idle workaround override did not re-enable the state"

rm -f "${tmp}/sys/devices/system/cpu/cpufreq/policy7/boost"
status_output="$(THORCH_HW_DEFAULTS_SYSFS_ROOT="${tmp}/sys" THORCH_CPU_BOOST=0 "${script}" status)"
grep -q 'cpu0/cpuidle/state1/disable=0' <<< "${status_output}" || fail "status did not report CPU0 idle workaround state"
grep -q 'policy4/boost=0' <<< "${status_output}" || fail "status did not report current boost-capable policy state"
grep -q 'policy0/scaling_governor=performance' <<< "${status_output}" || fail "status did not report cpu governor state"
grep -q 'gpu0/governor=msm-adreno-tz' <<< "${status_output}" || fail "default GPU governor was not msm-adreno-tz"

printf 'ok\n'
