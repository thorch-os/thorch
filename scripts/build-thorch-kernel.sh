#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-thorch-kernel.sh [options]

Builds a Thorch-owned Thor kernel from ROCKNIX's public kernel recipe, applies
the Waydroid/BinderFS kernel config fragment, installs the matching modules into
vendor/rocknix-kernel, and repacks that directory's Android /KERNEL template
with the new kernel and all SM8550 DTB payloads.

This script expects scripts/sync-rocknix-kernel.sh or make kernel to have already
imported a ROCKNIX kernel/runtime tree. The imported tree supplies firmware,
runtime graphics/FEX files, and the Android boot-image template that Thor's ABL
accepts; the source-built kernel and modules replace the imported kernel bits.

Options:
  --repo <url>              Kernel git repository.
  --ref <ref>               Kernel branch/tag/commit.
  --tarball-url <url>       Kernel source tarball. Set empty to use git.
  --tarball-sha256 <sha>    Optional sha256 for the tarball.
  --source-dir <dir>        Git checkout directory. Default: build/kernel-src.
  --build-dir <dir>         Out-of-tree build directory. Default: build/kernel-build.
  --config <file>           Base kernel .config. Default: ROCKNIX linux.aarch64.conf.
  --fragment <file>         Required Thorch config fragment.
  --patch-dir <dir>         ROCKNIX kernel patch directory. May be repeated.
  --dts-dir <dir>           ROCKNIX DTS overlay directory.
  --dts-patch-dir <dir>     DTS patch directory applied after DTS overlay copy. May be repeated.
  --dest <dir>              Kernel artifact destination. Default: vendor/rocknix-kernel.
  --template <file>         Android boot image template. Default: <dest>/boot/KERNEL.
  --jobs <n>                Parallel make jobs. Default: nproc.
  --cross-compile <prefix>  Cross compiler prefix. Default: aarch64-linux-gnu-.
  --no-fetch                Use the existing source checkout without fetching.
  --reuse-build-dir         Reuse the out-of-tree build directory for faster
                            local/debug rebuilds. Default is a clean build dir.
  --skip-kernel-patches     Assume the source checkout already has kernel
                            patches applied. DTS overlays are still refreshed.
EOF
}

path_abs() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    abspath "${path}"
  else
    abspath "${root}/${path}"
  fi
}

root="$(repo_root)"
source_repo="${THORCH_KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
source_ref="${THORCH_KERNEL_REF:-v7.0.2}"
source_version="${source_ref#v}"
source_major="${source_version%%.*}"
tarball_url="${THORCH_KERNEL_TARBALL_URL:-https://www.kernel.org/pub/linux/kernel/v${source_major}.x/linux-${source_version}.tar.xz}"
tarball_sha256="${THORCH_KERNEL_TARBALL_SHA256:-}"
source_dir="${THORCH_KERNEL_SOURCE_DIR:-${THORCH_BUILD_DIR}/kernel-src}"
build_dir="${THORCH_KERNEL_BUILD_DIR:-${THORCH_BUILD_DIR}/kernel-build}"
base_config="${THORCH_KERNEL_CONFIG:-${THORCH_ROCKNIX_DIR}/linux/linux.aarch64.conf}"
fragment="${THORCH_KERNEL_CONFIG_FRAGMENT:-packages/linux-thorch/waydroid-kernel.config}"
read -r -a patch_dirs <<< "${THORCH_KERNEL_PATCH_DIRS:-${THORCH_ROCKNIX_DIR}/packages/linux/patches/mainline ${THORCH_ROCKNIX_DIR}/patches/linux ${THORCH_ROCKNIX_DIR}/packages/linux/patches/default ${THORCH_ROCKNIX_DIR}/packages/linux/patches/7.0 packages/linux-thorch/patches}"
dts_dir="${THORCH_KERNEL_DTS_DIR:-${THORCH_ROCKNIX_DIR}/linux/dts}"
read -r -a dts_patch_dirs <<< "${THORCH_KERNEL_DTS_PATCH_DIRS:-packages/linux-thorch/dts-patches}"
dest="${THORCH_ROCKNIX_KERNEL_DIR}"
template=""
jobs="${THORCH_KERNEL_JOBS:-$(nproc)}"
cross_compile="${THORCH_KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-}"
fetch=1
reuse_build_dir="${THORCH_KERNEL_REUSE_BUILD_DIR:-0}"
skip_kernel_patches=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      source_repo="${2:-}"
      [[ -n "${source_repo}" ]] || die "--repo requires a value"
      shift 2
      ;;
    --ref)
      source_ref="${2:-}"
      [[ -n "${source_ref}" ]] || die "--ref requires a value"
      shift 2
      ;;
    --tarball-url)
      tarball_url="${2:-}"
      shift 2
      ;;
    --tarball-sha256)
      tarball_sha256="${2:-}"
      [[ -n "${tarball_sha256}" ]] || die "--tarball-sha256 requires a value"
      shift 2
      ;;
    --source-dir)
      source_dir="${2:-}"
      [[ -n "${source_dir}" ]] || die "--source-dir requires a value"
      shift 2
      ;;
    --build-dir)
      build_dir="${2:-}"
      [[ -n "${build_dir}" ]] || die "--build-dir requires a value"
      shift 2
      ;;
    --config)
      base_config="${2:-}"
      [[ -n "${base_config}" ]] || die "--config requires a value"
      shift 2
      ;;
    --fragment)
      fragment="${2:-}"
      [[ -n "${fragment}" ]] || die "--fragment requires a value"
      shift 2
      ;;
    --patch-dir)
      [[ -n "${2:-}" ]] || die "--patch-dir requires a value"
      patch_dirs+=("$2")
      shift 2
      ;;
    --dts-dir)
      dts_dir="${2:-}"
      [[ -n "${dts_dir}" ]] || die "--dts-dir requires a value"
      shift 2
      ;;
    --dts-patch-dir)
      [[ -n "${2:-}" ]] || die "--dts-patch-dir requires a value"
      dts_patch_dirs+=("$2")
      shift 2
      ;;
    --dest)
      dest="${2:-}"
      [[ -n "${dest}" ]] || die "--dest requires a value"
      shift 2
      ;;
    --template)
      template="${2:-}"
      [[ -n "${template}" ]] || die "--template requires a value"
      shift 2
      ;;
    --jobs)
      jobs="${2:-}"
      [[ "${jobs}" =~ ^[0-9]+$ && "${jobs}" -gt 0 ]] || die "--jobs must be a positive integer"
      shift 2
      ;;
    --cross-compile)
      cross_compile="${2:-}"
      [[ -n "${cross_compile}" ]] || die "--cross-compile requires a value"
      shift 2
      ;;
    --no-fetch)
      fetch=0
      shift
      ;;
    --reuse-build-dir|--incremental)
      reuse_build_dir=1
      shift
      ;;
    --skip-kernel-patches)
      skip_kernel_patches=1
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

case "${reuse_build_dir}" in
  0|1) ;;
  *) die "THORCH_KERNEL_REUSE_BUILD_DIR must be 0 or 1" ;;
esac

source_abs="$(path_abs "${source_dir}")"
build_abs="$(path_abs "${build_dir}")"
config_abs="$(path_abs "${base_config}")"
fragment_abs="$(path_abs "${fragment}")"
dts_abs="$(path_abs "${dts_dir}")"
dest_abs="$(path_abs "${dest}")"
template="${template:-${dest_abs}/boot/KERNEL}"
template_abs="$(path_abs "${template}")"

if [[ -n "${tarball_url}" ]]; then
  require_cmd curl depmod git gzip install make patch python3 rsync sha256sum tar xz "${cross_compile}gcc"
else
  require_cmd depmod git gzip install make patch python3 rsync "${cross_compile}gcc"
fi

[[ -f "${config_abs}" ]] || die "missing base kernel config: ${config_abs}"
[[ -f "${fragment_abs}" ]] || die "missing Thorch kernel config fragment: ${fragment_abs}"
[[ -d "${dts_abs}" ]] || die "missing ROCKNIX DTS overlay directory: ${dts_abs}"
[[ -f "${template_abs}" ]] || die "missing Android boot template: ${template_abs}; run scripts/sync-rocknix-kernel.sh first"
[[ -d "${dest_abs}/usr/lib/firmware" ]] || die "missing ROCKNIX firmware in ${dest_abs}; run scripts/sync-rocknix-kernel.sh first"

if [[ -n "${tarball_url}" && "${fetch}" -eq 1 ]]; then
  cache_dir="$(path_abs "${THORCH_BUILD_DIR}/cache/kernel")"
  tarball_name="${tarball_url%%\?*}"
  tarball_name="${tarball_name##*/}"
  [[ -n "${tarball_name}" ]] || die "could not determine tarball filename from ${tarball_url}"
  tarball_path="${cache_dir}/${tarball_name}"

  install -d "${cache_dir}"
  log "downloading ROCKNIX kernel base tarball ${tarball_name}"
  curl -fL --continue-at - -o "${tarball_path}" "${tarball_url}"
  if [[ -n "${tarball_sha256}" ]]; then
    printf '%s  %s\n' "${tarball_sha256}" "${tarball_path}" | sha256sum -c -
  fi
  case "${source_abs}" in
    "${root}/${THORCH_BUILD_DIR}/"*) rm -rf "${source_abs}" ;;
    *) [[ ! -e "${source_abs}" ]] || die "refusing to overwrite custom kernel source path: ${source_abs}" ;;
  esac
  install -d "${source_abs}"
  log "extracting ROCKNIX kernel base tarball"
  tar -xf "${tarball_path}" --strip-components=1 -C "${source_abs}"
  git -C "${source_abs}" init -q
  resolved_ref="${source_ref}"
elif [[ ! -d "${source_abs}/.git" ]]; then
  [[ "${fetch}" -eq 1 ]] || die "kernel source checkout is missing and --no-fetch was supplied: ${source_abs}"
  if [[ -e "${source_abs}" ]]; then
    case "${source_abs}" in
      "${root}/${THORCH_BUILD_DIR}/"*) rm -rf "${source_abs}" ;;
      *) die "kernel source path exists but is not a git checkout: ${source_abs}" ;;
    esac
  fi
  install -d "$(dirname "${source_abs}")"
  log "cloning ROCKNIX kernel base ${source_repo}"
  git clone --filter=blob:none --no-checkout "${source_repo}" "${source_abs}"
  resolved_ref=""
elif [[ "${fetch}" -eq 1 ]]; then
  log "fetching ROCKNIX kernel base ref ${source_ref}"
  current_origin="$(git -C "${source_abs}" config --get remote.origin.url || true)"
  [[ "${current_origin}" == "${source_repo}" ]] || die "kernel checkout origin is ${current_origin:-unset}, expected ${source_repo}; remove ${source_abs} or set THORCH_KERNEL_SOURCE_DIR"
  git -C "${source_abs}" fetch --tags origin "${source_ref}"
  git -C "${source_abs}" checkout --detach --force FETCH_HEAD
  git -C "${source_abs}" reset --hard FETCH_HEAD >/dev/null
  git -C "${source_abs}" clean -fdx >/dev/null
  resolved_ref="$(git -C "${source_abs}" rev-parse HEAD)"
else
  log "using existing Thor kernel source checkout at ${source_abs}"
  resolved_ref="$(git -C "${source_abs}" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' "${source_ref}")"
fi
if [[ -z "${resolved_ref}" && "${fetch}" -eq 1 ]]; then
  log "fetching ROCKNIX kernel base ref ${source_ref}"
  current_origin="$(git -C "${source_abs}" config --get remote.origin.url || true)"
  [[ "${current_origin}" == "${source_repo}" ]] || die "kernel checkout origin is ${current_origin:-unset}, expected ${source_repo}; remove ${source_abs} or set THORCH_KERNEL_SOURCE_DIR"
  git -C "${source_abs}" fetch --tags origin "${source_ref}"
  git -C "${source_abs}" checkout --detach --force FETCH_HEAD
  git -C "${source_abs}" reset --hard FETCH_HEAD >/dev/null
  git -C "${source_abs}" clean -fdx >/dev/null
  resolved_ref="$(git -C "${source_abs}" rev-parse HEAD)"
fi

apply_patch_file() {
  local patch_file="$1"

  if git -C "${source_abs}" apply --check --whitespace=nowarn "${patch_file}" >/dev/null 2>&1; then
    log "applying ROCKNIX kernel patch ${patch_file#"${root}/"}"
    git -C "${source_abs}" apply --whitespace=nowarn "${patch_file}"
  elif patch -d "${source_abs}" -p1 --dry-run --forward --batch < "${patch_file}" >/dev/null 2>&1; then
    log "applying ROCKNIX kernel patch with fuzz ${patch_file#"${root}/"}"
    patch -d "${source_abs}" -p1 --forward --batch < "${patch_file}" >/dev/null
  elif git -C "${source_abs}" apply --reverse --check --whitespace=nowarn "${patch_file}" >/dev/null 2>&1; then
    warn "ROCKNIX kernel patch is already applied, skipping: ${patch_file#"${root}/"}"
  elif patch -d "${source_abs}" -p1 --dry-run --reverse --batch < "${patch_file}" >/dev/null 2>&1; then
    warn "ROCKNIX kernel patch is already applied with fuzz, skipping: ${patch_file#"${root}/"}"
  else
    die "ROCKNIX kernel patch does not apply cleanly: ${patch_file}"
  fi
}

apply_patch_dir() {
  local patch_dir="$1" patch_abs patch_file

  patch_abs="$(path_abs "${patch_dir}")"
  if [[ ! -d "${patch_abs}" ]]; then
    warn "ROCKNIX kernel patch directory missing, skipping: ${patch_abs}"
    return 0
  fi
  while IFS= read -r patch_file; do
    apply_patch_file "${patch_file}"
  done < <(find "${patch_abs}" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
}

patch_marker="${source_abs}/.thorch-rocknix-patches-applied"
if [[ "${skip_kernel_patches}" -eq 1 ]]; then
  log "skipping kernel patch application for existing source checkout"
elif [[ "${fetch}" -eq 0 && -f "${patch_marker}" ]]; then
  log "using existing ROCKNIX-patched kernel source tree"
  log "ensuring requested local kernel patches are applied"
  for patch_dir in "${patch_dirs[@]}"; do
    [[ -n "${patch_dir}" ]] || continue
    case "${patch_dir}" in
      vendor/*|*/vendor/*)
        continue
        ;;
    esac
    apply_patch_dir "${patch_dir}"
  done
else
  log "applying ROCKNIX kernel patches"
  for patch_dir in "${patch_dirs[@]}"; do
    [[ -n "${patch_dir}" ]] || continue
    apply_patch_dir "${patch_dir}"
  done
  : > "${patch_marker}"
fi

log "copying ROCKNIX SM8550 DTS overlays"
rsync -a "${dts_abs}/" "${source_abs}/arch/arm64/boot/dts/"

log "applying Thorch DTS patches"
for patch_dir in "${dts_patch_dirs[@]}"; do
  [[ -n "${patch_dir}" ]] || continue
  apply_patch_dir "${patch_dir}"
done

if [[ "${reuse_build_dir}" -eq 1 ]]; then
  log "reusing kernel build directory at ${build_abs}"
  install -d "${build_abs}"
  if [[ ! -f "${build_abs}/.config" ]]; then
    install -Dm644 "${config_abs}" "${build_abs}/.config"
  fi
else
  rm -rf "${build_abs}"
  install -d "${build_abs}"
  install -Dm644 "${config_abs}" "${build_abs}/.config"
fi

apply_config_line() {
  local line="$1" key value symbol string

  if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]CONFIG_([A-Za-z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set[[:space:]]*$ ]]; then
    bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --disable "${BASH_REMATCH[1]}"
    return 0
  fi

  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "${line}" ]] || return 0
  [[ "${line}" == CONFIG_*=* ]] || return 0

  key="${line%%=*}"
  value="${line#*=}"
  symbol="${key#CONFIG_}"
  case "${value}" in
    y)
      bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --enable "${symbol}"
      ;;
    m)
      bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --module "${symbol}"
      ;;
    n)
      bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --disable "${symbol}"
      ;;
    \"*\")
      string="${value:1:${#value}-2}"
      bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --set-str "${symbol}" "${string}"
      ;;
    *)
      bash "${source_abs}/scripts/config" --file "${build_abs}/.config" --set-val "${symbol}" "${value}"
      ;;
  esac
}

log "applying Thorch Waydroid/BinderFS kernel config"
while IFS= read -r line || [[ -n "${line}" ]]; do
  apply_config_line "${line}"
done < "${fragment_abs}"
apply_config_line "CONFIG_IKCONFIG=y"
apply_config_line "CONFIG_IKCONFIG_PROC=y"
apply_config_line 'CONFIG_INITRAMFS_SOURCE=""'
apply_config_line 'CONFIG_DEFAULT_HOSTNAME="Thorch"'
apply_config_line 'CONFIG_LOCALVERSION=""'
apply_config_line "CONFIG_LOCALVERSION_AUTO=n"

make_args=(
  -C "${source_abs}"
  O="${build_abs}"
  ARCH=arm64
  CROSS_COMPILE="${cross_compile}"
)

log "resolving kernel config"
make "${make_args[@]}" olddefconfig

mapfile -t dtb_targets < <(
  find "${source_abs}/arch/arm64/boot/dts/qcom" -maxdepth 1 -name 'qcs8550-*.dts' \
  | LC_ALL=C sort | sed 's|.*/qcom/||; s|\.dts$|.dtb|; s|^|qcom/|'
)
[[ "${#dtb_targets[@]}" -gt 0 ]] || die "no qcs8550 DTS files found in ${source_abs}/arch/arm64/boot/dts/qcom/"

log "building Thor kernel, ${#dtb_targets[@]} SM8550 DTBs, and modules"
make "${make_args[@]}" -j"${jobs}" Image "${dtb_targets[@]}" modules
kernver="$(make "${make_args[@]}" -s kernelrelease)"
[[ -n "${kernver}" ]] || die "unable to determine built kernel release"

image="${build_abs}/arch/arm64/boot/Image"
dtb_dir="${build_abs}/arch/arm64/boot/dts/qcom"
[[ -f "${image}" ]] || die "kernel build did not produce ${image}"
[[ -n "$(find "${dtb_dir}" -maxdepth 1 -name 'qcs8550-*.dtb' -print -quit 2>/dev/null)" ]] \
  || die "kernel build did not produce any qcs8550 DTBs in ${dtb_dir}"

modules_stage="${build_abs}/modules-stage"
rm -rf "${modules_stage}"
install -d "${modules_stage}"
log "installing modules for ${kernver}"
make "${make_args[@]}" INSTALL_MOD_PATH="${modules_stage}" INSTALL_MOD_STRIP=1 DEPMOD=/bin/true modules_install
depmod -b "${modules_stage}" "${kernver}"
[[ -d "${modules_stage}/lib/modules/${kernver}" ]] || die "modules_install did not produce lib/modules/${kernver}"

boot_tmp="${build_abs}/KERNEL"
log "repacking Android boot template with source-built kernel and all SM8550 DTBs"
python3 - "${template_abs}" "${image}" "${boot_tmp}" "${dtb_dir}" <<'PY'
import gzip
import pathlib
import struct
import sys

template_path = pathlib.Path(sys.argv[1])
image_path = pathlib.Path(sys.argv[2])
out_path = pathlib.Path(sys.argv[3])
dtb_dir = pathlib.Path(sys.argv[4])

dtb_paths = sorted(dtb_dir.glob("qcs8550-*.dtb"))
if not dtb_paths:
    raise SystemExit(f"no qcs8550-*.dtb files found in {dtb_dir}")
print(f"appending {len(dtb_paths)} DTB(s): {', '.join(p.name for p in dtb_paths)}", file=sys.stderr)

data = template_path.read_bytes()
if data[:8] != b"ANDROID!":
    raise SystemExit(f"{template_path} is not an Android boot image")
if len(data) < 40:
    raise SystemExit(f"{template_path} is truncated")

def u32(offset):
    return struct.unpack_from("<I", data, offset)[0]

def align(value, page_size):
    return (value + page_size - 1) // page_size * page_size

kernel_size = u32(8)
ramdisk_size = u32(16)
second_size = u32(24)
page_size = u32(36)
if page_size <= 0 or page_size > 65536:
    raise SystemExit(f"{template_path} has invalid page size {page_size}")
if len(data) < page_size:
    raise SystemExit(f"{template_path} is smaller than its header page")

kernel_offset = page_size
ramdisk_offset = align(kernel_offset + kernel_size, page_size)
second_offset = align(ramdisk_offset + ramdisk_size, page_size)
tail_offset = align(second_offset + second_size, page_size)
if len(data) < tail_offset:
    raise SystemExit(f"{template_path} is truncated")

ramdisk = data[ramdisk_offset:ramdisk_offset + ramdisk_size]
second = data[second_offset:second_offset + second_size]
tail = data[tail_offset:]

dtb_blob = b""
for dtb_path in dtb_paths:
    dtb = dtb_path.read_bytes()
    if not dtb.startswith(b"\xd0\r\xfe\xed"):
        raise SystemExit(f"{dtb_path} is not a flattened device tree")
    dtb_blob += dtb

payload = gzip.compress(image_path.read_bytes(), compresslevel=9, mtime=0) + dtb_blob
header = bytearray(data[:page_size])
struct.pack_into("<I", header, 8, len(payload))

def pad(blob):
    return blob + (b"\0" * ((page_size - len(blob) % page_size) % page_size))

out_path.write_bytes(header + pad(payload) + pad(ramdisk) + pad(second) + tail)
PY

log "verifying embedded BinderFS kernel config"
python3 - "${image}" "${fragment_abs}" <<'PY'
import gzip
import pathlib
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
required_path = pathlib.Path(sys.argv[2])

start = image.find(b"IKCFG_ST")
end = image.find(b"IKCFG_ED", start)
if start < 0 or end < 0:
    raise SystemExit(f"{sys.argv[1]} does not embed a kernel config")

blob = image[start + len(b"IKCFG_ST"):end].lstrip(b"\x00\n")
try:
    config_text = gzip.decompress(blob).decode("utf-8", "replace")
except OSError as exc:
    raise SystemExit(f"could not decompress embedded kernel config: {exc}")

config = {}
for line in config_text.splitlines():
    if line.startswith("CONFIG_") and "=" in line:
        key, value = line.split("=", 1)
        config[key] = value
    elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
        key = line.split()[1]
        config[key] = "n"

missing = []
for raw in required_path.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if raw.startswith("# CONFIG_") and raw.endswith(" is not set"):
        key = raw.split()[1]
        value = "n"
    else:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, value = line.split("=", 1)

    if (config.get(key, "n") if value == "n" else config.get(key)) != value:
        missing.append(f"{key}={value}")

if missing:
    raise SystemExit(
        "source-built Thor kernel is missing required Waydroid support:\n  "
        + "\n  ".join(missing)
    )
PY

log "installing source-built Thor kernel artifacts into ${dest_abs}"
rm -rf "${dest_abs}/usr/lib/modules"
install -d "${dest_abs}/usr/lib/modules" "${dest_abs}/boot/dtb/qcom"
rsync -a "${modules_stage}/lib/modules/" "${dest_abs}/usr/lib/modules/"
install -Dm644 "${image}" "${dest_abs}/boot/Image"
install -Dm644 "${boot_tmp}" "${dest_abs}/boot/KERNEL"
while IFS= read -r dtb_file; do
    install -Dm644 "${dtb_file}" "${dest_abs}/boot/dtb/qcom/$(basename "${dtb_file}")"
done < <(find "${dtb_dir}" -maxdepth 1 -name 'qcs8550-*.dtb' | LC_ALL=C sort)

provenance="${dest_abs}/PROVENANCE"
provenance_tmp="$(mktemp)"
if [[ -f "${provenance}" ]]; then
  grep -Ev '^(THORCH_KERNEL_|SOURCE_THORCH_KERNEL_|WAYDROID_KERNEL_)' "${provenance}" > "${provenance_tmp}" || true
else
  : > "${provenance_tmp}"
fi
mv -f "${provenance_tmp}" "${provenance}"
{
  printf 'THORCH_KERNEL_SOURCE=source-built\n'
  printf 'THORCH_KERNEL_REPO=%s\n' "${source_repo}"
  printf 'THORCH_KERNEL_REF=%s\n' "${source_ref}"
  printf 'THORCH_KERNEL_RESOLVED_REF=%s\n' "${resolved_ref}"
  printf 'THORCH_KERNEL_RELEASE=%s\n' "${kernver}"
  printf 'THORCH_KERNEL_CONFIG=%s\n' "${config_abs}"
  printf 'THORCH_KERNEL_CONFIG_FRAGMENT=%s\n' "${fragment_abs}"
  printf 'THORCH_KERNEL_PATCH_DIRS=%s\n' "${patch_dirs[*]}"
  printf 'THORCH_KERNEL_DTS_DIR=%s\n' "${dts_abs}"
  printf 'THORCH_KERNEL_DTS_PATCH_DIRS=%s\n' "${dts_patch_dirs[*]}"
  printf 'SOURCE_THORCH_KERNEL_BOOT_TEMPLATE=%s\n' "${template_abs}"
  printf 'WAYDROID_KERNEL_BINDERFS=enabled\n'
  date -u '+THORCH_KERNEL_BUILT_AT=%Y-%m-%dT%H:%M:%SZ'
} >> "${provenance}"
chmod 0644 "${provenance}"

log "Thorch source-built BinderFS kernel ready in ${dest_abs} (${kernver})"
