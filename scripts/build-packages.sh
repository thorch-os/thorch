#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-packages.sh [--skip-kernel] [--packages <name[,name...]>] [--skip-fresh]

Builds Thorch aarch64 packages in an Arch Linux ARM rootfs using systemd-nspawn
and qemu-user-static. The linux-thorch package wraps imported ROCKNIX kernel
artifacts. Use --skip-kernel while iterating on userspace packages only.

  --packages           build only the comma-separated package list supplied;
                       useful for fast iteration on one package.
  --skip-fresh         reuse an existing repo package when local inputs are not
                       newer than that package.
EOF
}

skip_kernel=0
skip_fresh=0
requested_packages=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-kernel)
      skip_kernel=1
      shift
      ;;
    --packages)
      [[ "$#" -ge 2 ]] || die "--packages requires a comma-separated list"
      IFS=',' read -r -a requested_packages <<< "$2"
      shift 2
      ;;
    --skip-fresh)
      skip_fresh=1
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
require_cmd bsdtar curl qemu-aarch64-static repo-add rsync systemd-nspawn vercmp

root="$(repo_root)"
if [[ "${THORCH_BUILD_DIR}" = /* ]]; then
  build_dir="${THORCH_BUILD_DIR%/}"
else
  build_dir="${root}/${THORCH_BUILD_DIR}"
fi
build_root="${build_dir}/pkg-root"
cache_dir="${build_dir}/cache"
repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"
input_dir="${build_root}/thorch-input"
work_dir="${build_root}/thorch-work"
pkgdest="${build_root}/thorch-pkgdest"
rootfs_tar="${cache_dir}/ArchLinuxARM-aarch64-latest.tar.gz"
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

packages=(thorch-bsp thorch-fex-bin thorch-firmware-rocknix thorch-kde-defaults thorch-installer thorch-gamescope thorch-gaming-installers)
if [[ "${skip_kernel}" -eq 0 ]]; then
  packages=(linux-thorch "${packages[@]}")
fi
if [[ "${#requested_packages[@]}" -gt 0 ]]; then
  packages=("${requested_packages[@]}")
fi
for i in "${!packages[@]}"; do
  if [[ "${packages[i]}" == "thorch-fex" ]]; then
    packages[i]=thorch-fex-bin
  fi
done

rocknix_kernel_firmware_ready() {
  local kernel_dir="${root}/${THORCH_ROCKNIX_KERNEL_DIR}"
  [[ -f "${kernel_dir}/usr/lib/firmware/qcom/a740_sqe.fw" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/gmu_gen70200.bin" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/sm8550/a740_zap.mbn" ]]
}

needs_rocknix_sync=0
if [[ " ${packages[*]} " == *" linux-thorch "* ]] &&
  { [[ ! -f "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/Image" ]] || [[ ! -f "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/boot/KERNEL" ]]; }; then
  needs_rocknix_sync=1
fi
if [[ " ${packages[*]} " == *" thorch-firmware-rocknix "* ]] &&
  { [[ ! -f "${root}/${THORCH_ROCKNIX_KERNEL_DIR}/usr/lib/libvulkan_freedreno.so" ]] || ! rocknix_kernel_firmware_ready; }; then
  needs_rocknix_sync=1
fi
if [[ " ${packages[*]} " == *" thorch-fex-bin "* && ! -x "${root}/${THORCH_ROCKNIX_RUNTIME_DIR}/usr/bin/FEX" ]]; then
  needs_rocknix_sync=1
fi
if [[ "${needs_rocknix_sync}" -eq 1 ]]; then
  log "syncing prebuilt ROCKNIX SM8550 kernel/runtime artifacts"
  "${script_dir}/sync-rocknix-kernel.sh"
fi
if [[ " ${packages[*]} " == *" linux-thorch "* || " ${packages[*]} " == *" thorch-firmware-rocknix "* ]]; then
  validate_rocknix_kernel_provenance "${root}/${THORCH_ROCKNIX_KERNEL_DIR}"
fi
if [[ " ${packages[*]} " == *" thorch-fex-bin "* ]]; then
  validate_rocknix_runtime_provenance "${root}/${THORCH_ROCKNIX_RUNTIME_DIR}"
fi

if [[ ! -d "${build_root}/usr" ]]; then
  log "extracting package build root"
  rm -rf "${build_root}"
  install -d "${build_root}"
	  install -d "${cache_dir}" "${repo_dir}" "$(dirname "${build_root}")"
	  ensure_alarm_rootfs "${rootfs_tar}"
	  extract_alarm_rootfs_without_stock_kernel_firmware "${rootfs_tar}" "${build_root}"
	  repair_alarm_usrmerge_links "${build_root}"
	else
	  install -d "${cache_dir}" "${repo_dir}" "$(dirname "${build_root}")"
	  if [[ -f "${rootfs_tar}" ]]; then
	    verify_alarm_rootfs "${rootfs_tar}" || \
	      die "cached Arch Linux ARM rootfs failed verification; remove ${rootfs_tar} before recreating the package build root"
	  fi
	  repair_alarm_usrmerge_links "${build_root}"
	fi

cp /usr/bin/qemu-aarch64-static "${build_root}/usr/bin/"
configure_chroot_resolver "${build_root}"
configure_alarm_pacman "${build_root}"
mask_chroot_stock_kernel_hooks "${build_root}"

run_chroot() {
  rm -rf "${build_root}/run/systemd/nspawn"
  systemd-nspawn \
    --quiet \
    --pipe \
    --register=no \
    --directory="${build_root}" \
    /usr/bin/qemu-aarch64-static /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 /bin/bash -lc "$*"
}

remove_stock_firmware() {
  run_chroot "installed_stock=\$(pacman -Qq ${stock_kernel_firmware[*]} 2>/dev/null || true); [[ -z \"\${installed_stock}\" ]] || pacman -Rdd --noconfirm \${installed_stock}"
}

pkginfo_value() {
  local pkgfile="$1" key="$2"
  bsdtar -xOqf "${pkgfile}" .PKGINFO | awk -F ' = ' -v key="${key}" '$1 == key {print $2; exit}'
}

latest_repo_package_for() {
  local pkg="$1" file pkgname current

  shopt -s nullglob
  for file in "${repo_dir}"/*.pkg.tar.*; do
    pkgname="$(pkginfo_value "${file}" pkgname)"
    [[ "${pkgname}" == "${pkg}" ]] || continue
    current="${current:-}"
    if [[ -z "${current}" || "${file}" -nt "${current}" ]]; then
      current="${file}"
    fi
  done
  shopt -u nullglob

  [[ -n "${current:-}" ]] || return 1
  printf '%s\n' "${current}"
}

package_inputs_newer_than() {
  local pkg="$1" pkgfile="$2" dir
  local -a input_dirs=("${root}/packages/${pkg}")

  case "${pkg}" in
    linux-thorch|thorch-firmware-rocknix)
      input_dirs+=("${root}/${THORCH_ROCKNIX_KERNEL_DIR}")
      ;;
    thorch-fex-bin)
      input_dirs+=("${root}/${THORCH_ROCKNIX_RUNTIME_DIR}")
      ;;
  esac

  for dir in "${input_dirs[@]}"; do
    [[ -e "${dir}" ]] || continue
    if find "${dir}" -type f -newer "${pkgfile}" -print -quit | grep -q .; then
      return 0
    fi
  done

  return 1
}

fresh_repo_package_for() {
  local pkg="$1" pkgfile

  pkgfile="$(latest_repo_package_for "${pkg}")" || return 1
  if package_inputs_newer_than "${pkg}" "${pkgfile}"; then
    return 1
  fi

  printf '%s\n' "${pkgfile}"
}

prune_stale_repo_packages() {
  local -A best_file=()
  local -A best_version=()
  local file pkgname pkgver current cmp

  shopt -s nullglob
  for file in "${repo_dir}"/*.pkg.tar.*; do
    pkgname="$(pkginfo_value "${file}" pkgname)"
    pkgver="$(pkginfo_value "${file}" pkgver)"
    [[ -n "${pkgname}" && -n "${pkgver}" ]] || die "unable to read package metadata from ${file}"

    current="${best_file[${pkgname}]:-}"
    if [[ -z "${current}" ]]; then
      best_file["${pkgname}"]="${file}"
      best_version["${pkgname}"]="${pkgver}"
      continue
    fi

    cmp="$(vercmp "${pkgver}" "${best_version[${pkgname}]}")"
    if (( cmp > 0 )) || { (( cmp == 0 )) && [[ "${file}" -nt "${current}" ]]; }; then
      rm -f "${current}" "${current}.sig"
      best_file["${pkgname}"]="${file}"
      best_version["${pkgname}"]="${pkgver}"
    else
      rm -f "${file}" "${file}.sig"
    fi
  done
  shopt -u nullglob
}

sync_input_dir() {
  local rel="$1"
  local src="${root}/${rel}"
  local dst="${input_dir}/${rel}"

  [[ -e "${src}" ]] || return 0
  rm -rf "${dst}"
  install -d "$(dirname "${dst}")"
  rsync -a "${src}/" "${dst}/"
}

log "syncing package build inputs"
rm -rf "${input_dir}"
install -d "${input_dir}"
sync_input_dir "${THORCH_FIRMWARE_DIR}"
sync_input_dir "${THORCH_ROCKNIX_KERNEL_DIR}"
sync_input_dir "${THORCH_ROCKNIX_RUNTIME_DIR}"

log "preparing aarch64 package build chroot"
run_chroot "pacman-key --init >/dev/null 2>&1 || true"
run_chroot "pacman-key --populate archlinuxarm >/dev/null 2>&1 || true"
remove_stock_firmware
run_chroot "pacman -Syu --noconfirm --needed base-devel python"
remove_stock_firmware
run_chroot "gpgconf --kill all >/dev/null 2>&1 || pkill gpg-agent >/dev/null 2>&1 || true"
run_chroot "id builder >/dev/null 2>&1 || useradd -m builder"
run_chroot "install -d -o builder -g builder /nix"
for pkg in "${packages[@]}"; do
  if [[ "${skip_fresh}" -eq 1 ]]; then
    if pkgfile="$(fresh_repo_package_for "${pkg}")"; then
      log "skipping ${pkg}; ${pkgfile##*/} is fresh"
      continue
    fi
  fi

  log "building ${pkg}"
  rm -rf "${work_dir}/${pkg}" "${pkgdest}"
  install -d "${work_dir}/${pkg}" "${pkgdest}"
  rsync -a "${root}/packages/${pkg}/" "${work_dir}/${pkg}/"
  if [[ -f "${root}/packages/${pkg}/.thorch-build-pacman-deps" ]]; then
    deps="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${root}/packages/${pkg}/.thorch-build-pacman-deps" | tr '\n' ' ')"
    [[ -z "${deps}" ]] || run_chroot "pacman -S --needed --noconfirm ${deps}"
  fi
  run_chroot "chown -R builder:builder /thorch-work/${pkg} /thorch-pkgdest"
  run_chroot "cd /thorch-work/${pkg} && su builder -c 'env PKGDEST=/thorch-pkgdest THORCH_ROCKNIX_DIR=/thorch-input/${THORCH_ROCKNIX_DIR} THORCH_FIRMWARE_DIR=/thorch-input/${THORCH_FIRMWARE_DIR} THORCH_ROCKNIX_KERNEL_DIR=/thorch-input/${THORCH_ROCKNIX_KERNEL_DIR} THORCH_ROCKNIX_RUNTIME_DIR=/thorch-input/${THORCH_ROCKNIX_RUNTIME_DIR} makepkg --nodeps --noconfirm --cleanbuild'"
  find "${pkgdest}" -maxdepth 1 -type f -name '*.pkg.tar.*' -exec cp -f {} "${repo_dir}/" \;
done

log "updating local pacman repository"
prune_stale_repo_packages
rm -f "${repo_dir}/thorch.db"* "${repo_dir}/thorch.files"*
repo-add "${repo_dir}/thorch.db.tar.gz" "${repo_dir}"/*.pkg.tar.* >/dev/null
log "packages available in ${repo_dir}"
