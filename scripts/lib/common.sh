#!/usr/bin/env bash
set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_thorch_config() {
  local root
  root="$(repo_root)"
  # shellcheck source=../../config/thorch.conf
  source "${root}/config/thorch.conf"
}

log() {
  printf '==> %s\n' "$*" >&2
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      printf 'missing required command: %s\n' "${cmd}" >&2
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "this command must run as root"
}

abspath() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "${path}"
    return
  fi
  if [[ -d "${path}" ]]; then
    (cd "${path}" && pwd)
  else
    local parent base
    parent="$(dirname "${path}")"
    base="$(basename "${path}")"
    mkdir -p "${parent}"
    printf '%s/%s\n' "$(cd "${parent}" && pwd)" "${base}"
  fi
}

nspawn_machine_name() {
  local label="$1" path="$2" hash

  label="${label//[^[:alnum:]._-]/-}"
  hash="$(printf '%s' "$(abspath "${path}")" | cksum | awk '{print $1}')"
  printf 'thorch-%s-%s\n' "${label}" "${hash}"
}

rootfs_runner() {
  case "${THORCH_ROOTFS_RUNNER:-chroot}" in
    chroot|plain-chroot)
      printf 'chroot\n'
      ;;
    systemd-nspawn|nspawn)
      printf 'systemd-nspawn\n'
      ;;
    *)
      die "unsupported THORCH_ROOTFS_RUNNER: ${THORCH_ROOTFS_RUNNER}; use chroot or systemd-nspawn"
      ;;
  esac
}

require_rootfs_runner() {
  case "$(rootfs_runner)" in
    chroot)
      require_cmd chroot mknod mount mountpoint umount unshare
      [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] || require_cmd qemu-aarch64-static
      ;;
    systemd-nspawn)
      require_cmd systemd-nspawn
      [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] || require_cmd qemu-aarch64-static
      ;;
  esac
}

ensure_chroot_device_node() {
  local rootfs="$1" name="$2" major="$3" minor="$4" mode="$5" path

  path="${rootfs}/dev/${name}"
  if [[ -c "${path}" ]]; then
    chmod "${mode}" "${path}"
    return
  fi

  rm -f "${path}"
  mknod -m "${mode}" "${path}" c "${major}" "${minor}"
}

prepare_chroot_device_nodes() {
  local rootfs="$1"

  install -d -m 0755 "${rootfs}/dev"
  ensure_chroot_device_node "${rootfs}" null 1 3 0666
  ensure_chroot_device_node "${rootfs}" zero 1 5 0666
  ensure_chroot_device_node "${rootfs}" full 1 7 0666
  ensure_chroot_device_node "${rootfs}" random 1 8 0666
  ensure_chroot_device_node "${rootfs}" urandom 1 9 0666
  install -d -m 0755 "${rootfs}/dev/pts" "${rootfs}/dev/shm"
  ln -sfn /proc/self/fd "${rootfs}/dev/fd"
  ln -sfn /proc/self/fd/0 "${rootfs}/dev/stdin"
  ln -sfn /proc/self/fd/1 "${rootfs}/dev/stdout"
  ln -sfn /proc/self/fd/2 "${rootfs}/dev/stderr"
}

unmount_path_if_mounted() {
  local path="$1"

  while mountpoint -q "${path}"; do
    umount "${path}" || return 1
  done
}

run_plain_chroot_cmd() {
  local rootfs="$1"
  shift

  prepare_chroot_device_nodes "${rootfs}"
  install -d -m 0555 "${rootfs}/proc"
  if mountpoint -q "${rootfs}/proc"; then
    warn "unmounting stale chroot proc filesystem: ${rootfs}/proc"
    unmount_path_if_mounted "${rootfs}/proc" || \
      die "unable to unmount stale chroot proc filesystem: ${rootfs}/proc"
  fi

  # Keep proc in a private mount namespace. If the build is interrupted or
  # killed, the mount cannot leak into the host namespace and block cleanup.
  unshare --mount --propagation private \
    /bin/bash -c '
      set -euo pipefail
      rootfs="$1"
      shift
      mounted_proc=0
      status=0
      cleanup() {
        if [[ "${mounted_proc}" -eq 1 ]]; then
          umount "${rootfs}/proc" >/dev/null 2>&1 || true
        fi
      }
      trap cleanup EXIT
      trap "exit 129" HUP
      trap "exit 130" INT
      trap "exit 143" TERM
      mount -t proc proc "${rootfs}/proc"
      mounted_proc=1
      if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        chroot "${rootfs}" /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 "$@" || status=$?
      else
        chroot "${rootfs}" /usr/bin/qemu-aarch64-static /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 "$@" || status=$?
      fi
      exit "${status}"
    ' bash "${rootfs}" "$@"
}

run_aarch64_rootfs_cmd() {
  local rootfs="$1" machine="$2" runner
  shift 2

  runner="$(rootfs_runner)"
  case "${runner}" in
    chroot)
      run_plain_chroot_cmd "${rootfs}" "$@"
      ;;
    systemd-nspawn)
      rm -rf "${rootfs}/run/systemd/nspawn"
      if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        systemd-nspawn \
          --quiet --pipe --machine="${machine}" --register=no --directory="${rootfs}" \
          /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 "$@"
      else
        systemd-nspawn \
          --quiet --pipe --machine="${machine}" --register=no --directory="${rootfs}" \
          /usr/bin/qemu-aarch64-static /usr/bin/env TERM=dumb SYSTEMD_COLORS=0 "$@"
      fi
      ;;
  esac
}

run_aarch64_rootfs_shell() {
  local rootfs="$1" machine="$2"
  shift 2

  run_aarch64_rootfs_cmd "${rootfs}" "${machine}" /bin/bash --noprofile --norc -c "$*"
}

parse_size_bytes() {
  local size="$1"
  numfmt --from=iec "${size}"
}

verify_alarm_rootfs() {
  local rootfs_tar="$1"
  local sig_file="${rootfs_tar}.sig"
  local gpg_home status_file key keyring signer

  if [[ -n "${ALARM_ROOTFS_SHA256:-}" ]]; then
    require_cmd sha256sum
    printf '%s  %s\n' "${ALARM_ROOTFS_SHA256}" "${rootfs_tar}" | sha256sum -c -
    return
  fi

  [[ "${ALARM_ROOTFS_URL}" == https://* ]] || \
    die "ALARM_ROOTFS_URL must use https unless ALARM_ROOTFS_SHA256 is set"
  [[ -n "${ALARM_ROOTFS_SIG_URL:-}" ]] || \
    die "ALARM_ROOTFS_SIG_URL is required unless ALARM_ROOTFS_SHA256 is set"

  require_cmd bsdtar gpg
  curl -fL --retry 3 -o "${sig_file}" "${ALARM_ROOTFS_SIG_URL}"
  [[ -n "${ALARM_ROOTFS_SIGNING_KEYS:-}" ]] || \
    die "ALARM_ROOTFS_SIGNING_KEYS is required unless ALARM_ROOTFS_SHA256 is set"

  gpg_home="$(mktemp -d /tmp/thorch-alarm-gnupg.XXXXXX)"
  status_file="$(mktemp /tmp/thorch-alarm-gpg-status.XXXXXX)"
  chmod 0700 "${gpg_home}"

  cleanup_alarm_gpg() {
    gpgconf --homedir "${gpg_home}" --kill all >/dev/null 2>&1 || true
    rm -rf "${gpg_home}" "${status_file}"
  }

  import_alarm_signing_key() {
    local key="$1" keyring_pkg timeout_secs

    timeout_secs="${ALARM_ROOTFS_KEY_FETCH_TIMEOUT:-20}"
    if [[ -n "${ALARM_ROOTFS_KEYRING_URL:-}" ]]; then
      keyring_pkg="$(mktemp /tmp/thorch-alarm-keyring.XXXXXX.pkg.tar.xz)"
      if curl -fsSL --retry 2 --max-time "${timeout_secs}" -o "${keyring_pkg}" "${ALARM_ROOTFS_KEYRING_URL}" &&
          bsdtar -xOf "${keyring_pkg}" usr/share/pacman/keyrings/archlinuxarm.gpg |
            gpg --homedir "${gpg_home}" --batch --quiet --import - >/dev/null; then
        rm -f "${keyring_pkg}"
        return 0
      fi
      rm -f "${keyring_pkg}"
    fi

    [[ -n "${ALARM_ROOTFS_KEYSERVER:-}" ]] || return 1
    if command -v timeout >/dev/null 2>&1; then
      timeout "${timeout_secs}" gpg \
        --homedir "${gpg_home}" \
        --batch \
        --keyserver-options "timeout=${timeout_secs}" \
        --keyserver "${ALARM_ROOTFS_KEYSERVER}" \
        --recv-keys "${key}"
    else
      gpg \
        --homedir "${gpg_home}" \
        --batch \
        --keyserver-options "timeout=${timeout_secs}" \
        --keyserver "${ALARM_ROOTFS_KEYSERVER}" \
        --recv-keys "${key}"
    fi
  }

  keyring=/usr/share/pacman/keyrings/archlinuxarm.gpg
  if [[ -r "${keyring}" ]]; then
    gpg --homedir "${gpg_home}" --batch --quiet --import "${keyring}" >/dev/null
  fi

  for key in ${ALARM_ROOTFS_SIGNING_KEYS}; do
    key="$(printf '%s' "${key}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    [[ "${key}" =~ ^[0-9A-F]{40}$ ]] || {
      cleanup_alarm_gpg
      die "invalid ALARM_ROOTFS_SIGNING_KEYS fingerprint: ${key}"
    }
    if ! gpg --homedir "${gpg_home}" --batch --list-keys "${key}" >/dev/null 2>&1; then
      if ! import_alarm_signing_key "${key}"; then
        cleanup_alarm_gpg
        die "failed to import pinned Arch Linux ARM rootfs signing key ${key}; set ALARM_ROOTFS_KEYRING_URL or ALARM_ROOTFS_SHA256"
      fi
    fi
    gpg --homedir "${gpg_home}" --batch --with-colons --fingerprint "${key}" |
      awk -F: -v key="${key}" '$1 == "fpr" && $10 == key { found=1 } END { exit(found ? 0 : 1) }' || {
        cleanup_alarm_gpg
        die "failed to import pinned Arch Linux ARM rootfs signing key: ${key}"
      }
  done

  if ! gpg --homedir "${gpg_home}" --batch --status-fd 1 --verify "${sig_file}" "${rootfs_tar}" >"${status_file}" 2>&1; then
    cat "${status_file}" >&2
    cleanup_alarm_gpg
    return 1
  fi

  signer="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print toupper($3); exit }' "${status_file}")"
  for key in ${ALARM_ROOTFS_SIGNING_KEYS}; do
    key="$(printf '%s' "${key}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    if [[ "${signer}" == "${key}" ]]; then
      cleanup_alarm_gpg
      return 0
    fi
  done

  cat "${status_file}" >&2
  cleanup_alarm_gpg
  return 1
}

download_alarm_rootfs() {
  local rootfs_tar="$1"

  log "downloading Arch Linux ARM rootfs"
  install -d "$(dirname "${rootfs_tar}")"
  curl -fL --retry 3 -o "${rootfs_tar}" "${ALARM_ROOTFS_URL}"
}

ensure_alarm_rootfs() {
  local rootfs_tar="$1"

  if [[ ! -f "${rootfs_tar}" ]]; then
    download_alarm_rootfs "${rootfs_tar}"
  fi

  if verify_alarm_rootfs "${rootfs_tar}"; then
    return
  fi

  warn "cached Arch Linux ARM rootfs failed verification; redownloading ${rootfs_tar}"
  rm -f "${rootfs_tar}" "${rootfs_tar}.sig"
  download_alarm_rootfs "${rootfs_tar}"
  if verify_alarm_rootfs "${rootfs_tar}"; then
    return
  fi

  die "failed to verify Arch Linux ARM rootfs; install/populate the Arch Linux ARM keyring or set ALARM_ROOTFS_SHA256"
}

configure_alarm_pacman() {
  local rootfs="$1"
  local mirror

  install -d "${rootfs}/etc/pacman.d"
  : > "${rootfs}/etc/pacman.d/mirrorlist"
  for mirror in ${ALARM_MIRRORS:-${ALARM_MIRROR:-https://ca.us.mirror.archlinuxarm.org}}; do
    printf 'Server = %s/$arch/$repo\n' "${mirror%/}" >> "${rootfs}/etc/pacman.d/mirrorlist"
  done
}

configure_pacman_for_emulated_build() {
  local config="$1"

  [[ -f "${config}" ]] || die "missing pacman configuration: ${config}"
  if ! grep -q '^DisableSandbox$' "${config}"; then
    sed -i '/^\[options\]/a DisableSandbox' "${config}"
  fi
  sed -i 's/^CheckSpace$/#CheckSpace/' "${config}"
}

configure_chroot_resolver() {
  local rootfs="$1"
  local source="/etc/resolv.conf"

  if grep -Eq '^nameserver[[:space:]]+127\.' /etc/resolv.conf 2>/dev/null && [[ -r /run/systemd/resolve/resolv.conf ]]; then
    source="/run/systemd/resolve/resolv.conf"
  fi

  rm -f "${rootfs}/etc/resolv.conf"
  cp -L "${source}" "${rootfs}/etc/resolv.conf"
}

thorch_stock_firmware_packages() {
  printf '%s\n' \
    linux-firmware \
    linux-firmware-amdgpu \
    linux-firmware-atheros \
    linux-firmware-broadcom \
    linux-firmware-cirrus \
    linux-firmware-intel \
    linux-firmware-liquidio \
    linux-firmware-marvell \
    linux-firmware-mediatek \
    linux-firmware-mellanox \
    linux-firmware-nfp \
    linux-firmware-nvidia \
    linux-firmware-other \
    linux-firmware-qcom \
    linux-firmware-qlogic \
    linux-firmware-radeon \
    linux-firmware-realtek \
    linux-firmware-whence
}

remove_chroot_packages_if_installed() {
  local rootfs="$1" machine="$2" package installed_package installed_output
  local -a installed=()
  shift 2

  installed_output="$(
    run_aarch64_rootfs_cmd "${rootfs}" "${machine}" /usr/bin/pacman -Qq
  )"
  for package in "$@"; do
    while IFS= read -r installed_package; do
      if [[ "${installed_package}" == "${package}" ]]; then
        installed+=("${package}")
        break
      fi
    done <<< "${installed_output}"
  done
  (( ${#installed[@]} > 0 )) || return 0

  log "removing packages from ephemeral chroot: ${installed[*]}"
  run_aarch64_rootfs_cmd \
    "${rootfs}" "${machine}" /usr/bin/pacman -R --noconfirm -- "${installed[@]}"
}

mask_chroot_stock_kernel_hooks() {
  local rootfs="$1"

  install -d "${rootfs}/etc/pacman.d/hooks"
  ln -sf /dev/null "${rootfs}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook"
  ln -sf /dev/null "${rootfs}/etc/pacman.d/hooks/60-thorch-boot-transaction-prepare.hook"
  ln -sf /dev/null "${rootfs}/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
  ln -sf /dev/null "${rootfs}/etc/pacman.d/hooks/95-thorch-boot-transaction-commit.hook"
}

extract_alarm_rootfs() {
  local rootfs_tar="$1"
  local dest="$2"

  # Keep the rootfs package database and owned files coherent. Thorch's kernel
  # and firmware packages replace the stock packages through normal pacman
  # provides/conflicts/replaces metadata during the image transaction.
  bsdtar -xpf "${rootfs_tar}" -C "${dest}"
}

repair_alarm_usrmerge_links() {
  local rootfs="$1"

  ensure_usrmerge_link() {
    local path="$1"
    local target="$2"

    if [[ -L "${path}" || ! -e "${path}" ]]; then
      ln -sfn "${target}" "${path}"
      return
    fi
    if [[ -d "${path}" && -z "$(find "${path}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      rmdir "${path}"
      ln -s "${target}" "${path}"
      return
    fi
  }

  install -d "${rootfs}/usr"
  ensure_usrmerge_link "${rootfs}/lib" usr/lib
  ensure_usrmerge_link "${rootfs}/bin" usr/bin
  ensure_usrmerge_link "${rootfs}/sbin" usr/bin
  ensure_usrmerge_link "${rootfs}/lib64" usr/lib
}

validate_rocknix_kernel_provenance() {
  local kernel_dir="$1"
  local expected_kernel_release="${2:-$(linux_thorch_expected_kernel_release)}"
  local provenance="${kernel_dir}/PROVENANCE"
  local expected_kernel_ref="${THORCH_KERNEL_REF:-}"
  local firmware provenance_ref="" provenance_release="" module_releases

  if [[ ! -f "${provenance}" ]]; then
    warn "missing ROCKNIX kernel provenance at ${provenance}"
  elif grep -Eq '(^ROCKNIX_REF=smoke-test-existing-kernel-tree$|^SOURCE_(BOOT|ROOT)_DIR=.*/packages/[^/]+/pkg($|/)|^SOURCE_(IMAGE|DTB|MODULES)=packages/[^/]+/pkg/)' "${provenance}"; then
    die "ROCKNIX kernel provenance points at a local makepkg/smoke-test output; re-import from a mounted or extracted ROCKNIX image"
  else
    provenance_ref="$(awk -F= '$1 == "THORCH_KERNEL_REF" {print substr($0, index($0, "=") + 1); exit}' "${provenance}" 2>/dev/null || true)"
    provenance_release="$(awk -F= '$1 == "THORCH_KERNEL_RELEASE" {print substr($0, index($0, "=") + 1); exit}' "${provenance}" 2>/dev/null || true)"
  fi

  if [[ -n "${expected_kernel_ref}" && -n "${provenance_ref}" && "${provenance_ref}" != "${expected_kernel_ref}" ]]; then
    die "ROCKNIX kernel artifacts were built from ${provenance_ref}, but THORCH_KERNEL_REF is ${expected_kernel_ref}; run make kernel"
  fi

  module_releases="$(find "${kernel_dir}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | paste -sd, -)"
  [[ -n "${module_releases}" ]] || die "ROCKNIX kernel artifacts are missing /usr/lib/modules; run make kernel"
  if [[ "${module_releases}" != "${expected_kernel_release}" ]]; then
    die "ROCKNIX kernel modules are ${module_releases}, but linux-thorch requires ${expected_kernel_release}; run make kernel"
  fi
  if [[ -n "${provenance_release}" ]] &&
    ! tr ',' '\n' <<<"${module_releases}" | grep -Fxq -- "${provenance_release}"; then
    die "ROCKNIX kernel modules are ${module_releases}, but provenance records ${provenance_release}; run make kernel"
  fi

  for firmware in \
    qcom/a740_sqe.fw \
    qcom/gmu_gen70200.bin \
    qcom/sm8550/a740_zap.mbn; do
    [[ -f "${kernel_dir}/usr/lib/firmware/${firmware}" ]] || \
      die "ROCKNIX kernel artifacts are missing firmware ${firmware}; re-import from a ROCKNIX image with /SYSTEM"
  done
}

linux_thorch_expected_kernel_release() {
  local pkgbuild="${1:-$(repo_root)/packages/linux-thorch/PKGBUILD}"
  local pkgver pkgrel

  [[ -f "${pkgbuild}" ]] || die "missing linux-thorch PKGBUILD: ${pkgbuild}"
  pkgver="$(sed -n 's/^pkgver=//p' "${pkgbuild}" | head -n1)"
  pkgrel="$(sed -n 's/^pkgrel=//p' "${pkgbuild}" | head -n1)"
  [[ "${pkgver}" =~ ^[0-9][0-9A-Za-z._+-]*$ ]] || \
    die "unable to derive linux-thorch pkgver from ${pkgbuild}"
  [[ "${pkgrel}" =~ ^[1-9][0-9]*$ ]] || \
    die "unable to derive linux-thorch pkgrel from ${pkgbuild}"
  printf '%s-thorch%s\n' "${pkgver}" "${pkgrel}"
}

rocknix_kernel_artifacts_current() {
  local kernel_dir="$1"
  local expected_kernel_release="${2:-$(linux_thorch_expected_kernel_release)}"
  local provenance_release module_releases

  [[ -f "${kernel_dir}/boot/Image" ]] || return 1
  [[ -f "${kernel_dir}/boot/KERNEL" ]] || return 1
  [[ -f "${kernel_dir}/PROVENANCE" ]] || return 1
  provenance_release="$(awk -F= '$1 == "THORCH_KERNEL_RELEASE" {print substr($0, index($0, "=") + 1); exit}' "${kernel_dir}/PROVENANCE" 2>/dev/null || true)"
  [[ "${provenance_release}" == "${expected_kernel_release}" ]] || return 1
  module_releases="$(find "${kernel_dir}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | paste -sd, -)"
  [[ "${module_releases}" == "${expected_kernel_release}" ]]
}

validate_rocknix_runtime_provenance() {
  local runtime_dir="$1"
  local provenance="${runtime_dir}/PROVENANCE"

  if [[ ! -f "${provenance}" ]]; then
    warn "missing ROCKNIX runtime provenance at ${provenance}"
    return 0
  fi

  if grep -Eq '(^ROCKNIX_REF=smoke-test-existing-kernel-tree$|^SOURCE_(ROOT_DIR|RUNTIME_ROOT)=.*/packages/[^/]+/(pkg|src)($|/))' "${provenance}"; then
    die "ROCKNIX runtime provenance points at a local makepkg/smoke-test output; re-import from a mounted or extracted ROCKNIX image"
  fi
}
