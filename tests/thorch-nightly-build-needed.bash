#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${root}/scripts/nightly-build-needed.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

current="1111111111111111111111111111111111111111"
previous="2222222222222222222222222222222222222222"
manifest="${tmpdir}/previous.build-manifest"

[[ "$("${checker}" "${current}")" == "true" ]] ||
  fail "missing previous manifest did not request the first build"

printf 'THORCH_NIGHTLY_BUILD_MANIFEST=1\nTHORCH_COMMIT=%s\n' \
  "${current}" > "${manifest}"
[[ "$("${checker}" "${current}" "${manifest}")" == "false" ]] ||
  fail "already-published Thorch commit requested another build"

printf 'THORCH_NIGHTLY_BUILD_MANIFEST=1\nTHORCH_COMMIT=%s\n' \
  "${previous}" > "${manifest}"
[[ "$("${checker}" "${current}" "${manifest}")" == "true" ]] ||
  fail "new Thorch commit did not request a build"

printf 'THORCH_NIGHTLY_BUILD_MANIFEST=1\n' > "${manifest}"
if "${checker}" "${current}" "${manifest}" >/dev/null 2>&1; then
  fail "manifest without a Thorch commit was accepted"
fi

printf 'THORCH_COMMIT=%s\nTHORCH_COMMIT=%s\n' \
  "${current}" "${previous}" > "${manifest}"
if "${checker}" "${current}" "${manifest}" >/dev/null 2>&1; then
  fail "manifest with duplicate Thorch commits was accepted"
fi

if "${checker}" invalid "${manifest}" >/dev/null 2>&1; then
  fail "invalid current Thorch commit was accepted"
fi

printf 'thorch nightly commit gate checks passed\n'
