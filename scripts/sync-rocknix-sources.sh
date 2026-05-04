#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/sync-rocknix-sources.sh [--ref <commit-or-branch>] [--dest <dir>] [--with-firmware]

Synchronizes selected public ROCKNIX SM8550 filesystem overlays, package
patchsets, configs, and metadata into vendor/rocknix-sm8550. This keeps Thorch
builds reproducible from public upstream inputs.

Use --with-firmware to also sync the public SM8550/AYN Thor firmware blobs.
Release builds should pass a full commit SHA.
EOF
}

ref="${ROCKNIX_REF}"
dest="${THORCH_ROCKNIX_DIR}"
with_firmware=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ref)
      ref="${2:-}"
      [[ -n "${ref}" ]] || die "--ref requires a value"
      shift 2
      ;;
    --dest)
      dest="${2:-}"
      [[ -n "${dest}" ]] || die "--dest requires a value"
      shift 2
      ;;
    --with-firmware)
      with_firmware=1
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

require_cmd git rsync install

root="$(repo_root)"
if [[ "${dest}" == /* ]]; then
  dest_abs="$(abspath "${dest}")"
else
  dest_abs="$(abspath "${root}/${dest}")"
fi
tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

log "fetching ROCKNIX distribution ref ${ref}"
clone_url="${ROCKNIX_REPO%.git}.git"
git clone --depth 1 --filter=blob:none --sparse "${clone_url}" "${tmpdir}/distribution"
cd "${tmpdir}/distribution"
sparse_paths=(
  projects/ROCKNIX/devices/SM8550/filesystem/usr/share/inputplumber
  projects/ROCKNIX/devices/SM8550/config
  projects/ROCKNIX/devices/SM8550/linux
  projects/ROCKNIX/devices/SM8550/patches
  projects/ROCKNIX/packages/apps/gamescope/patches
  projects/ROCKNIX/packages/apps/mangohud/config
  projects/ROCKNIX/packages/apps/mangohud/patches/SM8550
  projects/ROCKNIX/packages/hardware/quirks/platforms/SM8550
)
if [[ "${with_firmware}" -eq 1 ]]; then
  sparse_paths+=(projects/ROCKNIX/devices/SM8550/filesystem/usr/lib/kernel-overlays/base/lib/firmware)
fi
git sparse-checkout set "${sparse_paths[@]}"

if ! git checkout "${ref}" >/dev/null 2>&1; then
  git fetch --depth 1 origin "${ref}"
  git checkout FETCH_HEAD
fi

resolved_ref="$(git rev-parse HEAD)"
rocknix_root="projects/ROCKNIX"
src="${rocknix_root}/devices/SM8550"

sync_required_dir() {
  local from="$1" to="$2"
  [[ -d "${from}" ]] || die "required ROCKNIX path missing: ${from}"
  rm -rf "${to}"
  install -d "$(dirname "${to}")"
  rsync -a "${from}/" "${to}/"
}

sync_optional_dir() {
  local from="$1" to="$2"
  rm -rf "${to}"
  if [[ ! -d "${from}" ]]; then
    warn "optional ROCKNIX path missing, cleared local copy: ${from}"
    return 0
  fi
  install -d "$(dirname "${to}")"
  rsync -a "${from}/" "${to}/"
}

install -d "${dest_abs}"
sync_required_dir "${src}/config" "${dest_abs}/config"
sync_optional_dir "${src}/filesystem/usr/share/inputplumber" "${dest_abs}/inputplumber"
sync_optional_dir "${src}/linux" "${dest_abs}/linux"
sync_optional_dir "${src}/patches" "${dest_abs}/patches"
sync_required_dir "${rocknix_root}/packages/apps/gamescope/patches" "${dest_abs}/packages/apps/gamescope/patches"
sync_required_dir "${rocknix_root}/packages/apps/mangohud/config" "${dest_abs}/packages/apps/mangohud/config"
sync_required_dir "${rocknix_root}/packages/apps/mangohud/patches/SM8550" "${dest_abs}/packages/apps/mangohud/patches/SM8550"
sync_required_dir "${rocknix_root}/packages/hardware/quirks/platforms/SM8550" "${dest_abs}/packages/hardware/quirks/platforms/SM8550"

{
  printf 'ROCKNIX_REPO=%s\n' "${ROCKNIX_REPO}"
  printf 'REQUESTED_REF=%s\n' "${ref}"
  printf 'RESOLVED_REF=%s\n' "${resolved_ref}"
  date -u '+SYNCED_AT=%Y-%m-%dT%H:%M:%SZ'
} > "${dest_abs}/SOURCE_PROVENANCE"
chmod 0644 "${dest_abs}/SOURCE_PROVENANCE"

if [[ "${with_firmware}" -eq 1 ]]; then
  fw_src="${src}/filesystem/usr/lib/kernel-overlays/base/lib/firmware"
  rm -rf "${dest_abs}/firmware"
  install -d "${dest_abs}/firmware"
  rsync -a "${fw_src}/" "${dest_abs}/firmware/"
  {
    printf 'ROCKNIX_REPO=%s\n' "${ROCKNIX_REPO}"
    printf 'REQUESTED_REF=%s\n' "${ref}"
    printf 'RESOLVED_REF=%s\n' "${resolved_ref}"
    printf 'ROCKNIX_FIRMWARE_PATH=%s\n' "${fw_src}"
    date -u '+SYNCED_AT=%Y-%m-%dT%H:%M:%SZ'
  } > "${dest_abs}/firmware/THORCH_FIRMWARE_PROVENANCE"
  chmod 0644 "${dest_abs}/firmware/THORCH_FIRMWARE_PROVENANCE"
fi

log "ROCKNIX SM8550 sources synced to ${dest_abs}"
