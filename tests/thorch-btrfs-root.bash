#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
makefile="${root}/Makefile"
dockerfile="${root}/Dockerfile"
image_builder="${root}/scripts/build-image.sh"
installer="${root}/packages/thorch-installer/payload/usr/bin/thorch-install-internal"
expand_root="${root}/packages/thorch-installer/payload/usr/bin/thorch-expand-root"
sd_hook="${root}/packages/thorch-bsp/payload/usr/lib/initcpio/hooks/thorch-sd-prefer"
mkinitcpio_policy="${root}/packages/thorch-bsp/payload/etc/mkinitcpio.conf.d/90-thorch.conf"
linux_pkgbuild="${root}/packages/linux-thorch/PKGBUILD"
firstbootctl="${root}/packages/thorch-firstboot/payload/usr/bin/thorch-firstbootctl"
nightly="${root}/.github/workflows/nightly.yml"
build_docs="${root}/docs/build.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'THORCH_ROOT_FSTYPE="${THORCH_ROOT_FSTYPE:-ext4}"' "${config}" ||
  fail "config does not define ext4 as the conservative default root filesystem"

grep -q 'THORCH_BTRFS_MOUNT_OPTIONS="${THORCH_BTRFS_MOUNT_OPTIONS:-rw,relatime,compress=zstd:1}"' "${config}" ||
  fail "config does not define default btrfs mount options"

grep -q 'THORCH_ROOT_FSTYPE' "${makefile}" ||
  fail "Makefile does not preserve THORCH_ROOT_FSTYPE through sudo/Docker"

grep -q 'btrfs-progs' "${dockerfile}" ||
  fail "Docker builder image does not install btrfs-progs"

grep -q 'mkfs.btrfs' "${image_builder}" ||
  fail "image builder does not create btrfs root filesystems"

grep -q 'rsync -aHAX --numeric-ids "${rootfs_dir}/" "${populate_mount}/"' "${image_builder}" ||
  fail "image builder does not populate btrfs through the kernel mount path"

! grep -q -- '--compress zstd:1' "${image_builder}" ||
  fail "image builder still uses corruptible offline btrfs rootdir compression"

! grep -q -- '--rootdir "${rootfs_dir}"' "${image_builder}" ||
  fail "image builder still uses the corruptible offline btrfs population path"

grep -q 'btrfs inspect-internal min-dev-size' "${image_builder}" ||
  fail "auto-sized btrfs images are not shrunk after mounted population"

grep -q -- '--byte-count "${root_bytes}"' "${image_builder}" ||
  fail "fixed-size btrfs images do not constrain mkfs.btrfs to the reserved root partition size"

grep -q 'resize_btrfs_image_to_max' "${image_builder}" ||
  fail "auto-sized btrfs images are not resized to the configured headroom"

grep -q 'verify_btrfs_image_readable' "${image_builder}" ||
  fail "image builder does not force-read populated btrfs data"

grep -q 'thorch-rebuild-abl-kernel --root-uuid ${root_uuid} --rootfstype ${root_fstype}' "${image_builder}" ||
  fail "image builder does not pass rootfstype through to /KERNEL"

grep -Eq '^MODULES\+?=.*(^|[[:space:](])btrfs([[:space:])]|$)' "${mkinitcpio_policy}" ||
  fail "package-owned mkinitcpio policy does not add the btrfs root module"

! grep -q '^ALL_config=' "${linux_pkgbuild}" ||
  fail "linux-thorch preset bypasses package-owned mkinitcpio drop-ins"

grep -q 'supported_root_fstype()' "${installer}" ||
  fail "internal installer does not validate supported root filesystems"

grep -q 'mkfs.btrfs' "${installer}" ||
  fail "internal installer cannot format btrfs roots"

grep -q 'rootfstype "${root_fstype}"' "${installer}" ||
  fail "internal installer does not rebuild /KERNEL with the selected rootfstype"

grep -q 'installed root is missing package-owned Thorch mkinitcpio policy' "${installer}" ||
  fail "internal installer does not require the packaged mkinitcpio policy"

grep -q 'btrfs filesystem resize max /' "${expand_root}" ||
  fail "root expander does not grow btrfs roots online"

grep -q '\[ "$fstype" = "btrfs" \]' "${sd_hook}" ||
  fail "initramfs SD root hook does not detect btrfs THORCH_ROOT"

grep -q 'SUPPORTED_ROOT_FSTYPES = {"ext4", "btrfs"}' "${firstbootctl}" ||
  fail "firstboot helper does not allow btrfs SD roots"

grep -q 'root_fstype:' "${nightly}" ||
  fail "nightly workflow does not expose a btrfs root filesystem option"

grep -q 'THORCH_ROOT_FSTYPE=btrfs' "${build_docs}" ||
  fail "build docs do not document the btrfs root option"

printf 'thorch btrfs root checks passed\n'
