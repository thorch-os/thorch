#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
makefile="${root}/Makefile"
image_builder="${root}/scripts/build-image.sh"
build_docs="${root}/docs/build.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'THORCH_USER_CACHE_TMPFS_SIZE="${THORCH_USER_CACHE_TMPFS_SIZE:-512M}"' "${config}" ||
  fail "default cache tmpfs size is not configured"

grep -q 'THORCH_USER_CACHE_TMPFS_SIZE' "${makefile}" ||
  fail "make build does not preserve THORCH_USER_CACHE_TMPFS_SIZE through sudo"

grep -q 'cache_tmpfs_enabled()' "${image_builder}" ||
  fail "image builder does not gate cache tmpfs creation"

grep -q 'size=${cache_tmpfs_size_bytes}' "${image_builder}" ||
  fail "image builder does not use validated byte size in fstab"

grep -q 'tmpfs /home/${THORCH_USER}/.cache tmpfs' "${image_builder}" ||
  fail "image builder does not mount default user cache as tmpfs"

grep -q 'THORCH_USER_CACHE_TMPFS_SIZE=512M' "${build_docs}" ||
  fail "build docs do not mention the default cache tmpfs size"

printf 'thorch image cache tmpfs checks passed\n'
