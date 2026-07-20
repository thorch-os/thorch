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
manifest_cli="${script_dir}/package-manifest.py"
image_packages=()
if [[ -n "${THORCH_IMAGE_PACKAGES}" ]]; then
  read -r -a requested_image_packages <<< "${THORCH_IMAGE_PACKAGES}"
  requested_image_csv="$(IFS=,; printf '%s' "${requested_image_packages[*]}")"
  image_package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" select \
      --profile image --packages "${requested_image_csv}"
  )"
else
  image_package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" profile image
  )"
fi
[[ -n "${image_package_selection}" ]] || die "image package profile is empty"
mapfile -t image_packages <<< "${image_package_selection}"
cache_tmpfs_size_bytes=
root_fstype="${THORCH_ROOT_FSTYPE,,}"
root_mount_options=
root_fstab_pass=
root_img=
stock_kernel_firmware=(linux-aarch64)
mapfile -t stock_firmware_packages < <(thorch_stock_firmware_packages)
stock_kernel_firmware+=("${stock_firmware_packages[@]}")

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
# Match the known-good ROCKNIX qcom-abl image metadata: a legacy-bootable
# Microsoft Basic Data partition at the 16 MiB offset, not an EFI System
# Partition.
first_lba=32768
rocknix_boot_type="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

cache_tmpfs_enabled() {
  case "${THORCH_USER_CACHE_TMPFS_SIZE}" in
    ''|0|off|Off|OFF|false|False|FALSE|no|No|NO|none|None|NONE|disabled|Disabled|DISABLED)
      return 1
      ;;
  esac

  return 0
}

ssh_enabled() {
  case "${THORCH_ENABLE_SSH}" in
    1|on|On|ON|true|True|TRUE|yes|Yes|YES|enabled|Enabled|ENABLED)
      return 0
      ;;
    0|off|Off|OFF|false|False|FALSE|no|No|NO|disabled|Disabled|DISABLED)
      return 1
      ;;
    *)
      die "invalid THORCH_ENABLE_SSH: ${THORCH_ENABLE_SSH}; use 0 or 1"
      ;;
  esac
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
if ssh_enabled && [[ -z "${THORCH_PASSWORD}" ]]; then
  die "THORCH_ENABLE_SSH requires a non-empty THORCH_PASSWORD"
fi
[[ "${#image_packages[@]}" -gt 0 ]] || die "image package profile must contain at least one package"
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
  rocknix_kernel_artifacts_current "${kernel_dir}" &&
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

initialize_rootfs_passwords() {
  if [[ -n "${THORCH_PASSWORD}" ]]; then
    printf '%s:%s\nroot:%s\n' "${THORCH_USER}" "${THORCH_PASSWORD}" "${THORCH_PASSWORD}" |
      run_rootfs_cmd /usr/bin/chpasswd
    return
  fi

  # Firstboot calls chpasswd after the owner chooses a password. Until then,
  # keep both image accounts locked instead of shipping a shared credential.
  run_rootfs_cmd /usr/bin/usermod --lock "${THORCH_USER}"
  run_rootfs_cmd /usr/bin/usermod --lock root
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

stage_image_repository() {
  local pacman_build_conf="${rootfs_dir}/etc/pacman-thorch-build.conf"

  python3 "${script_dir}/check-package-repo.py" \
    "${repo_dir}" --require "${image_packages[@]}"
  rm -rf "${rootfs_dir}/var/cache/thorch"
  install -d "${rootfs_dir}/var/cache/thorch"
  rsync -a "${repo_dir}/" "${rootfs_dir}/var/cache/thorch/"
  [[ -e "${rootfs_dir}/var/cache/thorch/thorch.db" ]] ||
    die "local package repository has no thorch.db"

  # The imported ROCKNIX kernel does not currently provide Landlock. Keep
  # pacman's alpm download user and seccomp filter, but disable only the
  # unsupported filesystem portion of the download sandbox.
  sed -i \
    -e '/^DisableSandbox$/d' \
    -e '/^DisableSandboxFilesystem$/d' \
    -e 's/^#CheckSpace$/CheckSpace/' \
    "${rootfs_dir}/etc/pacman.conf"
  sed -i '/^\[options\]/a DisableSandboxFilesystem' \
    "${rootfs_dir}/etc/pacman.conf"
  cp "${rootfs_dir}/etc/pacman.conf" "${pacman_build_conf}"
  configure_pacman_for_emulated_build "${pacman_build_conf}"
  cat >> "${pacman_build_conf}" <<'EOF'

[thorch]
SigLevel = Optional TrustAll
Server = file:///var/cache/thorch
EOF
}

image_boot_transaction_hook_names=(
  60-thorch-boot-transaction-prepare.hook
  95-thorch-boot-transaction-commit.hook
)

mask_image_boot_transaction_hooks() {
  local hooks_dir="${rootfs_dir}/etc/pacman.d/hooks" hook target
  install -d "${hooks_dir}"
  for hook in "${image_boot_transaction_hook_names[@]}"; do
    target="${hooks_dir}/${hook}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -L "${target}" && "$(readlink "${target}")" == /dev/null ]] ||
        die "refusing to replace image-root hook override: ${target}"
    fi
    ln -sfn /dev/null "${target}"
  done
}

unmask_image_boot_transaction_hooks() {
  local hooks_dir="${rootfs_dir}/etc/pacman.d/hooks" hook target status=0
  for hook in "${image_boot_transaction_hook_names[@]}"; do
    target="${hooks_dir}/${hook}"
    if [[ -L "${target}" && "$(readlink "${target}")" == /dev/null ]]; then
      rm -f "${target}" || status=1
    elif [[ -e "${target}" || -L "${target}" ]]; then
      warn "image-root transaction hook mask changed unexpectedly: ${target}"
      status=1
    fi
  done
  return "${status}"
}

verify_image_package_versions() {
  local package expected installed

  for package in "${image_packages[@]}"; do
    expected="$(
      run_rootfs "LC_ALL=C pacman --config /etc/pacman-thorch-build.conf -Si thorch/${package} | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n1" |
        strip_control_output
    )"
    [[ -n "${expected}" ]] || die "local repository has no version for ${package}"
    installed="$(run_rootfs_cmd /usr/bin/pacman -Q -- "${package}" | strip_control_output)"
    [[ "${installed}" == "${package} ${expected}" ]] ||
      die "installed ${installed:-missing ${package}}, expected local ${package} ${expected}"
  done
}

install_image_packages() {
  local package package_args status=0
  local -a local_package_targets=()

  for package in "${image_packages[@]}"; do
    local_package_targets+=("thorch/${package}")
  done
  printf -v package_args '%q ' "${local_package_targets[@]}"
  # A reusable image root has no mounted /boot and is not its host's running
  # system. Suppress only Thorch's live-update hooks while pacman composes it;
  # the normal image path below generates and validates the payload explicitly.
  mask_image_boot_transaction_hooks
  # The pristine ALARM root contains a stock kernel and firmware. Remove them
  # in a dependency-checked transaction so pacman does not stop for conflict
  # prompts when installing their explicit Thorch replacements.
  remove_chroot_packages_if_installed \
    "${rootfs_dir}" "${rootfs_machine}" "${stock_kernel_firmware[@]}" || status=$?
  if [[ "${status}" -eq 0 ]]; then
    run_rootfs "pacman --config /etc/pacman-thorch-build.conf -Syu --noconfirm ${package_args}" || status=$?
  fi
  unmask_image_boot_transaction_hooks || status=$?
  [[ "${status}" -eq 0 ]] || return "${status}"
  verify_image_package_versions

  # Finish the legacy-mask migration only after pacman has released its lock.
  # The delivered image is then guarded for every future kernel transaction.
  run_rootfs "thorch-update-bootstrap >/dev/null"
}

unstage_image_repository() {
  rm -f "${rootfs_dir}/etc/pacman-thorch-build.conf" \
    "${rootfs_dir}/var/lib/pacman/sync/thorch.db" \
    "${rootfs_dir}/var/lib/pacman/sync/thorch.files"
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

remove_orphaned_dependencies() {
  run_rootfs "orphans=\$(pacman -Qdtq 2>/dev/null || true); [[ -z \"\${orphans}\" ]] || pacman -Rns --noconfirm \${orphans}"
}

ensure_btrfs_root_support() {
  [[ "${root_fstype}" == "btrfs" ]] || return 0
  run_rootfs "pacman --config /etc/pacman-thorch-build.conf -S --noconfirm --needed btrfs-progs"
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
  extract_alarm_rootfs "${rootfs_tar}" "${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  stage_qemu_for_rootfs
  configure_chroot_resolver "${rootfs_dir}"
  configure_alarm_pacman "${rootfs_dir}"
  mask_chroot_stock_kernel_hooks "${rootfs_dir}"

  log "installing Arch and Thorch packages"
  run_rootfs "pacman-key --init >/dev/null 2>&1 || true"
  run_rootfs "pacman-key --populate archlinuxarm >/dev/null 2>&1 || true"
  stage_image_repository
  log "installing local Thorch packages through the staged repository: ${image_packages[*]}"
  install_image_packages
  run_rootfs "gpgconf --kill all >/dev/null 2>&1 || pkill gpg-agent >/dev/null 2>&1 || true"
  ensure_btrfs_root_support
  remove_orphaned_dependencies
else
  stage_qemu_for_rootfs
  [[ -x "${rootfs_dir}/usr/bin/pacman" && -d "${rootfs_dir}/var/lib/pacman" ]] || die "cannot reuse missing rootfs: ${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  log "reusing populated rootfs ${rootfs_dir}"
  stage_image_repository
  log "refreshing the full system and local Thorch packages in reused rootfs"
  install_image_packages
  ensure_btrfs_root_support
  remove_orphaned_dependencies
fi
unstage_image_repository

mapfile -t installed_package_names < <(run_rootfs "pacman -Qq" | strip_control_output)
unexpected_stock_packages=()
for stock_package in "${stock_kernel_firmware[@]}"; do
  for installed_package in "${installed_package_names[@]}"; do
    if [[ "${installed_package}" == "${stock_package}" ]]; then
      unexpected_stock_packages+=("${stock_package}")
      break
    fi
  done
done
if (( ${#unexpected_stock_packages[@]} > 0 )); then
  die "unexpected stock kernel/firmware packages installed: ${unexpected_stock_packages[*]}"
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
initialize_rootfs_passwords
case "${THORCH_DEFAULT_SESSION}" in
  plasma|plasma-desktop) default_session_mode=desktop ;;
  mobile|plasma-mobile) default_session_mode=mobile ;;
  *) die "unsupported THORCH_DEFAULT_SESSION: ${THORCH_DEFAULT_SESSION}" ;;
esac
THORCH_SESSIONCTL_ROOT="${rootfs_dir}" \
  "${rootfs_dir}/usr/bin/thorch-sessionctl" set "${default_session_mode}" \
    --user "${THORCH_USER}" --no-restart >/dev/null
rsync -a "${rootfs_dir}/etc/skel/." "${rootfs_dir}/home/${THORCH_USER}/"
install -d -m 0700 "${rootfs_dir}/home/${THORCH_USER}/.cache"
rm -f \
  "${rootfs_dir}/etc/skel/Desktop/thorch-expand-root.desktop" \
  "${rootfs_dir}/etc/skel/Desktop/thorch-install-waydroid.desktop" \
  "${rootfs_dir}/home/${THORCH_USER}/Desktop/thorch-expand-root.desktop" \
  "${rootfs_dir}/home/${THORCH_USER}/Desktop/thorch-install-waydroid.desktop"
run_rootfs "chown -R ${THORCH_USER}:${THORCH_USER} /home/${THORCH_USER}"
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
rocknix_kernver="$(find "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
[[ -n "${rocknix_kernver}" ]] || die "unable to determine imported ROCKNIX kernel release"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/Image" \
  "${rootfs_dir}/usr/lib/modules/${rocknix_kernver}/Image"
run_rootfs "mkinitcpio -P"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/KERNEL" \
  "${rootfs_dir}/usr/share/thorch/rocknix/KERNEL"
run_rootfs "thorch-rebuild-abl-kernel --root-uuid ${root_uuid} --rootfstype ${root_fstype}"
rm -f "${rootfs_dir}/boot/Image"
run_rootfs "thorch-check-boot --root-uuid ${root_uuid}"
# Product service defaults live with their owning packages. Applying presets
# here composes those policies without duplicating the service inventory.
ssh_build_preset="${rootfs_dir}/etc/systemd/system-preset/00-thorch-build-ssh.preset"
rm -f "${ssh_build_preset}"
if ssh_enabled; then
  install -d "$(dirname "${ssh_build_preset}")"
  printf 'enable sshd.service\n' > "${ssh_build_preset}"
fi
systemctl --root "${rootfs_dir}" preset-all >/dev/null
systemctl --root "${rootfs_dir}" --global preset-all >/dev/null
rm -f "${ssh_build_preset}"
# Public images keep SSH disabled. Local bring-up builds may opt in only after
# explicitly provisioning a password above.
if ! ssh_enabled; then
  # Also remove any enablement inherited from an upstream rootfs preset.
  systemctl --root "${rootfs_dir}" disable sshd.service >/dev/null 2>&1 || true
fi
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

start=${first_lba}, size=${boot_sectors}, type=${rocknix_boot_type}, name=system, attrs=LegacyBIOSBootable
start=${root_start}, size=${root_sectors}, type=linux, name=storage
EOF

dd if="${boot_img}" of="${image}" bs="${sector_size}" seek="${first_lba}" conv=notrunc status=none
copy_sparse_file_into_image "${root_img}" "${image}" "$((root_start * sector_size))"
sync

"${script_dir}/check-thorch-image.sh" "${image}"
log "image ready: ${image}"
