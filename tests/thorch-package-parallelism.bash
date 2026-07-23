#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
builder="${root}/scripts/build-packages.sh"
makefile="${root}/Makefile"
build_docs="${root}/docs/build.md"
kwin_pkgbuild="${root}/packages/kwin/PKGBUILD"
keyboard_pkgbuild="${root}/packages/plasma-keyboard/PKGBUILD"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'THORCH_PACKAGE_JOBS="${THORCH_PACKAGE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"' "${config}" ||
  fail "package build parallelism does not default to the online processor count"
grep -Fq 'MAKEFLAGS=-j${THORCH_PACKAGE_JOBS}' "${builder}" ||
  fail "makepkg builds do not receive the configured parallelism"
grep -Fq 'CMAKE_BUILD_PARALLEL_LEVEL=${THORCH_PACKAGE_JOBS}' "${builder}" ||
  fail "CMake package builds do not receive the configured parallelism"
grep -q 'THORCH_PACKAGE_JOBS' "${makefile}" ||
  fail "make does not preserve package build parallelism through sudo and Docker"
grep -q '`THORCH_PACKAGE_JOBS`' "${build_docs}" ||
  fail "package build parallelism is not documented"

for pkgbuild in "${kwin_pkgbuild}" "${keyboard_pkgbuild}"; do
  ! grep -Eq -- '--parallel[[:space:]]+[0-9]+' "${pkgbuild}" ||
    fail "${pkgbuild#"${root}/"} overrides THORCH_PACKAGE_JOBS with a fixed CMake job count"
done

failure="$(mktemp)"
trap 'rm -f "${failure}"' EXIT
if THORCH_KERNEL_JOBS=1 THORCH_PACKAGE_JOBS=0 \
    "${builder}" --validate-input-paths --packages thorch-bsp \
    >"${failure}" 2>&1; then
  fail "package builder accepted zero parallel jobs"
fi
grep -q 'THORCH_PACKAGE_JOBS must be a positive integer' "${failure}" ||
  fail "invalid package parallelism did not produce an actionable error"

printf 'thorch package parallelism checks passed\n'
