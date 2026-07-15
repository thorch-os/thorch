#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-image.sh [--skip-package-build] [--reuse-rootfs]

Builds a Thorch Arch Linux ARM raw image for AYN Thor. The image contains a FAT
boot partition labelled ROCKNIX and a THORCH_ROOT root partition. It is intended
to boot as an SD installer/recovery system, then install itself internally.

This builder does not mount image partitions or bind-mount host /dev, /proc, or
/sys. Rootfs commands run through THORCH_ROOTFS_RUNNER, which defaults to plain
chroot with qemu-aarch64-static. The final GPT image is assembled from
standalone filesystem images.

THORCH_IMAGE_PACKAGES controls which local packages are built and installed.
THORCH_ROOT_FSTYPE controls the root filesystem type: ext4 or btrfs.
THORCH_USER_CACHE_TMPFS_SIZE controls the default user's ~/.cache tmpfs size;
set it to 0/off/none/disabled to keep cache writes on the root filesystem.

  --reuse-rootfs        continue from build/image-rootfs and reinstall current
                        local Thorch packages; useful for quick iteration.
EOF
}

skip_package_build=0
reuse_rootfs=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-package-build)
      skip_package_build=1
      shift
      ;;
    --reuse-rootfs)
      reuse_rootfs=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

require_root
require_cmd awk bsdtar cat curl dd du file find mcopy mdir mkfs.vfat numfmt python3 rsync sfdisk stat sync systemctl truncate uuidgen vercmp
require_rootfs_runner

root="$(repo_root)"
if [[ "${THORCH_BUILD_DIR}" = /* ]]; then
  build_dir="${THORCH_BUILD_DIR%/}"
else
  build_dir="${root}/${THORCH_BUILD_DIR}"
fi
cache_dir="${build_dir}/cache"
rootfs_dir="${build_dir}/image-rootfs"
boot_stage="${build_dir}/boot-stage"
boot_img="${build_dir}/boot.vfat"
image="${root}/${THORCH_OUTPUT_DIR}/thorch-arch-aarch64.img"
repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"
rootfs_tar="${cache_dir}/ArchLinuxARM-aarch64-latest.tar.gz"
rootfs_machine="$(nspawn_machine_name image-rootfs "${rootfs_dir}")"
read -r -a image_packages <<< "${THORCH_IMAGE_PACKAGES}"
cache_tmpfs_size_bytes=
root_fstype="${THORCH_ROOT_FSTYPE,,}"
root_mount_options=
root_fstab_pass=
root_img=
stock_kernel_firmware=(
  linux-aarch64
  linux-firmware
  linux-firmware-amdgpu
  linux-firmware-atheros
  linux-firmware-broadcom
  linux-firmware-cirrus
  linux-firmware-intel
  linux-firmware-mediatek
  linux-firmware-nvidia
  linux-firmware-other
  linux-firmware-qcom
  linux-firmware-qlogic
  linux-firmware-radeon
  linux-firmware-realtek
  linux-firmware-whence
)

build_mount_dirs=(
  "${build_dir}/btrfs-resize-root"
  "${build_dir}/btrfs-verify-root"
  "${build_dir}/btrfs-populate-root"
  "${rootfs_dir}/proc"
)

cleanup_build_mounts() {
  local mount_dir failed=0

  for mount_dir in "${build_mount_dirs[@]}"; do
    if mountpoint -q "${mount_dir}" && ! unmount_path_if_mounted "${mount_dir}"; then
      warn "unable to unmount build path: ${mount_dir}"
      failed=1
    fi
  done

  return "${failed}"
}

cleanup_build_mounts_on_exit() {
  local status="$?"

  trap - EXIT
  if ! cleanup_build_mounts; then
    status=1
  fi
  exit "${status}"
}

trap cleanup_build_mounts_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

boot_size="${THORCH_BOOT_SIZE:-512M}"
sector_size=512
first_lba=2048

cache_tmpfs_enabled() {
  case "${THORCH_USER_CACHE_TMPFS_SIZE}" in
    ''|0|off|Off|OFF|false|False|FALSE|no|No|NO|none|None|NONE|disabled|Disabled|DISABLED)
      return 1
      ;;
  esac

  return 0
}

configure_root_filesystem() {
  case "${root_fstype}" in
    ext4)
      require_cmd mkfs.ext4
      root_mount_options="rw,relatime"
      root_fstab_pass=1
      ;;
    btrfs)
      require_cmd btrfs mkfs.btrfs mount umount
      root_mount_options="${THORCH_BTRFS_MOUNT_OPTIONS:-rw,relatime,compress=zstd:1}"
      root_fstab_pass=0
      ;;
    *)
      die "unsupported THORCH_ROOT_FSTYPE: ${THORCH_ROOT_FSTYPE}; use ext4 or btrfs"
      ;;
  esac

  [[ "${root_mount_options}" != *[[:space:]]* ]] || \
    die "root mount options must not contain whitespace: ${root_mount_options}"
  root_img="${build_dir}/root.${root_fstype}"
}

[[ "${THORCH_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid THORCH_USER: ${THORCH_USER}"
[[ "${THORCH_PASSWORD}" != *$'\n'* ]] || die "THORCH_PASSWORD must not contain newlines"
[[ "${#image_packages[@]}" -gt 0 ]] || die "THORCH_IMAGE_PACKAGES must contain at least one package"
configure_root_filesystem
if cache_tmpfs_enabled; then
  cache_tmpfs_size_bytes="$(parse_size_bytes "${THORCH_USER_CACHE_TMPFS_SIZE}")" || \
    die "invalid THORCH_USER_CACHE_TMPFS_SIZE: ${THORCH_USER_CACHE_TMPFS_SIZE}"
  [[ "${cache_tmpfs_size_bytes}" =~ ^[0-9]+$ && "${cache_tmpfs_size_bytes}" -gt 0 ]] || \
    die "THORCH_USER_CACHE_TMPFS_SIZE must be greater than zero when enabled"
fi
thorch_user_q="$(printf '%q' "${THORCH_USER}")"

rocknix_kernel_artifacts_ready() {
  local kernel_dir="${root}/${THORCH_ROCKNIX_KERNEL_DIR}"
  [[ -f "${kernel_dir}/boot/Image" ]] &&
    [[ -f "${kernel_dir}/boot/KERNEL" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/a740_sqe.fw" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/gmu_gen70200.bin" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/sm8550/a740_zap.mbn" ]]
}

if [[ ! -d "${root}/${THORCH_FIRMWARE_DIR}/qcom/sm8550/ayn/thor" ]]; then
  log "syncing public ROCKNIX SM8550 firmware"
  "${script_dir}/sync-rocknix-sources.sh" --ref "${ROCKNIX_REF}" --with-firmware
fi
if ! rocknix_kernel_artifacts_ready; then
  log "syncing ROCKNIX runtime and source-building Thorch SM8550 kernel artifacts"
  "${script_dir}/sync-rocknix-kernel.sh"
fi
validate_rocknix_kernel_provenance "${root}/${THORCH_ROCKNIX_KERNEL_DIR}"

if [[ "${skip_package_build}" -eq 0 ]]; then
  image_packages_csv="$(IFS=,; printf '%s' "${image_packages[*]}")"
  "${script_dir}/build-packages.sh" --packages "${image_packages_csv}"
fi

[[ -d "${repo_dir}" ]] || die "missing local package repo: ${repo_dir}"

install -d "${cache_dir}" "${root}/${THORCH_OUTPUT_DIR}"
ensure_alarm_rootfs "${rootfs_tar}"

run_rootfs() {
  run_aarch64_rootfs_shell "${rootfs_dir}" "${rootfs_machine}" "$*"
}

run_rootfs_cmd() {
  run_aarch64_rootfs_cmd "${rootfs_dir}" "${rootfs_machine}" "$@"
}

set_rootfs_passwords() {
  printf '%s:%s\nroot:%s\n' "${THORCH_USER}" "${THORCH_PASSWORD}" "${THORCH_PASSWORD}" |
    run_rootfs_cmd /usr/bin/chpasswd
}

strip_control_output() {
  sed $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g' | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

round_up_bytes() {
  local bytes="$1"
  local quantum="$2"
  printf '%s\n' "$(( (bytes + quantum - 1) / quantum * quantum ))"
}

image_size_is_auto() {
  case "${THORCH_IMAGE_SIZE}" in
    auto|fit|shrinkwrap)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

calculate_image_bytes() {
  local boot_bytes="$1"
  local used_bytes headroom_bytes metadata_slack_bytes image_bytes
  local fixed_bytes auto_bytes align_bytes

  if ! image_size_is_auto; then
    parse_size_bytes "${THORCH_IMAGE_SIZE}"
    return
  fi

  used_bytes="$(du -sx --block-size=1 "${rootfs_dir}" | awk '{print $1}')"
  headroom_bytes="$(parse_size_bytes "${THORCH_IMAGE_AUTO_HEADROOM}")"
  metadata_slack_bytes=$((used_bytes / 20))
  fixed_bytes=$((first_lba * sector_size + boot_bytes + 34 * sector_size))
  auto_bytes=$((fixed_bytes + used_bytes + metadata_slack_bytes + headroom_bytes))
  align_bytes=$((1024 * 1024))
  image_bytes="$(round_up_bytes "${auto_bytes}" "${align_bytes}")"

  log "auto-sized raw image to $(numfmt --to=iec --suffix=B "${image_bytes}") ($(numfmt --to=iec --suffix=B "${used_bytes}") rootfs, $(numfmt --to=iec --suffix=B "${headroom_bytes}") headroom)"
  printf '%s\n' "${image_bytes}"
}

stage_image_packages() {
  local package_files=()
  local pkg

  install -d "${rootfs_dir}/var/cache/thorch"
  rm -f "${rootfs_dir}/var/cache/thorch/"*.pkg.tar.* 2>/dev/null || true

  for pkg in "${image_packages[@]}"; do
    package_files+=("$(best_repo_package_for "${pkg}")")
  done

  cp -f "${package_files[@]}" "${rootfs_dir}/var/cache/thorch/"
}

pkginfo_value() {
  local pkgfile="$1" key="$2"
  bsdtar -xOqf "${pkgfile}" .PKGINFO | awk -F ' = ' -v key="${key}" '$1 == key {print $2; exit}'
}

best_repo_package_for() {
  local pkg="$1" file pkgname version best="" best_version="" cmp

  shopt -s nullglob
  for file in "${repo_dir}/${pkg}-"*.pkg.tar.*; do
    pkgname="$(pkginfo_value "${file}" pkgname)"
    [[ "${pkgname}" == "${pkg}" ]] || continue
    version="$(pkginfo_value "${file}" pkgver)"
    [[ -n "${version}" ]] || die "unable to read package version from ${file}"

    if [[ -z "${best}" ]]; then
      best="${file}"
      best_version="${version}"
      continue
    fi

    cmp="$(vercmp "${version}" "${best_version}")"
    if (( cmp > 0 )) || { (( cmp == 0 )) && [[ "${file}" -nt "${best}" ]]; }; then
      best="${file}"
      best_version="${version}"
    fi
  done
  shopt -u nullglob

  [[ -n "${best}" ]] || die "missing built package for ${pkg} in ${repo_dir}"
  printf '%s\n' "${best}"
}

cleanup_rootfs_for_image() {
  log "removing build-time caches from image rootfs"
  rm -f "${rootfs_dir}/usr/bin/qemu-aarch64-static"
  rm -rf "${rootfs_dir}/var/cache/pacman/pkg/"*
  rm -rf "${rootfs_dir}/var/cache/thorch/"*
  rm -rf "${rootfs_dir}/tmp/"* "${rootfs_dir}/var/tmp/"*
  rm -f "${rootfs_dir}/var/log/"*.log
  install -d -m 0755 "${rootfs_dir}/var/cache/pacman/pkg" "${rootfs_dir}/var/cache/thorch"
  install -d -m 1777 "${rootfs_dir}/tmp" "${rootfs_dir}/var/tmp"
}

stage_qemu_for_rootfs() {
  case "$(uname -m)" in
    aarch64|arm64)
      return 0
      ;;
  esac

  [[ -x "${rootfs_dir}/usr/bin/qemu-aarch64-static" ]] ||
    cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/"
}

remove_stock_firmware() {
  run_rootfs "installed_stock=\$(pacman -Qq ${stock_kernel_firmware[*]} 2>/dev/null || true); [[ -z \"\${installed_stock}\" ]] || pacman -Rdd --noconfirm \${installed_stock}"
}

remove_orphaned_dependencies() {
  run_rootfs "orphans=\$(pacman -Qdtq 2>/dev/null || true); [[ -z \"\${orphans}\" ]] || pacman -Rns --noconfirm \${orphans}"
}

ensure_btrfs_root_support() {
  [[ "${root_fstype}" == "btrfs" ]] || return 0
  run_rootfs "pacman -S --noconfirm --needed btrfs-progs"
}

ensure_mkinitcpio_module() {
  local conf="$1" module="$2"

  if ! grep -Eq "^#?MODULES=" "${conf}"; then
    printf 'MODULES=(%s)\n' "${module}" >> "${conf}"
    return
  fi

  if grep -Eq "^#?MODULES=.*(^|[[:space:](])${module}([[:space:])]|$)" "${conf}"; then
    return
  fi

  sed -i -E "s/^#?MODULES=\(([^)]*)\)/MODULES=(\1 ${module})/" "${conf}"
}

prepare_mkinitcpio_config() {
  sed -i 's/^#\?HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap consolefont block thorch-firmware thorch-sd-prefer filesystems fsck)/' \
    "${rootfs_dir}/etc/mkinitcpio.conf"
  if [[ "${root_fstype}" == "btrfs" ]]; then
    ensure_mkinitcpio_module "${rootfs_dir}/etc/mkinitcpio.conf" btrfs
  fi
}

create_root_filesystem_image() {
  case "${root_fstype}" in
    ext4)
      mkfs.ext4 -F -L THORCH_ROOT -U "${root_uuid}" -d "${rootfs_dir}" "${root_img}" >/dev/null
      ;;
    btrfs)
      mkfs.btrfs -f -L THORCH_ROOT -U "${root_uuid}" \
        --byte-count "${root_bytes}" \
        "${root_img}" >/dev/null
      populate_btrfs_image
      ;;
  esac
}

populate_btrfs_image() {
  local populate_mount="${build_dir}/btrfs-populate-root"
  local min_size shrink_size

  rm -rf "${populate_mount}"
  install -d "${populate_mount}"
  if ! mount -o "loop,${root_mount_options}" "${root_img}" "${populate_mount}"; then
    rmdir "${populate_mount}" 2>/dev/null || true
    die "unable to mount ${root_img} for btrfs population"
  fi
  if ! rsync -aHAX --numeric-ids "${rootfs_dir}/" "${populate_mount}/"; then
    umount "${populate_mount}" >/dev/null 2>&1 || true
    rmdir "${populate_mount}" 2>/dev/null || true
    die "unable to populate btrfs root image"
  fi
  sync "${populate_mount}"

  if image_size_is_auto; then
    min_size="$(btrfs inspect-internal min-dev-size "${populate_mount}" | awk 'NR == 1 {print $1}')"
    [[ "${min_size}" =~ ^[0-9]+$ && "${min_size}" -gt 0 ]] || {
      umount "${populate_mount}" >/dev/null 2>&1 || true
      rmdir "${populate_mount}" 2>/dev/null || true
      die "unable to determine minimum populated btrfs size"
    }
    shrink_size="$(round_up_bytes "$((min_size + 64 * 1024 * 1024))" $((1024 * 1024)))"
    if ! btrfs filesystem resize "${shrink_size}" "${populate_mount}" >/dev/null; then
      umount "${populate_mount}" >/dev/null 2>&1 || true
      rmdir "${populate_mount}" 2>/dev/null || true
      die "unable to shrink populated btrfs root image"
    fi
  fi

  umount "${populate_mount}"
  rmdir "${populate_mount}" 2>/dev/null || true
  if image_size_is_auto; then
    truncate -s "${shrink_size}" "${root_img}"
  fi
}

verify_btrfs_image_readable() {
  local verify_mount="${build_dir}/btrfs-verify-root"

  rm -rf "${verify_mount}"
  install -d "${verify_mount}"
  if ! mount -o loop,ro "${root_img}" "${verify_mount}"; then
    rmdir "${verify_mount}" 2>/dev/null || true
    die "unable to mount ${root_img} for full data verification"
  fi
  if ! find "${verify_mount}" -xdev -type f -exec cat -- {} + >/dev/null; then
    umount "${verify_mount}" >/dev/null 2>&1 || true
    rmdir "${verify_mount}" 2>/dev/null || true
    die "btrfs root image contains unreadable file data"
  fi
  umount "${verify_mount}"
  rmdir "${verify_mount}" 2>/dev/null || true
}

resize_btrfs_image_to_max() {
  local size_bytes="$1"
  local resize_mount="${build_dir}/btrfs-resize-root"

  truncate -s "${size_bytes}" "${root_img}"
  rm -rf "${resize_mount}"
  install -d "${resize_mount}"
  if ! mount -o loop,rw "${root_img}" "${resize_mount}"; then
    rmdir "${resize_mount}" 2>/dev/null || true
    die "unable to mount ${root_img} for btrfs resize"
  fi
  if ! btrfs filesystem resize max "${resize_mount}" >/dev/null; then
    umount "${resize_mount}" >/dev/null 2>&1 || true
    rmdir "${resize_mount}" 2>/dev/null || true
    die "unable to resize btrfs root image to $(numfmt --to=iec --suffix=B "${size_bytes}")"
  fi
  umount "${resize_mount}"
  rmdir "${resize_mount}" 2>/dev/null || true
}

copy_sparse_file_into_image() {
  local src="$1" dst="$2" offset="$3"

  python3 - "${src}" "${dst}" "${offset}" <<'PY'
import errno
import os
import sys

src, dst, offset_text = sys.argv[1:]
offset = int(offset_text)
chunk_size = 16 * 1024 * 1024
unsupported = {
    errno.EINVAL,
    getattr(errno, "ENOTSUP", errno.EINVAL),
    getattr(errno, "EOPNOTSUPP", errno.EINVAL),
}

size = os.stat(src).st_size
with open(src, "rb", buffering=0) as src_file, open(dst, "r+b", buffering=0) as dst_file:
    src_fd = src_file.fileno()
    dst_fd = dst_file.fileno()
    pos = 0
    while pos < size:
        try:
            data = os.lseek(src_fd, pos, os.SEEK_DATA)
        except OSError as exc:
            if exc.errno == errno.ENXIO:
                break
            if exc.errno in unsupported:
                data = pos
            else:
                raise

        if data >= size:
            break

        try:
            hole = os.lseek(src_fd, data, os.SEEK_HOLE)
        except OSError as exc:
            if exc.errno in unsupported:
                hole = size
            else:
                raise

        end = min(hole, size)
        os.lseek(src_fd, data, os.SEEK_SET)
        os.lseek(dst_fd, offset + data, os.SEEK_SET)
        remaining = end - data
        while remaining > 0:
            buf = os.read(src_fd, min(chunk_size, remaining))
            if not buf:
                raise OSError(f"unexpected EOF while copying {src}")
            view = memoryview(buf)
            while view:
                written = os.write(dst_fd, view)
                view = view[written:]
            remaining -= len(buf)
        pos = end
PY
}

log "preparing image rootfs"
cleanup_build_mounts || die "unable to clean stale image build mounts"
rm -rf "${boot_stage}" "${boot_img}" "${build_dir}/root.ext4" "${build_dir}/root.btrfs"
if [[ "${reuse_rootfs}" -eq 0 ]]; then
  rm -rf "${rootfs_dir}"
  install -d "${rootfs_dir}"
  extract_alarm_rootfs_without_stock_kernel_firmware "${rootfs_tar}" "${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  stage_qemu_for_rootfs
  configure_chroot_resolver "${rootfs_dir}"
  configure_alarm_pacman "${rootfs_dir}"
  mask_chroot_stock_kernel_hooks "${rootfs_dir}"

  log "installing Arch and Thorch packages"
  run_rootfs "pacman-key --init >/dev/null 2>&1 || true"
  run_rootfs "pacman-key --populate archlinuxarm >/dev/null 2>&1 || true"
  remove_stock_firmware
  run_rootfs "pacman -Syu --noconfirm"
  run_rootfs "gpgconf --kill all >/dev/null 2>&1 || pkill gpg-agent >/dev/null 2>&1 || true"

  log "installing local Thorch packages: ${image_packages[*]}"
  stage_image_packages
  run_rootfs "pacman -U --noconfirm --overwrite 'usr/lib/firmware/ath12k/WCN7850/hw2.0/*' --overwrite 'usr/share/vulkan/icd.d/freedreno_icd*.json' --overwrite 'usr/lib/libvulkan_freedreno.so' --overwrite 'usr/lib/libdisplay-info.so.2' --overwrite 'usr/lib/libdisplay-info.so.0.2.0' --overwrite 'usr/share/fex-emu/libvulkan_freedreno.so' /var/cache/thorch/*.pkg.tar.*"
  ensure_btrfs_root_support
  remove_stock_firmware
  remove_orphaned_dependencies
else
  stage_qemu_for_rootfs
  [[ -x "${rootfs_dir}/usr/bin/pacman" && -d "${rootfs_dir}/var/lib/pacman" ]] || die "cannot reuse missing rootfs: ${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  log "reusing populated rootfs ${rootfs_dir}"
  stage_image_packages
  log "refreshing local Thorch packages in reused rootfs"
  run_rootfs "pacman -U --noconfirm --overwrite 'usr/lib/firmware/ath12k/WCN7850/hw2.0/*' --overwrite 'usr/share/vulkan/icd.d/freedreno_icd*.json' --overwrite 'usr/lib/libvulkan_freedreno.so' --overwrite 'usr/lib/libdisplay-info.so.2' --overwrite 'usr/lib/libdisplay-info.so.0.2.0' --overwrite 'usr/share/fex-emu/libvulkan_freedreno.so' /var/cache/thorch/*.pkg.tar.*"
  ensure_btrfs_root_support
  remove_stock_firmware
  remove_orphaned_dependencies
fi

unexpected_firmware="$(run_rootfs "pacman -Qq ${stock_kernel_firmware[*]} 2>/dev/null || true" | strip_control_output)"
if [[ -n "${unexpected_firmware}" ]]; then
  die "unexpected generic/GPU firmware packages installed: ${unexpected_firmware//$'\n'/ }"
fi
run_rootfs "test -f /usr/lib/firmware/qcom/a740_sqe.fw && test -f /usr/lib/firmware/qcom/gmu_gen70200.bin && test -f /usr/lib/firmware/qcom/sm8550/a740_zap.mbn" || \
  die "missing ROCKNIX Adreno firmware files"

log "configuring Thorch user and services"
cat > "${rootfs_dir}/etc/locale.conf" <<'EOF'
LANG=C.UTF-8
EOF
run_rootfs "for g in wheel adm video input audio storage render; do getent group \$g >/dev/null || groupadd -r \$g; done"
run_rootfs "id ${thorch_user_q} >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel,adm,video,input,audio,storage,render ${thorch_user_q}"
if [[ "${THORCH_USER}" != "alarm" ]]; then
  run_rootfs "if id alarm >/dev/null 2>&1; then userdel -r alarm >/dev/null 2>&1 || usermod -L -s /usr/bin/nologin alarm; fi"
fi
set_rootfs_passwords
install -d "${rootfs_dir}/etc/sudoers.d"
cat > "${rootfs_dir}/etc/sudoers.d/10-thorch-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 "${rootfs_dir}/etc/sudoers.d/10-thorch-wheel"
sed -i "s/^User=.*/User=${THORCH_USER}/" "${rootfs_dir}/etc/sddm.conf.d/10-thorch.conf"
if [[ "${THORCH_DEFAULT_SESSION}" == "plasma" || "${THORCH_DEFAULT_SESSION}" == "plasma-desktop" ]]; then
  sed -i 's/^Session=.*/Session=plasma.desktop/' "${rootfs_dir}/etc/sddm.conf.d/10-thorch.conf"
fi
rsync -a "${rootfs_dir}/etc/skel/." "${rootfs_dir}/home/${THORCH_USER}/"
install -d -m 0700 "${rootfs_dir}/home/${THORCH_USER}/.cache"
rm -f \
  "${rootfs_dir}/etc/skel/Desktop/thorch-expand-root.desktop" \
  "${rootfs_dir}/etc/skel/Desktop/thorch-install-waydroid.desktop" \
  "${rootfs_dir}/home/${THORCH_USER}/Desktop/thorch-expand-root.desktop" \
  "${rootfs_dir}/home/${THORCH_USER}/Desktop/thorch-install-waydroid.desktop"
run_rootfs "chown -R ${THORCH_USER}:${THORCH_USER} /home/${THORCH_USER}"
run_rootfs "systemctl disable systemd-networkd.service systemd-networkd-wait-online.service systemd-networkd.socket systemd-networkd-varlink.socket systemd-networkd-varlink-metrics.socket systemd-networkd-resolve-hook.socket >/dev/null 2>&1 || true"
run_rootfs "systemctl mask systemd-networkd.service systemd-networkd-wait-online.service systemd-networkd.socket systemd-networkd-varlink.socket systemd-networkd-varlink-metrics.socket systemd-networkd-resolve-hook.socket >/dev/null 2>&1 || true"

rm -f "${rootfs_dir}/etc/mkinitcpio.d/linux-aarch64.preset"
# The ALARM tarball may not include an empty /boot entry once boot contents are excluded.
install -d "${rootfs_dir}/boot"
root_uuid="$(uuidgen)"
fat_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
fat_id="${fat_id^^}"
boot_uuid="${fat_id:0:4}-${fat_id:4:4}"
cache_tmpfs_fstab=
if cache_tmpfs_enabled; then
  thorch_uid="$(run_rootfs_cmd /usr/bin/id -u "${THORCH_USER}" | strip_control_output)"
  thorch_gid="$(run_rootfs_cmd /usr/bin/id -g "${THORCH_USER}" | strip_control_output)"
  [[ "${thorch_uid}" =~ ^[0-9]+$ && "${thorch_gid}" =~ ^[0-9]+$ ]] || \
    die "unable to resolve numeric uid/gid for ${THORCH_USER}"
  cache_tmpfs_fstab="tmpfs /home/${THORCH_USER}/.cache tmpfs rw,nosuid,nodev,relatime,size=${cache_tmpfs_size_bytes},mode=0700,uid=${thorch_uid},gid=${thorch_gid} 0 0"
fi

cat > "${rootfs_dir}/etc/fstab" <<EOF
UUID=${root_uuid} / ${root_fstype} ${root_mount_options} 0 ${root_fstab_pass}
UUID=${boot_uuid} /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2
${cache_tmpfs_fstab}
EOF
prepare_mkinitcpio_config

rocknix_kernver="$(find "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
[[ -n "${rocknix_kernver}" ]] || die "unable to determine imported ROCKNIX kernel release"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/Image" \
  "${rootfs_dir}/usr/lib/modules/${rocknix_kernver}/Image"
run_rootfs "mkinitcpio -P"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/KERNEL" \
  "${rootfs_dir}/usr/share/thorch/rocknix/KERNEL"
run_rootfs "thorch-rebuild-abl-kernel --root-uuid ${root_uuid} --rootfstype ${root_fstype}"
rm -f "${rootfs_dir}/boot/Image"
run_rootfs "thorch-check-boot"
rootfs_services=(
  bluetooth.service
  NetworkManager.service
  sshd.service
  sddm.service
  systemd-binfmt.service
  thorch-rgb.service
  thorch-rgb-battery.service
  thorch-rgb-poweroff.service
  thorch-fancontrol.service
  thorch-touchscreen-setup.service
  thorch-session-recovery.service
  thorch-inputd.service
  thorch-hw-defaults.service
  thorch-debug-report.service
)
if [[ -f "${rootfs_dir}/usr/lib/systemd/system/inputplumber.service" ||
  -f "${rootfs_dir}/etc/systemd/system/inputplumber.service" ]]; then
  rootfs_services+=(inputplumber.service)
fi
systemctl --root "${rootfs_dir}" enable "${rootfs_services[@]}" >/dev/null
cleanup_rootfs_for_image

log "creating boot filesystem image"
install -d "${boot_stage}"
rsync -a "${rootfs_dir}/boot/." "${boot_stage}/"
find "${rootfs_dir}/boot" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
truncate -s "${boot_size}" "${boot_img}"
mkfs.vfat -F 32 -n ROCKNIX -i "${fat_id}" "${boot_img}" >/dev/null
shopt -s nullglob dotglob
boot_entries=("${boot_stage}"/*)
if [[ "${#boot_entries[@]}" -gt 0 ]]; then
  mcopy -s -o -i "${boot_img}" "${boot_entries[@]}" ::/
fi
shopt -u nullglob dotglob

log "creating root filesystem image"
boot_bytes="$(parse_size_bytes "${boot_size}")"
image_bytes="$(calculate_image_bytes "${boot_bytes}")"
image_sectors=$((image_bytes / sector_size))
boot_sectors=$(((boot_bytes + sector_size - 1) / sector_size))
root_start=$((first_lba + boot_sectors))
root_sectors=$((image_sectors - root_start - 34))
root_bytes=$((root_sectors * sector_size))
[[ "${root_sectors}" -gt 0 ]] || die "image size ${THORCH_IMAGE_SIZE} is too small"

truncate -s "${root_bytes}" "${root_img}"
create_root_filesystem_image
root_img_bytes="$(stat -c '%s' "${root_img}")"
root_img_sectors=$(((root_img_bytes + sector_size - 1) / sector_size))
if image_size_is_auto && [[ "${root_fstype}" == "btrfs" ]]; then
  headroom_bytes="$(parse_size_bytes "${THORCH_IMAGE_AUTO_HEADROOM}")"
  root_bytes="$(round_up_bytes "$((root_img_bytes + headroom_bytes))" $((1024 * 1024)))"
  root_sectors=$(((root_bytes + sector_size - 1) / sector_size))
  root_bytes=$((root_sectors * sector_size))
  resize_btrfs_image_to_max "${root_bytes}"
  root_img_bytes="$(stat -c '%s' "${root_img}")"
  root_img_sectors=$(((root_img_bytes + sector_size - 1) / sector_size))
  image_sectors=$((root_start + root_sectors + 34))
  image_bytes=$((image_sectors * sector_size))
  log "auto-sized btrfs raw image to $(numfmt --to=iec --suffix=B "${image_bytes}") ($(numfmt --to=iec --suffix=B "${root_img_bytes}") root filesystem, $(numfmt --to=iec --suffix=B "${headroom_bytes}") headroom)"
elif (( root_img_sectors > root_sectors )); then
  image_size_is_auto || die "root filesystem image needs $(numfmt --to=iec --suffix=B "${root_img_bytes}") but THORCH_IMAGE_SIZE=${THORCH_IMAGE_SIZE} only reserved $(numfmt --to=iec --suffix=B "${root_bytes}")"
  root_sectors="${root_img_sectors}"
  root_bytes=$((root_sectors * sector_size))
  image_sectors=$((root_start + root_sectors + 34))
  image_bytes=$((image_sectors * sector_size))
  log "expanded auto-sized raw image to $(numfmt --to=iec --suffix=B "${image_bytes}") after ${root_fstype} root image creation"
fi
if [[ "${root_fstype}" == "btrfs" ]]; then
  log "force-reading btrfs root image data"
  verify_btrfs_image_readable
fi

log "assembling raw GPT image ${image}"
rm -f "${image}"
truncate -s "${image_bytes}" "${image}"
sfdisk "${image}" >/dev/null <<EOF
label: gpt
unit: sectors

start=${first_lba}, size=${boot_sectors}, type=uefi
start=${root_start}, size=${root_sectors}, type=linux
EOF

dd if="${boot_img}" of="${image}" bs="${sector_size}" seek="${first_lba}" conv=notrunc status=none
copy_sparse_file_into_image "${root_img}" "${image}" "$((root_start * sector_size))"
sync

"${script_dir}/check-thorch-image.sh" "${image}"
log "image ready: ${image}"
