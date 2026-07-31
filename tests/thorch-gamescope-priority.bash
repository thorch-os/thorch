#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkgbuild="${root}/packages/thorch-gamescope/PKGBUILD"
launchers="${root}/packages/thorch-gaming-installers"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if grep -Eiq 'setcap[[:space:]].*cap_sys_nice|setcap[[:space:]].*CAP_SYS_NICE' "${pkgbuild}"; then
  fail "gamescope package grants CAP_SYS_NICE"
fi

grep -Fq \
  'wlroots::git+https://gitlab.freedesktop.org/wlroots/wlroots.git#commit=88a869855742281c98c22cab9641b317b8d065ef' \
  "${pkgbuild}" ||
  fail "gamescope does not pin its exact official wlroots submodule commit"
if grep -Fq 'wlroots-5261.patch' "${pkgbuild}"; then
  fail "gamescope still applies the obsolete wlroots MR 5261 patch"
fi
grep -Fq -- '-Denable_tests=false' "${pkgbuild}" ||
  fail "gamescope package does not disable its undeclared Catch2 unit-test target"

if grep -ERiq \
  'CAP_SYS_NICE|AmbientCapabilities=.*SYS_NICE|CapabilityBoundingSet=.*SYS_NICE|(^|[[:space:]])nice([[:space:]]+-n)?[[:space:]]+-20([[:space:]]|$)|(^|[[:space:]])renice([[:space:]].*)?-20([[:space:]]|$)' \
  "${launchers}"; then
  fail "Steam/gamescope launcher grants or requests -20 priority"
fi

printf 'thorch gamescope normal-priority checks passed\n'
