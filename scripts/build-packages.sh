#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-packages.sh [--skip-kernel] [--packages <name[,name...]>] [--skip-fresh] [--trust-existing] [--validate-input-paths]

Builds Thorch aarch64 packages in an Arch Linux ARM rootfs using
THORCH_ROOTFS_RUNNER and qemu-user-static. The runner defaults to plain chroot;
set THORCH_ROOTFS_RUNNER=systemd-nspawn to use the old nspawn backend. The
linux-thorch package wraps Thorch's ROCKNIX-derived kernel artifacts. Each
package is built in a fresh copy of the base root and makepkg installs only the
dependencies declared by its PKGBUILD. Use --skip-kernel while iterating on
userspace packages only.

  --packages           build only the comma-separated package list supplied;
                       useful for fast iteration on one package. Packages are
                       validated and reordered through manifests/packages.json.
  --skip-fresh         compatibility spelling for the default fingerprint-based
                       package reuse; retained for fast-build callers.
  --trust-existing     with --skip-fresh, treat existing packages without an
                       artifact binding as fresh and record the current input
                       and artifact digests. This is an explicit migration
                       assertion for a repo that predates artifact bindings.
  --validate-input-paths
                       validate manifest and configured package input paths
                       without requiring root or changing the build tree.
EOF
}

skip_kernel=0
skip_fresh=0
trust_existing=0
validate_input_paths=0
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
    --validate-input-paths)
      validate_input_paths=1
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

if [[ "${trust_existing}" -eq 1 && "${skip_fresh}" -ne 1 ]]; then
  die "--trust-existing requires --skip-fresh"
fi

root="$(repo_root)"
manifest_cli="${script_dir}/package-manifest.py"
python3 "${manifest_cli}" --repo "${root}" validate >/dev/null

canonical_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
}

assert_path_beneath() {
  local parent="$1" candidate="$2" label="$3" canonical_parent canonical_candidate

  canonical_parent="$(canonical_path "${parent}")"
  canonical_candidate="$(canonical_path "${candidate}")"
  case "${canonical_candidate}" in
    "${canonical_parent}"/*) ;;
    *)
      die "${label} escapes ${canonical_parent}: ${candidate}"
      ;;
  esac
}

validate_relative_config_path() {
  local name="$1" value="$2" part
  local -a parts=()

  [[ -n "${value}" ]] || die "${name} must not be empty"
  [[ "${value}" != /* ]] || die "${name} must be repository-relative: ${value}"
  IFS='/' read -r -a parts <<< "${value}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" && "${part}" != "." && "${part}" != ".." ]] || \
      die "${name} contains an unsafe path component: ${value}"
  done
}

for config_path_variable in \
  THORCH_LOCAL_REPO_DIR \
  THORCH_FIRMWARE_DIR \
  THORCH_ROCKNIX_DIR \
  THORCH_ROCKNIX_KERNEL_DIR \
  THORCH_ROCKNIX_RUNTIME_DIR; do
  validate_relative_config_path \
    "${config_path_variable}" "${!config_path_variable}"
done
if [[ "${THORCH_BUILD_DIR}" != /* ]]; then
  validate_relative_config_path THORCH_BUILD_DIR "${THORCH_BUILD_DIR}"
elif [[ "$(canonical_path "${THORCH_BUILD_DIR}")" == / ]]; then
  die "THORCH_BUILD_DIR must not resolve to the filesystem root"
fi

if [[ "${THORCH_BUILD_DIR}" = /* ]]; then
  build_dir="${THORCH_BUILD_DIR%/}"
else
  build_dir="${root}/${THORCH_BUILD_DIR}"
  assert_path_beneath "${root}" "${build_dir}" THORCH_BUILD_DIR
fi
base_root="${build_dir}/pkg-base-root"
base_root_schema=2
base_root_schema_file="${base_root}/.thorch-package-base-schema"
build_root="${build_dir}/pkg-root"
cache_dir="${build_dir}/cache"
repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"
retained_repo_root="${repo_dir}.cohorts"
input_dir="${build_root}/thorch-input"
work_dir="${build_root}/thorch-work"
pkgdest="${build_root}/thorch-pkgdest"
rootfs_tar="${cache_dir}/ArchLinuxARM-aarch64-latest.tar.gz"
assert_path_beneath "${root}" "${repo_dir}" THORCH_LOCAL_REPO_DIR
assert_path_beneath "${root}" "${retained_repo_root}" THORCH_LOCAL_REPO_DIR
for controlled_path in "${base_root}" "${build_root}" "${cache_dir}"; do
  assert_path_beneath "${build_dir}" "${controlled_path}" "package build path"
done
for controlled_path in "${input_dir}" "${work_dir}" "${pkgdest}"; do
  assert_path_beneath "${build_root}" "${controlled_path}" "package staging path"
done

if [[ "${#requested_packages[@]}" -gt 0 ]]; then
  requested_csv="$(IFS=,; printf '%s' "${requested_packages[*]}")"
  package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" select \
      --profile build --packages "${requested_csv}"
  )"
else
  package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" profile build
  )"
fi
mapfile -t packages <<< "${package_selection}"
if [[ "${skip_kernel}" -eq 1 ]]; then
  userspace_packages=()
  for pkg in "${packages[@]}"; do
    [[ "${pkg}" == "linux-thorch" ]] || userspace_packages+=("${pkg}")
  done
  packages=("${userspace_packages[@]}")
fi
if [[ "${#packages[@]}" -eq 0 ]]; then
  log "no packages selected"
  exit 0
fi
selected_packages=("${packages[@]}")

pkginfo_value() {
  local pkgfile="$1" key="$2"
  bsdtar -xOqf "${pkgfile}" .PKGINFO | awk -F ' = ' -v key="${key}" '$1 == key {print $2; exit}'
}

latest_repo_package_for() {
  local pkg="$1" file pkgname pkgver current current_version cmp

  shopt -s nullglob
  for file in "${repo_dir}"/*.pkg.tar.*; do
    [[ "${file}" != *.sig ]] || continue
    pkgname="$(pkginfo_value "${file}" pkgname)"
    [[ "${pkgname}" == "${pkg}" ]] || continue
    pkgver="$(pkginfo_value "${file}" pkgver)"
    current="${current:-}"
    current_version="${current_version:-}"
    if [[ -z "${current}" ]]; then
      current="${file}"
      current_version="${pkgver}"
      continue
    fi
    cmp="$(vercmp "${pkgver}" "${current_version}")"
    if (( cmp > 0 )) || { (( cmp == 0 )) && [[ "${file}" -nt "${current}" ]]; }; then
      current="${file}"
      current_version="${pkgver}"
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

  path="${root}/${path}"
  assert_path_beneath "${root}" "${path}" "declared package input"
  printf '%s\n' "${path}"
}

input_fingerprint_for() {
  local pkg="$1" input_lines input resolved
  local -a fingerprint_args=()

  input_lines="$(python3 "${manifest_cli}" --repo "${root}" inputs "${pkg}")" || \
    return 1
  while IFS= read -r input || [[ -n "${input}" ]]; do
    [[ -n "${input}" ]] || continue
    resolved="$(resolve_input_path "${input}")" || return 1
    fingerprint_args+=("${input}" "${resolved}")
  done <<< "${input_lines}"

  python3 - "${root}" "${fingerprint_args[@]}" <<'PY'
import hashlib
import os
import stat
import sys


digest = hashlib.sha256()


def field(value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def visit(path: str, relative: str) -> None:
    field(relative.encode("utf-8", "surrogateescape"))
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        field(b"missing")
        return

    field(oct(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
    if stat.S_ISLNK(metadata.st_mode):
        field(b"link")
        field(os.fsencode(os.readlink(path)))
        return
    if stat.S_ISREG(metadata.st_mode):
        field(b"file")
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                field(chunk)
        return
    if stat.S_ISDIR(metadata.st_mode):
        field(b"directory")
        with os.scandir(path) as entries:
            children = sorted(entries, key=lambda entry: os.fsencode(entry.name))
        for child in children:
            child_relative = child.name if relative == "." else f"{relative}/{child.name}"
            visit(child.path, child_relative)
        return
    field(b"special")
    field(str(metadata.st_rdev).encode("ascii"))


root = sys.argv[1]
arguments = sys.argv[2:]
if len(arguments) % 2:
    raise SystemExit("input fingerprint arguments must be spec/path pairs")
for index in range(0, len(arguments), 2):
    spec, path = arguments[index : index + 2]
    field(b"declared-input")
    field(spec.encode("utf-8"))
    field(os.path.relpath(path, root).encode("utf-8", "surrogateescape"))
    visit(path, ".")
print(digest.hexdigest())
PY
}

binding_file_for() {
  local pkgfile="$1"

  printf '%s/.thorch-inputs/%s.json\n' "${repo_dir}" "${pkgfile##*/}"
}

legacy_fingerprint_file_for() {
  local pkgfile="$1"

  printf '%s/.thorch-inputs/%s.sha256\n' "${repo_dir}" "${pkgfile##*/}"
}

record_artifact_binding() {
  local pkg="$1" pkgfile="$2" inputs_sha256="${3:-}"
  local artifact_sha256 binding_file binding_dir legacy_file temporary

  [[ -n "${inputs_sha256}" ]] || inputs_sha256="$(input_fingerprint_for "${pkg}")"
  artifact_sha256="$(sha256sum "${pkgfile}" | awk '{print $1}')"
  binding_file="$(binding_file_for "${pkgfile}")"
  binding_dir="$(dirname "${binding_file}")"
  legacy_file="$(legacy_fingerprint_file_for "${pkgfile}")"
  assert_path_beneath "${repo_dir}" "${binding_dir}" "package binding directory"
  assert_path_beneath "${binding_dir}" "${binding_file}" "package artifact binding"
  assert_path_beneath "${binding_dir}" "${legacy_file}" "legacy package binding"
  install -d "${binding_dir}"
  temporary="$(mktemp "${binding_file}.XXXXXX")"
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "artifact": "%s",\n' "${pkgfile##*/}"
    printf '  "artifact_sha256": "%s",\n' "${artifact_sha256}"
    printf '  "inputs_sha256": "%s"\n' "${inputs_sha256}"
    printf '}\n'
  } > "${temporary}"
  chmod 0644 "${temporary}"
  mv -f "${temporary}" "${binding_file}"
  rm -f "${legacy_file}"
}

fresh_repo_package_for() {
  local pkg="$1" pkgfile binding_file current_fingerprint

  pkgfile="$(latest_repo_package_for "${pkg}")" || return 1
  binding_file="$(binding_file_for "${pkgfile}")"
  current_fingerprint="$(input_fingerprint_for "${pkg}")"

  if [[ ! -e "${binding_file}" && ! -L "${binding_file}" ]]; then
    [[ "${trust_existing}" -eq 1 ]] || return 1
    python3 "${script_dir}/check-package-repo.py" "${repo_dir}" \
      --retained-root "${retained_repo_root}" --candidate "${pkgfile}" >/dev/null
    log "recording input/artifact binding for existing ${pkg}; ${pkgfile##*/} is trusted"
    record_artifact_binding "${pkg}" "${pkgfile}" "${current_fingerprint}"
    printf '%s\n' "${pkgfile}"
    return 0
  fi

  python3 "${script_dir}/check-package-repo.py" "${repo_dir}" \
    --retained-root "${retained_repo_root}" --candidate "${pkgfile}" \
    --binding "${binding_file}" \
    --expected-input-sha256 "${current_fingerprint}" >/dev/null 2>&1 || return 1
  printf '%s\n' "${pkgfile}"
}

validate_package_paths() {
  local pkg="$1" input_lines input prefix rest relative destination

  assert_path_beneath \
    "${work_dir}" "${work_dir}/${pkg}" "package work destination"
  input_lines="$(python3 "${manifest_cli}" --repo "${root}" inputs "${pkg}")" || \
    return 1
  while IFS= read -r input || [[ -n "${input}" ]]; do
    [[ -n "${input}" ]] || continue
    resolve_input_path "${input}" >/dev/null
    prefix="${input%%/*}"
    case "${prefix}" in
      THORCH_FIRMWARE_DIR|THORCH_ROCKNIX_DIR|THORCH_ROCKNIX_KERNEL_DIR|THORCH_ROCKNIX_RUNTIME_DIR)
        if [[ "${prefix}" == "${input}" ]]; then
          rest=""
        else
          rest="${input#*/}"
        fi
        relative="${!prefix}${rest:+/${rest}}"
        destination="${input_dir}/${relative}"
        assert_path_beneath \
          "${input_dir}" "${destination}" "package input destination"
        ;;
    esac
  done <<< "${input_lines}"
}

for pkg in "${packages[@]}"; do
  validate_package_paths "${pkg}"
done
if [[ "${validate_input_paths}" -eq 1 ]]; then
  log "package input paths are contained and valid"
  exit 0
fi

require_root
require_cmd bsdtar cp curl git mktemp python3 repo-add rsync sha256sum vercmp
require_rootfs_runner
machine_name="$(nspawn_machine_name pkg-root "${build_root}")"
base_machine_name="$(nspawn_machine_name pkg-base-root "${base_root}")"

for stale_root in "${base_root}" "${build_root}"; do
  if mountpoint -q "${stale_root}/proc"; then
    warn "unmounting stale package chroot proc filesystem: ${stale_root}/proc"
    unmount_path_if_mounted "${stale_root}/proc" || \
      die "unable to unmount stale package chroot proc filesystem: ${stale_root}/proc"
  fi
done

validate_local_repo() {
  python3 "${script_dir}/check-package-repo.py" "${repo_dir}" \
    --retained-root "${retained_repo_root}" \
    --bindings-root "${repo_dir}/.thorch-inputs" "$@"
}

stale_packages=()
for pkg in "${packages[@]}"; do
  if pkgfile="$(fresh_repo_package_for "${pkg}")"; then
    if [[ "${skip_fresh}" -eq 1 ]]; then
      log "skipping ${pkg}; ${pkgfile##*/} is fresh"
    else
      log "reusing ${pkg}; ${pkgfile##*/} has identical declared inputs"
    fi
    continue
  fi
  stale_packages+=("${pkg}")
done
packages=("${stale_packages[@]}")
if [[ "${#packages[@]}" -eq 0 ]]; then
  validate_local_repo --require "${selected_packages[@]}" >/dev/null
  log "all requested packages have unchanged declared inputs"
  exit 0
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
  ! rocknix_kernel_artifacts_current "${root}/${THORCH_ROCKNIX_KERNEL_DIR}"; then
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

install -d "${cache_dir}" "${repo_dir}" "$(dirname "${base_root}")"
if [[ ! -d "${base_root}/usr" || ! -f "${base_root_schema_file}" ||
  "$(cat "${base_root_schema_file}" 2>/dev/null || true)" != "${base_root_schema}" ]]; then
  log "extracting pristine package base root"
  assert_path_beneath "${build_dir}" "${base_root}" "package base root"
  rm -rf "${base_root}"
  install -d "${base_root}"
  ensure_alarm_rootfs "${rootfs_tar}"
  extract_alarm_rootfs "${rootfs_tar}" "${base_root}"
  repair_alarm_usrmerge_links "${base_root}"
  printf '%s\n' "${base_root_schema}" > "${base_root_schema_file}"
else
  if [[ -f "${rootfs_tar}" ]]; then
    verify_alarm_rootfs "${rootfs_tar}" || \
      die "cached Arch Linux ARM rootfs failed verification; remove ${rootfs_tar} before recreating the package base root"
  fi
  repair_alarm_usrmerge_links "${base_root}"
fi

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  cp /usr/bin/qemu-aarch64-static "${base_root}/usr/bin/"
fi
configure_chroot_resolver "${base_root}"
configure_alarm_pacman "${base_root}"
# This root exists only to build packages under emulation; unlike the image
# root, its pacman configuration is never shipped to users.
configure_pacman_for_emulated_build "${base_root}/etc/pacman.conf"
mask_chroot_stock_kernel_hooks "${base_root}"

run_base_chroot() {
  run_aarch64_rootfs_shell "${base_root}" "${base_machine_name}" "$*"
}

run_chroot() {
  run_aarch64_rootfs_shell "${build_root}" "${machine_name}" "$*"
}

remove_repo_artifact() {
  local pkgfile="$1" target
  local -a targets=(
    "${pkgfile}"
    "${pkgfile}.sig"
    "$(binding_file_for "${pkgfile}")"
    "$(legacy_fingerprint_file_for "${pkgfile}")"
  )

  for target in "${targets[@]}"; do
    assert_path_beneath "${repo_dir}" "${target}" "package repository removal"
  done
  rm -f -- "${targets[@]}"
}

prune_stale_repo_packages() {
  local -A best_file=()
  local -A best_version=()
  local file pkgname pkgver current cmp

  shopt -s nullglob
  for file in "${repo_dir}"/*.pkg.tar.*; do
    [[ "${file}" != *.sig ]] || continue
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
      remove_repo_artifact "${current}"
      best_file["${pkgname}"]="${file}"
      best_version["${pkgname}"]="${pkgver}"
    else
      remove_repo_artifact "${file}"
    fi
  done
  shopt -u nullglob
}

update_local_repo() {
  local file metadata_file
  local -a repo_packages=()

  prune_stale_repo_packages
  shopt -s nullglob
  for metadata_file in "${repo_dir}/thorch.db"* "${repo_dir}/thorch.files"*; do
    assert_path_beneath \
      "${repo_dir}" "${metadata_file}" "package repository metadata removal"
    rm -f -- "${metadata_file}"
  done
  shopt -u nullglob
  shopt -s nullglob
  for file in "${repo_dir}"/*.pkg.tar.*; do
    [[ "${file}" != *.sig ]] || continue
    repo_packages+=("${file}")
  done
  shopt -u nullglob
  if [[ "${#repo_packages[@]}" -eq 0 ]]; then
    return 1
  fi
  repo-add "${repo_dir}/thorch.db.tar.gz" "${repo_packages[@]}" >/dev/null
}

sync_input_path() {
  local source="$1" relative="$2"
  local destination="${input_dir}/${relative}"

  [[ -e "${source}" || -L "${source}" ]] || return 0
  assert_path_beneath "${root}" "${source}" "package input source"
  assert_path_beneath "${input_dir}" "${destination}" "package input destination"
  rm -rf "${destination}"
  install -d "$(dirname "${destination}")"
  if [[ -d "${source}" && ! -L "${source}" ]]; then
    install -d "${destination}"
    rsync -a "${source}/" "${destination}/"
  else
    cp -a "${source}" "${destination}"
  fi
}

sync_package_inputs() {
  local pkg="$1" input_lines input prefix rest base relative source
  local -A synced=()

  assert_path_beneath "${build_root}" "${input_dir}" "package input root"
  rm -rf "${input_dir}"
  install -d "${input_dir}"
  input_lines="$(python3 "${manifest_cli}" --repo "${root}" inputs "${pkg}")" || \
    return 1
  while IFS= read -r input || [[ -n "${input}" ]]; do
    [[ -n "${input}" ]] || continue
    prefix="${input%%/*}"
    case "${prefix}" in
      THORCH_FIRMWARE_DIR|THORCH_ROCKNIX_DIR|THORCH_ROCKNIX_KERNEL_DIR|THORCH_ROCKNIX_RUNTIME_DIR)
        base="${!prefix}"
        if [[ "${prefix}" == "${input}" ]]; then
          rest=""
        else
          rest="${input#*/}"
        fi
        relative="${base}${rest:+/${rest}}"
        [[ -z "${synced[${relative}]:-}" ]] || continue
        synced["${relative}"]=1
        source="$(resolve_input_path "${input}")"
        sync_input_path "${source}" "${relative}"
        ;;
    esac
  done <<< "${input_lines}"
}

stage_local_build_repo() {
  local pacman_conf="${build_root}/etc/pacman.conf"

  assert_path_beneath \
    "${build_root}" "${build_root}/thorch-repo" "staged package repository"
  rm -rf "${build_root}/thorch-repo"
  if [[ ! -e "${repo_dir}/thorch.db" ]]; then
    return 0
  fi
  install -d "${build_root}/thorch-repo"
  rsync -a "${repo_dir}/" "${build_root}/thorch-repo/"
  install -d "${build_root}/var/lib/pacman/sync"
  cp -L "${repo_dir}/thorch.db" \
    "${build_root}/var/lib/pacman/sync/thorch-build.db"
  {
    printf '\n[thorch-build]\n'
    printf 'SigLevel = Optional TrustAll\n'
    printf 'Server = file:///thorch-repo\n'
  } >> "${pacman_conf}"
}

reset_package_root() {
  local pkg="$1"

  if mountpoint -q "${build_root}/proc"; then
    unmount_path_if_mounted "${build_root}/proc" || \
      die "unable to unmount package root before building ${pkg}"
  fi
  assert_path_beneath "${build_dir}" "${build_root}" "package build root"
  rm -rf "${build_root}"
  install -d "${build_root}"
  cp -a --reflink=auto "${base_root}/." "${build_root}/"
  configure_chroot_resolver "${build_root}"
  stage_local_build_repo
  sync_package_inputs "${pkg}"
}

log "preparing pristine aarch64 package base root"
run_base_chroot "pacman-key --init >/dev/null 2>&1 || true"
run_base_chroot "pacman-key --populate archlinuxarm >/dev/null 2>&1 || true"
run_base_chroot "pacman -Syu --noconfirm --needed base-devel python sudo"
run_base_chroot "gpgconf --kill all >/dev/null 2>&1 || pkill gpg-agent >/dev/null 2>&1 || true"
run_base_chroot "id builder >/dev/null 2>&1 || useradd -m builder"
run_base_chroot "install -d -o builder -g builder /nix /home/builder"
run_base_chroot "install -d -m 0750 /etc/sudoers.d && printf '%s\\n' 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/thorch-builder && chmod 0440 /etc/sudoers.d/thorch-builder"

retained_repo="$("${script_dir}/archive-package-repo.sh" "${repo_dir}")"
[[ -z "${retained_repo}" ]] || log "retained local repository bytes at ${retained_repo}"
update_local_repo || true
for pkg in "${packages[@]}"; do
  log "building ${pkg} in an isolated package root"
  package_inputs_sha256="$(input_fingerprint_for "${pkg}")"
  reset_package_root "${pkg}"
  assert_path_beneath "${work_dir}" "${work_dir}/${pkg}" "package work destination"
  assert_path_beneath "${build_root}" "${pkgdest}" "package artifact destination"
  rm -rf "${work_dir:?}/${pkg}" "${pkgdest:?}"
  install -d "${work_dir}/${pkg}" "${pkgdest}"
  rsync -a "${root}/packages/${pkg}/" "${work_dir}/${pkg}/"
  run_chroot "chown -R builder:builder /thorch-work/${pkg} /thorch-pkgdest"
  package_env="env PKGDEST=/thorch-pkgdest THORCH_ROCKNIX_DIR=/thorch-input/${THORCH_ROCKNIX_DIR} THORCH_FIRMWARE_DIR=/thorch-input/${THORCH_FIRMWARE_DIR} THORCH_ROCKNIX_KERNEL_DIR=/thorch-input/${THORCH_ROCKNIX_KERNEL_DIR} THORCH_ROCKNIX_RUNTIME_DIR=/thorch-input/${THORCH_ROCKNIX_RUNTIME_DIR}"
  run_chroot "cd /thorch-work/${pkg} && su builder -c '${package_env} makepkg --printsrcinfo > .SRCINFO'"
  run_chroot "test -s /thorch-work/${pkg}/.SRCINFO && grep -Eq '^[[:space:]]*pkgname = ${pkg}$' /thorch-work/${pkg}/.SRCINFO" || \
    die "makepkg generated invalid .SRCINFO for ${pkg}"
  run_chroot "cd /thorch-work/${pkg} && su builder -c '${package_env} makepkg --syncdeps --noconfirm --cleanbuild'"
  current_inputs_sha256="$(input_fingerprint_for "${pkg}")"
  [[ "${current_inputs_sha256}" == "${package_inputs_sha256}" ]] || \
    die "declared inputs changed while building ${pkg}; discard the artifact and retry"
  built_files=0
  shopt -s nullglob
  for pkgfile in "${pkgdest}"/*.pkg.tar.*; do
    python3 "${script_dir}/check-package-repo.py" "${repo_dir}" \
      --retained-root "${retained_repo_root}" --candidate "${pkgfile}" >/dev/null
    destination="${repo_dir}/${pkgfile##*/}"
    assert_path_beneath "${repo_dir}" "${destination}" "package repository destination"
    cp -f "${pkgfile}" "${destination}"
    record_artifact_binding "${pkg}" "${destination}" "${package_inputs_sha256}"
    built_files=$((built_files + 1))
  done
  shopt -u nullglob
  [[ "${built_files}" -gt 0 ]] || die "makepkg produced no package for ${pkg}"
  update_local_repo
done

log "validating local package repository"
validate_local_repo --require "${selected_packages[@]}"
retained_repo="$("${script_dir}/archive-package-repo.sh" "${repo_dir}")"
[[ -z "${retained_repo}" ]] || log "retained local repository bytes at ${retained_repo}"
log "packages available in ${repo_dir}"
