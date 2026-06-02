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
boot partition labelled ROCKNIX and an ext4 root partition. It is intended to
boot as an SD installer/recovery system, then install itself internally.

This builder does not mount image partitions or bind-mount host /dev, /proc, or
/sys. Rootfs commands run through systemd-nspawn, and the final GPT image is
assembled from standalone filesystem images.

THORCH_IMAGE_PACKAGES controls which local packages are built and installed.

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
require_cmd awk bsdtar curl dd du file mcopy mdir mkfs.ext4 mkfs.vfat numfmt qemu-aarch64-static rsync sfdisk systemctl systemd-nspawn truncate uuidgen

root="$(repo_root)"
build_dir="${root}/${THORCH_BUILD_DIR}"
cache_dir="${build_dir}/cache"
rootfs_dir="${build_dir}/image-rootfs"
boot_stage="${build_dir}/boot-stage"
boot_img="${build_dir}/boot.vfat"
root_img="${build_dir}/root.ext4"
image="${root}/${THORCH_OUTPUT_DIR}/thorch-arch-aarch64.img"
repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"
rootfs_tar="${cache_dir}/ArchLinuxARM-aarch64-latest.tar.gz"
rootfs_machine="$(nspawn_machine_name image-rootfs "${rootfs_dir}")"
read -r -a image_packages <<< "${THORCH_IMAGE_PACKAGES}"
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

boot_size="${THORCH_BOOT_SIZE:-512M}"
sector_size=512
first_lba=2048

[[ "${THORCH_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid THORCH_USER: ${THORCH_USER}"
[[ "${THORCH_PASSWORD}" != *$'\n'* ]] || die "THORCH_PASSWORD must not contain newlines"
[[ "${#image_packages[@]}" -gt 0 ]] || die "THORCH_IMAGE_PACKAGES must contain at least one package"
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
  rm -rf "${rootfs_dir}/run/systemd/nspawn"
  systemd-nspawn \
    --quiet \
    --pipe \
    --machine="${rootfs_machine}" \
    --register=no \
    --directory="${rootfs_dir}" \
    /usr/bin/qemu-aarch64-static /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 /bin/bash --noprofile --norc -c "$*"
}

run_rootfs_cmd() {
  rm -rf "${rootfs_dir}/run/systemd/nspawn"
  systemd-nspawn \
    --quiet \
    --pipe \
    --machine="${rootfs_machine}" \
    --register=no \
    --directory="${rootfs_dir}" \
    /usr/bin/qemu-aarch64-static /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 "$@"
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
  local pkg matches

  install -d "${rootfs_dir}/var/cache/thorch"
  rm -f "${rootfs_dir}/var/cache/thorch/"*.pkg.tar.* 2>/dev/null || true

  shopt -s nullglob
  for pkg in "${image_packages[@]}"; do
    matches=("${repo_dir}/${pkg}-"*.pkg.tar.*)
    [[ "${#matches[@]}" -gt 0 ]] || die "missing built package for ${pkg} in ${repo_dir}"
    package_files+=("${matches[@]}")
  done
  shopt -u nullglob

  cp -f "${package_files[@]}" "${rootfs_dir}/var/cache/thorch/"
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

remove_stock_firmware() {
  run_rootfs "installed_stock=\$(pacman -Qq ${stock_kernel_firmware[*]} 2>/dev/null || true); [[ -z \"\${installed_stock}\" ]] || pacman -Rdd --noconfirm \${installed_stock}"
}

remove_orphaned_dependencies() {
  run_rootfs "orphans=\$(pacman -Qdtq 2>/dev/null || true); [[ -z \"\${orphans}\" ]] || pacman -Rns --noconfirm \${orphans}"
}

log "preparing image rootfs"
rm -rf "${boot_stage}" "${boot_img}" "${root_img}"
if [[ "${reuse_rootfs}" -eq 0 ]]; then
  rm -rf "${rootfs_dir}"
  install -d "${rootfs_dir}"
  extract_alarm_rootfs_without_stock_kernel_firmware "${rootfs_tar}" "${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/"
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
  remove_stock_firmware
  remove_orphaned_dependencies
else
  [[ -x "${rootfs_dir}/usr/bin/qemu-aarch64-static" ]] || cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/"
  [[ -x "${rootfs_dir}/usr/bin/pacman" && -d "${rootfs_dir}/var/lib/pacman" ]] || die "cannot reuse missing rootfs: ${rootfs_dir}"
  repair_alarm_usrmerge_links "${rootfs_dir}"
  log "reusing populated rootfs ${rootfs_dir}"
  stage_image_packages
  log "refreshing local Thorch packages in reused rootfs"
  run_rootfs "pacman -U --noconfirm --overwrite 'usr/lib/firmware/ath12k/WCN7850/hw2.0/*' --overwrite 'usr/share/vulkan/icd.d/freedreno_icd*.json' --overwrite 'usr/lib/libvulkan_freedreno.so' --overwrite 'usr/lib/libdisplay-info.so.2' --overwrite 'usr/lib/libdisplay-info.so.0.2.0' --overwrite 'usr/share/fex-emu/libvulkan_freedreno.so' /var/cache/thorch/*.pkg.tar.*"
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

cat > "${rootfs_dir}/etc/fstab" <<EOF
UUID=${root_uuid} / ext4 rw,relatime 0 1
UUID=${boot_uuid} /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2
EOF
sed -i 's/^#\?HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap consolefont block thorch-firmware thorch-sd-prefer filesystems fsck)/' \
  "${rootfs_dir}/etc/mkinitcpio.conf"

rocknix_kernver="$(find "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
[[ -n "${rocknix_kernver}" ]] || die "unable to determine imported ROCKNIX kernel release"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/Image" \
  "${rootfs_dir}/usr/lib/modules/${rocknix_kernver}/Image"
run_rootfs "mkinitcpio -P"
install -Dm644 "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/KERNEL" \
  "${rootfs_dir}/usr/share/thorch/rocknix/KERNEL"
run_rootfs "thorch-rebuild-abl-kernel --root-uuid ${root_uuid} --rootfstype ext4"
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
mkfs.ext4 -F -L THORCH_ROOT -U "${root_uuid}" -d "${rootfs_dir}" "${root_img}" >/dev/null

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
dd if="${root_img}" of="${image}" bs="${sector_size}" seek="${root_start}" conv=notrunc status=progress
sync

"${script_dir}/check-thorch-image.sh" "${image}"
log "image ready: ${image}"
