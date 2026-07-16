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

grep -q 'unshare --mount --propagation private' "${common}" ||
  fail "plain chroot proc mount is not isolated from the host namespace"

grep -q 'unmount_path_if_mounted "${rootfs}/proc"' "${common}" ||
  fail "plain chroot backend does not recover stale proc mounts"

grep -q 'cleanup_build_mounts_on_exit' "${image_builder}" ||
  fail "image builder does not clean temporary mounts on exit"

hook_fixture="$(mktemp -d)"
# shellcheck source=../scripts/lib/common.sh
source "${common}"
mask_chroot_stock_kernel_hooks "${hook_fixture}"
for hook in \
  60-mkinitcpio-remove.hook \
  60-thorch-boot-transaction-prepare.hook \
  90-mkinitcpio-install.hook \
  95-thorch-boot-transaction-commit.hook; do
  target="${hook_fixture}/etc/pacman.d/hooks/${hook}"
  [[ -L "${target}" && "$(readlink "${target}")" == /dev/null ]] ||
    fail "package root did not mask kernel hook ${hook}"
done
rm -rf "${hook_fixture}"

if (( EUID == 0 )); then
  mount_fixture="$(mktemp -d)"
  cleanup_mount_fixture() {
    if mountpoint -q "${mount_fixture}/proc"; then
      umount "${mount_fixture}/proc" >/dev/null 2>&1 || true
    fi
    rm -rf "${mount_fixture}"
  }
  trap cleanup_mount_fixture EXIT
  mkdir -p "${mount_fixture}/proc"
  mount -t proc proc "${mount_fixture}/proc"
  # shellcheck source=../scripts/lib/common.sh
  source "${common}"
  unmount_path_if_mounted "${mount_fixture}/proc" ||
    fail "stale proc mount cleanup failed"
  ! mountpoint -q "${mount_fixture}/proc" ||
    fail "stale proc mount cleanup left a mount behind"
fi

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
