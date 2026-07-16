#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-packages.sh [--skip-kernel] [--packages <name[,name...]>] [--skip-fresh] [--trust-existing]

Builds Thorch aarch64 packages in an Arch Linux ARM rootfs using
THORCH_ROOTFS_RUNNER and qemu-user-static. The runner defaults to plain chroot;
set THORCH_ROOTFS_RUNNER=systemd-nspawn to use the old nspawn backend. The
linux-thorch package wraps Thorch's ROCKNIX-derived kernel artifacts. Use
--skip-kernel while iterating on userspace packages only.

  --packages           build only the comma-separated package list supplied;
                       useful for fast iteration on one package.
  --skip-fresh         reuse an existing repo package when local inputs are not
                       newer than that package.
  --trust-existing     with --skip-fresh, treat existing packages without an
                       input fingerprint as fresh and record their current
                       fingerprint. Intended for fast iteration over a repo
                       that predates input fingerprints.
EOF
}

skip_kernel=0
skip_fresh=0
trust_existing=0
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
    --trust-existing)
      trust_existing=1
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
require_cmd bsdtar curl git repo-add rsync sha256sum vercmp
require_rootfs_runner

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
machine_name="$(nspawn_machine_name pkg-root "${build_root}")"
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

if mountpoint -q "${build_root}/proc"; then
  warn "unmounting stale package chroot proc filesystem: ${build_root}/proc"
  unmount_path_if_mounted "${build_root}/proc" || \
    die "unable to unmount stale package chroot proc filesystem: ${build_root}/proc"
fi

packages=(thorch-bsp thorch-fex-bin thorch-firmware-rocknix kwin plasma-keyboard thorch-kde-defaults thorch-firstboot thorch-installer thorch-gamescope thorch-gaming-installers thorch-waydroid-installer thorch-inputplumber thorch-rocknix-quirks thorch-mangohud thorch-gamepadcalibration)
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

resolve_input_path() {
  local path="$1" prefix rest value

  prefix="${path%%/*}"
  if [[ "${prefix}" == "${path}" ]]; then
    rest=""
  else
    rest="${path#*/}"
  fi

  case "${prefix}" in
    THORCH_FIRMWARE_DIR|THORCH_ROCKNIX_DIR|THORCH_ROCKNIX_KERNEL_DIR|THORCH_ROCKNIX_RUNTIME_DIR)
      value="${!prefix}"
      path="${value}${rest:+/${rest}}"
      ;;
  esac

  [[ "${path}" = /* ]] || path="${root}/${path}"
  printf '%s\n' "${path}"
}

trim_input_line() {
  local line="$1"

  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "${line}"
}

package_input_paths() {
  local pkg="$1" manifest line

  printf '%s\n' "${root}/packages/${pkg}"
  manifest="${root}/packages/${pkg}/.thorch-build-inputs"
  if [[ -f "${manifest}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="$(trim_input_line "${line}")"
      [[ -n "${line}" ]] || continue
      resolve_input_path "${line}"
    done < "${manifest}"
  fi
}

input_fingerprint_for() {
  local pkg="$1" path file rel digest target

  {
    while IFS= read -r path; do
      if [[ -f "${path}" ]]; then
        [[ "${path##*/}" == ".thorch-build-inputs" ]] && continue
        rel="${path#"${root}/"}"
        digest="$(sha256sum "${path}" | awk '{print $1}')"
        printf 'file %s %s\n' "${rel}" "${digest}"
      elif [[ -L "${path}" ]]; then
        rel="${path#"${root}/"}"
        target="$(readlink "${path}")"
        printf 'link %s %s\n' "${rel}" "${target}"
      elif [[ -d "${path}" ]]; then
        while IFS= read -r file; do
          [[ "${file##*/}" == ".thorch-build-inputs" ]] && continue
          rel="${file#"${root}/"}"
          if [[ -L "${file}" ]]; then
            target="$(readlink "${file}")"
            printf 'link %s %s\n' "${rel}" "${target}"
          else
            digest="$(sha256sum "${file}" | awk '{print $1}')"
            printf 'file %s %s\n' "${rel}" "${digest}"
          fi
        done < <(find "${path}" \( -type f -o -type l \) -print | LC_ALL=C sort)
      else
        rel="${path#"${root}/"}"
        printf 'missing %s\n' "${rel}"
      fi
    done < <(package_input_paths "${pkg}")
  } | sha256sum | awk '{print $1}'
}

fingerprint_file_for() {
  local pkgfile="$1"

  printf '%s/.thorch-inputs/%s.sha256\n' "${repo_dir}" "${pkgfile##*/}"
}

record_input_fingerprint() {
  local pkg="$1" pkgfile="$2" fingerprint_file

  fingerprint_file="$(fingerprint_file_for "${pkgfile}")"
  install -d "$(dirname "${fingerprint_file}")"
  input_fingerprint_for "${pkg}" > "${fingerprint_file}"
}

package_dir_inputs_newer_than() {
  local pkg="$1" pkgfile="$2" rel pkg_ts latest_commit dirty

  rel="packages/${pkg}"
  if git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    pkg_ts="$(stat -c '%Y' "${pkgfile}")"
    latest_commit="$(git -C "${root}" log -1 --format=%ct -- "${rel}" 2>/dev/null || true)"
    if [[ -n "${latest_commit}" && "${latest_commit}" -gt "${pkg_ts}" ]]; then
      return 0
    fi

    dirty="$(
      git -C "${root}" status --porcelain --untracked-files=all -- "${rel}" |
        awk '$2 !~ /(^|\/)\.thorch-build-inputs$/ { print; exit }'
    )"
    [[ -n "${dirty}" ]] && return 0
    return 1
  fi

  find "${root}/${rel}" -type f ! -name '.thorch-build-inputs' -newer "${pkgfile}" -print -quit | grep -q .
}

package_inputs_newer_than() {
  local pkg="$1" pkgfile="$2" path

  while IFS= read -r path; do
    [[ -e "${path}" ]] || continue
    if [[ "${path}" == "${root}/packages/${pkg}" ]]; then
      package_dir_inputs_newer_than "${pkg}" "${pkgfile}" && return 0
      continue
    fi
    if [[ -f "${path}" ]]; then
      [[ "${path##*/}" == ".thorch-build-inputs" ]] && continue
      [[ "${path}" -nt "${pkgfile}" ]] && return 0
    elif find "${path}" -type f ! -name '.thorch-build-inputs' -newer "${pkgfile}" -print -quit | grep -q .; then
      return 0
    fi
  done < <(package_input_paths "${pkg}")

  return 1
}

fresh_repo_package_for() {
  local pkg="$1" pkgfile fingerprint_file current_fingerprint recorded_fingerprint

  pkgfile="$(latest_repo_package_for "${pkg}")" || return 1
  fingerprint_file="$(fingerprint_file_for "${pkgfile}")"
  current_fingerprint="$(input_fingerprint_for "${pkg}")"

  if [[ -f "${fingerprint_file}" ]]; then
    recorded_fingerprint="$(<"${fingerprint_file}")"
    [[ "${recorded_fingerprint}" == "${current_fingerprint}" ]] || return 1
    printf '%s\n' "${pkgfile}"
    return 0
  fi

  if [[ "${trust_existing}" -eq 1 ]]; then
    log "recording input fingerprint for existing ${pkg}; ${pkgfile##*/} is trusted"
    install -d "$(dirname "${fingerprint_file}")"
    printf '%s\n' "${current_fingerprint}" > "${fingerprint_file}"
    printf '%s\n' "${pkgfile}"
    return 0
  fi

  if package_inputs_newer_than "${pkg}" "${pkgfile}"; then
    return 1
  fi

  install -d "$(dirname "${fingerprint_file}")"
  printf '%s\n' "${current_fingerprint}" > "${fingerprint_file}"
  printf '%s\n' "${pkgfile}"
}

if [[ "${skip_fresh}" -eq 1 ]]; then
  stale_packages=()
  for pkg in "${packages[@]}"; do
    if pkgfile="$(fresh_repo_package_for "${pkg}")"; then
      log "skipping ${pkg}; ${pkgfile##*/} is fresh"
      continue
    fi
    stale_packages+=("${pkg}")
  done
  packages=("${stale_packages[@]}")
  if [[ "${#packages[@]}" -eq 0 ]]; then
    log "all requested packages are fresh"
    exit 0
  fi
fi

rocknix_kernel_firmware_ready() {
  local kernel_dir="${root}/${THORCH_ROCKNIX_KERNEL_DIR}"
  [[ -f "${kernel_dir}/usr/lib/firmware/qcom/a740_sqe.fw" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/gmu_gen70200.bin" ]] &&
    [[ -f "${kernel_dir}/usr/lib/firmware/qcom/sm8550/a740_zap.mbn" ]]
}

rocknix_package_sources_ready() {
  local source_dir="${root}/${THORCH_ROCKNIX_DIR}"
  [[ -f "${source_dir}/packages/apps/gamescope/patches/0001-WaylandBackend-wire-up-wl_touch-implementation.patch" ]] &&
    [[ -f "${source_dir}/packages/apps/gamescope/patches/0004-DRMBackend-Add-GAMESCOPE_FAKE_OUTPUT_MM-env-to-set-c.patch" ]] &&
    [[ -f "${source_dir}/packages/apps/gamescope/patches/0005-feature-add-rotation-shader-for-rotating-output.patch" ]] &&
    [[ -f "${source_dir}/packages/apps/mangohud/patches/SM8550/0001-SM8550-GPU.patch" ]] &&
    [[ -f "${source_dir}/packages/apps/mangohud/config/MangoHud.conf" ]] &&
    [[ -d "${source_dir}/inputplumber" ]] &&
    [[ -d "${source_dir}/packages/hardware/quirks/platforms/SM8550" ]]
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
  log "syncing ROCKNIX runtime and source-building Thorch SM8550 kernel artifacts"
  "${script_dir}/sync-rocknix-kernel.sh"
fi
if { [[ " ${packages[*]} " == *" thorch-gamescope "* ]] ||
  [[ " ${packages[*]} " == *" thorch-inputplumber "* ]] ||
  [[ " ${packages[*]} " == *" thorch-rocknix-quirks "* ]] ||
  [[ " ${packages[*]} " == *" thorch-mangohud "* ]]; } && ! rocknix_package_sources_ready; then
  log "syncing public ROCKNIX SM8550 package sources"
  "${script_dir}/sync-rocknix-sources.sh"
fi
if [[ " ${packages[*]} " == *" linux-thorch "* || " ${packages[*]} " == *" thorch-firmware-rocknix "* ]]; then
  validate_rocknix_kernel_provenance "${root}/${THORCH_ROCKNIX_KERNEL_DIR}"
fi
if [[ " ${packages[*]} " == *" thorch-fex-bin "* ]]; then
  validate_rocknix_runtime_provenance "${root}/${THORCH_ROCKNIX_RUNTIME_DIR}"
fi

install -d "${cache_dir}" "${repo_dir}" "$(dirname "${build_root}")"
if [[ ! -d "${build_root}/usr" ]]; then
  log "extracting package build root"
  rm -rf "${build_root}"
  install -d "${build_root}"
  ensure_alarm_rootfs "${rootfs_tar}"
  extract_alarm_rootfs_without_stock_kernel_firmware "${rootfs_tar}" "${build_root}"
  repair_alarm_usrmerge_links "${build_root}"
else
  if [[ -f "${rootfs_tar}" ]]; then
    verify_alarm_rootfs "${rootfs_tar}" || \
      die "cached Arch Linux ARM rootfs failed verification; remove ${rootfs_tar} before recreating the package build root"
  fi
  repair_alarm_usrmerge_links "${build_root}"
fi

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  cp /usr/bin/qemu-aarch64-static "${build_root}/usr/bin/"
fi
configure_chroot_resolver "${build_root}"
configure_alarm_pacman "${build_root}"
mask_chroot_stock_kernel_hooks "${build_root}"

run_chroot() {
  run_aarch64_rootfs_shell "${build_root}" "${machine_name}" "$*"
}

remove_stock_firmware() {
  run_chroot "installed_stock=\$(pacman -Qq ${stock_kernel_firmware[*]} 2>/dev/null || true); [[ -z \"\${installed_stock}\" ]] || pacman -Rdd --noconfirm \${installed_stock}"
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
      rm -f "${current}" "${current}.sig" "$(fingerprint_file_for "${current}")"
      best_file["${pkgname}"]="${file}"
      best_version["${pkgname}"]="${pkgver}"
    else
      rm -f "${file}" "${file}.sig" "$(fingerprint_file_for "${file}")"
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
sync_input_dir "${THORCH_ROCKNIX_DIR}"
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
  shopt -s nullglob
  for pkgfile in "${pkgdest}"/*.pkg.tar.*; do
    cp -f "${pkgfile}" "${repo_dir}/"
    record_input_fingerprint "${pkg}" "${repo_dir}/${pkgfile##*/}"
  done
  shopt -u nullglob
done

log "updating local pacman repository"
prune_stale_repo_packages
rm -f "${repo_dir}/thorch.db"* "${repo_dir}/thorch.files"*
shopt -s nullglob
repo_packages=("${repo_dir}"/*.pkg.tar.*)
shopt -u nullglob
[[ "${#repo_packages[@]}" -gt 0 ]] || die "no packages available for repo-add in ${repo_dir}"
repo-add "${repo_dir}/thorch.db.tar.gz" "${repo_packages[@]}" >/dev/null
log "packages available in ${repo_dir}"
