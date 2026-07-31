#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/import-rocknix-runtime.sh --root-dir <dir> [--dest <dir>] [--ref <label>]

Imports selected ROCKNIX /SYSTEM runtime artifacts for Thorch, including the
prebuilt FEX emulator, FEX thunks, matching x86_64 guest Vulkan driver, binfmt
registrations, and ABI compatibility libraries needed by those binaries.
EOF
}

require_value() {
  local opt="$1" value="${2:-}"
  [[ -n "${value}" ]] || {
    usage
    die "${opt} requires a value"
  }
}

root_dir=""
dest="${THORCH_ROCKNIX_RUNTIME_DIR}"
ref_label="${ROCKNIX_REF}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --from-dir|--root-dir)
      require_value "$1" "${2:-}"
      root_dir="$2"
      shift 2
      ;;
    --dest)
      require_value "$1" "${2:-}"
      dest="$2"
      shift 2
      ;;
    --ref)
      require_value "$1" "${2:-}"
      ref_label="$2"
      shift 2
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

[[ -n "${root_dir}" ]] || {
  usage
  die "provide --root-dir"
}

require_cmd find install rsync

root="$(repo_root)"
if [[ "${dest}" == /* ]]; then
  dest_abs="$(abspath "${dest}")"
else
  dest_abs="$(abspath "${root}/${dest}")"
fi
root_dir_abs="$(abspath "${root_dir}")"

case "${root_dir_abs}" in
  *"${root}/packages/"*"/pkg"*|*"${root}/packages/"*"/src"*)
    die "refusing to import runtime artifacts from local makepkg pkg/src outputs; use a mounted or extracted ROCKNIX image"
    ;;
esac

runtime_root=""
for candidate in "${root_dir_abs}" "${root_dir_abs}/system"; do
  if [[ -x "${candidate}/usr/bin/FEX" ]]; then
    runtime_root="${candidate}"
    break
  fi
done
[[ -n "${runtime_root}" ]] || die "could not find ROCKNIX FEX runtime under ${root_dir_abs}"

copy_path() {
  local rel="$1"

  [[ -e "${runtime_root}/${rel}" || -L "${runtime_root}/${rel}" ]] || return 0
  install -d "${dest_abs}/$(dirname "${rel}")"
  rsync -a "${runtime_root}/${rel}" "${dest_abs}/$(dirname "${rel}")/"
}

rm -rf "${dest_abs}"
install -d "${dest_abs}"

for bin in \
  FEX \
  FEXBash \
  FEXConfig \
  FEXGetConfig \
  FEXInterpreter \
  FEXOfflineCompiler \
  FEXRootFSFetcher \
  FEXServer \
  FEXServerManager \
  FEXpidof
do
  copy_path "usr/bin/${bin}"
done

copy_path usr/lib/fex-emu
copy_path usr/lib/binfmt.d/FEX-x86.conf
copy_path usr/lib/binfmt.d/FEX-x86_64.conf
copy_path usr/share/fex-emu/AppConfig
copy_path usr/share/fex-emu/GuestThunks
copy_path usr/share/fex-emu/GuestThunks_32
copy_path usr/share/fex-emu/ThunksDB.json
copy_path usr/share/fex-emu/libvulkan_freedreno.so
copy_path usr/config/fex-emu

for fmt_lib in "${runtime_root}"/usr/lib/libfmt.so.11*; do
  [[ -e "${fmt_lib}" || -L "${fmt_lib}" ]] || continue
  install -d "${dest_abs}/usr/lib"
  rsync -a "${fmt_lib}" "${dest_abs}/usr/lib/"
done

[[ -x "${dest_abs}/usr/bin/FEX" ]] || die "ROCKNIX runtime import did not produce usr/bin/FEX"
[[ -x "${dest_abs}/usr/bin/FEXRootFSFetcher" ]] || die "ROCKNIX runtime import did not produce usr/bin/FEXRootFSFetcher"
[[ -d "${dest_abs}/usr/lib/fex-emu/HostThunks" ]] || die "ROCKNIX runtime import did not produce HostThunks"
[[ -d "${dest_abs}/usr/share/fex-emu/GuestThunks" ]] || die "ROCKNIX runtime import did not produce GuestThunks"
[[ -f "${dest_abs}/usr/share/fex-emu/libvulkan_freedreno.so" ]] || die "ROCKNIX runtime import did not produce the FEX guest Vulkan driver"

{
  printf 'ROCKNIX_REPO=%s\n' "${ROCKNIX_REPO}"
  printf 'ROCKNIX_REF=%s\n' "${ref_label}"
  printf 'SOURCE_ROOT_DIR=%s\n' "${root_dir_abs}"
  printf 'SOURCE_RUNTIME_ROOT=%s\n' "${runtime_root}"
  printf 'SOURCE_FEX=%s\n' "${runtime_root}/usr/bin/FEX"
  printf 'SOURCE_FEX_ROOTFS_FETCHER=%s\n' "${runtime_root}/usr/bin/FEXRootFSFetcher"
  printf 'SOURCE_FEX_HOST_THUNKS=%s\n' "${runtime_root}/usr/lib/fex-emu/HostThunks"
  printf 'SOURCE_FEX_GUEST_THUNKS=%s\n' "${runtime_root}/usr/share/fex-emu/GuestThunks"
  printf 'SOURCE_FEX_VULKAN_FREEDRENO=%s\n' "${runtime_root}/usr/share/fex-emu/libvulkan_freedreno.so"
  date -u '+IMPORTED_AT=%Y-%m-%dT%H:%M:%SZ'
} > "${dest_abs}/PROVENANCE"
chmod 0644 "${dest_abs}/PROVENANCE"

log "ROCKNIX runtime artifacts imported to ${dest_abs}"
