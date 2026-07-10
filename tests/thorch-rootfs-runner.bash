#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
common="${root}/scripts/lib/common.sh"
image_builder="${root}/scripts/build-image.sh"
package_builder="${root}/scripts/build-packages.sh"
makefile="${root}/Makefile"
build_docs="${root}/docs/build.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'THORCH_ROOTFS_RUNNER="${THORCH_ROOTFS_RUNNER:-chroot}"' "${config}" ||
  fail "THORCH_ROOTFS_RUNNER does not default to chroot"

grep -q 'run_aarch64_rootfs_cmd()' "${common}" ||
  fail "common rootfs command runner is missing"

grep -q 'chroot "${rootfs}" /usr/bin/qemu-aarch64-static' "${common}" ||
  fail "plain chroot backend is missing"

grep -q 'systemd-nspawn)' "${common}" ||
  fail "systemd-nspawn opt-in backend is missing"

! grep -q 'require_cmd .*systemd-nspawn' "${image_builder}" ||
  fail "image builder still requires systemd-nspawn unconditionally"

! grep -q 'require_cmd .*systemd-nspawn' "${package_builder}" ||
  fail "package builder still requires systemd-nspawn unconditionally"

grep -q 'THORCH_ROOTFS_RUNNER' "${makefile}" ||
  fail "make sudo environment does not preserve THORCH_ROOTFS_RUNNER"

grep -q 'THORCH_ROOTFS_RUNNER=systemd-nspawn' "${build_docs}" ||
  fail "build docs do not document the nspawn fallback"

printf 'thorch rootfs runner checks passed\n'
