#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/sync-rocknix-kernel.sh [options]

Downloads an official ROCKNIX SM8550 image, verifies it when a .sha256 asset is
available, mounts it read-only, and imports the prebuilt kernel artifacts into
vendor/rocknix-kernel plus selected runtime artifacts into vendor/rocknix-runtime.

Options:
  --source nightly|stable     Release channel to use. Project default: nightly.
  --release <tag|latest|previous>
                              Release tag, for example nightly-20260429 or
                              20250517. "previous" means the nightly before
                              the newest public nightly. The standalone script
                              fallback is latest, but project config may pin it.
  --platform <name>           ROCKNIX platform. Default: SM8550.
  --url <image-url>           Use an explicit .img.gz or .img URL.
  --sha256-url <url>          Use an explicit sha256 URL.
  --allow-unverified          Continue if no sha256 can be fetched. Unsafe.
  --cache-dir <dir>           Download/decompress cache. Default: build/cache/rocknix.
  --dest <dir>                Import destination. Default: vendor/rocknix-kernel.
  --runtime-dest <dir>        Runtime import destination. Default: vendor/rocknix-runtime.
  --keep-mounted              Leave the loop image mounted for debugging.

This script must run as root because it uses loop devices and read-only mounts.
EOF
}

source_channel="${ROCKNIX_KERNEL_SOURCE:-nightly}"
release="${ROCKNIX_KERNEL_RELEASE:-latest}"
platform="${ROCKNIX_KERNEL_PLATFORM:-SM8550}"
image_url="${ROCKNIX_KERNEL_IMAGE_URL:-}"
sha256_url="${ROCKNIX_KERNEL_SHA256_URL:-}"
cache_dir="${ROCKNIX_KERNEL_CACHE_DIR:-${THORCH_BUILD_DIR}/cache/rocknix}"
dest="${THORCH_ROCKNIX_KERNEL_DIR}"
runtime_dest="${THORCH_ROCKNIX_RUNTIME_DIR}"
keep_mounted=0
allow_unverified="${ROCKNIX_KERNEL_ALLOW_UNVERIFIED:-0}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --source)
      source_channel="${2:-}"
      [[ -n "${source_channel}" ]] || die "--source requires a value"
      shift 2
      ;;
    --release)
      release="${2:-}"
      [[ -n "${release}" ]] || die "--release requires a value"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      [[ -n "${platform}" ]] || die "--platform requires a value"
      shift 2
      ;;
    --url)
      image_url="${2:-}"
      [[ -n "${image_url}" ]] || die "--url requires a value"
      shift 2
      ;;
    --sha256-url)
      sha256_url="${2:-}"
      [[ -n "${sha256_url}" ]] || die "--sha256-url requires a value"
      shift 2
      ;;
    --allow-unverified)
      allow_unverified=1
      shift
      ;;
    --cache-dir)
      cache_dir="${2:-}"
      [[ -n "${cache_dir}" ]] || die "--cache-dir requires a value"
      shift 2
      ;;
    --dest)
      dest="${2:-}"
      [[ -n "${dest}" ]] || die "--dest requires a value"
      shift 2
      ;;
    --runtime-dest)
      runtime_dest="${2:-}"
      [[ -n "${runtime_dest}" ]] || die "--runtime-dest requires a value"
      shift 2
      ;;
    --keep-mounted)
      keep_mounted=1
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
require_cmd curl gzip jq losetup mount python3 readlink sha256sum sfdisk umount unsquashfs

root="$(repo_root)"
if [[ "${cache_dir}" == /* ]]; then
  cache_abs="$(abspath "${cache_dir}")"
else
  cache_abs="$(abspath "${root}/${cache_dir}")"
fi
if [[ "${dest}" == /* ]]; then
  dest_abs="$(abspath "${dest}")"
else
  dest_abs="$(abspath "${root}/${dest}")"
fi
if [[ "${runtime_dest}" == /* ]]; then
  runtime_dest_abs="$(abspath "${runtime_dest}")"
else
  runtime_dest_abs="$(abspath "${root}/${runtime_dest}")"
fi

github_asset_url() {
  local repo="$1" tag="$2" regex="$3"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/${tag}" |
    jq -er --arg regex "${regex}" '.assets[] | select(.name | test($regex)) | .browser_download_url' |
    head -n1
}

nightly_tag_at_index() {
  local index="$1"
  curl -fsSL 'https://api.github.com/repos/ROCKNIX/distribution-nightly/releases?per_page=30' |
    jq -er --argjson index "${index}" '
      [.[].tag_name | select(test("^nightly-[0-9]{8}$"))][$index]
    '
}

latest_nightly_tag() {
  nightly_tag_at_index 0
}

previous_nightly_tag() {
  nightly_tag_at_index 1
}

latest_stable_tag() {
  curl -fsSL https://api.github.com/repos/ROCKNIX/distribution/releases/latest |
    jq -er '.tag_name'
}

asset_name_from_url() {
  local url="$1"
  url="${url%%\?*}"
  basename "${url}"
}

if [[ -z "${image_url}" ]]; then
  case "${source_channel}" in
    nightly)
      if [[ "${release}" == "latest" ]]; then
        release="$(latest_nightly_tag)"
      elif [[ "${release}" == "previous" || "${release}" == "latest-1" ]]; then
        release="$(previous_nightly_tag)"
      fi
      [[ "${release}" == nightly-* ]] || die "nightly release must look like nightly-YYYYMMDD: ${release}"
      release_date="${release#nightly-}"
      image_regex="^ROCKNIX-${platform}[.]aarch64-${release_date}[.]img[.]gz$"
      image_url="$(github_asset_url ROCKNIX/distribution-nightly "${release}" "${image_regex}")"
      ;;
    stable)
      if [[ "${release}" == "latest" ]]; then
        release="$(latest_stable_tag)"
      fi
      release_date="${release}"
      image_regex="^ROCKNIX-${platform}[.]aarch64-${release_date}[.]img[.]gz$"
      image_url="$(github_asset_url ROCKNIX/distribution "${release}" "${image_regex}")"
      ;;
    *)
      die "--source must be nightly or stable"
      ;;
  esac
fi

[[ -n "${image_url}" ]] || die "unable to resolve ROCKNIX image URL"
image_name="$(asset_name_from_url "${image_url}")"
case "${image_name}" in
  *.img.gz|*.img) ;;
  *) die "expected a .img.gz or .img URL, got: ${image_url}" ;;
esac

if [[ -z "${sha256_url}" && "${image_url}" == *.img.gz ]]; then
  sha256_url="${image_url}.sha256"
fi

install -d "${cache_abs}"
downloaded="${cache_abs}/${image_name}"
log "downloading ROCKNIX kernel source image ${image_name}"
curl -fL --continue-at - -o "${downloaded}" "${image_url}"

image_sha256=""
if [[ -n "${sha256_url}" ]]; then
  sha_file="${downloaded}.sha256"
  if curl -fL -o "${sha_file}" "${sha256_url}"; then
    log "verifying ${image_name}"
    (cd "${cache_abs}" && sha256sum -c "$(basename "${sha_file}")")
    image_sha256="$(awk '{print $1; exit}' "${sha_file}")"
  else
    [[ "${allow_unverified}" == 1 ]] || die "sha256 asset was not available: ${sha256_url}"
    warn "sha256 asset was not available: ${sha256_url}; continuing unverified because --allow-unverified was set"
  fi
fi
if [[ -z "${image_sha256}" ]]; then
  [[ "${allow_unverified}" == 1 ]] || die "ROCKNIX image has no sha256 verification; pass --sha256-url or --allow-unverified"
  warn "ROCKNIX image is being imported without sha256 verification"
fi

case "${downloaded}" in
  *.img.gz)
    image="${downloaded%.gz}"
    if [[ ! -f "${image}" || "${downloaded}" -nt "${image}" ]]; then
      log "decompressing ${image_name}"
      gzip -cd "${downloaded}" > "${image}.tmp"
      mv -f "${image}.tmp" "${image}"
    fi
    ;;
  *.img)
    image="${downloaded}"
    ;;
esac

mounts=()
work_tree=""
loop_device=""
cleanup() {
  if [[ "${keep_mounted}" -eq 1 ]]; then
    if [[ -n "${loop_device}" ]]; then
      warn "leaving ROCKNIX image mounted on ${loop_device}"
    fi
    return 0
  fi
  local mountpoint
  for mountpoint in "${mounts[@]}"; do
    umount "${mountpoint}" >/dev/null 2>&1 || true
  done
  [[ -n "${loop_device}" ]] && losetup -d "${loop_device}" >/dev/null 2>&1 || true
  for mountpoint in "${mounts[@]}"; do
    rmdir "${mountpoint}" >/dev/null 2>&1 || true
  done
  [[ -n "${work_tree}" ]] && rm -rf "${work_tree}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "attaching ${image} read-only"
loop_device="$(losetup --find --partscan --show --read-only "${image}")"
partitions=()
for _ in {1..20}; do
  mapfile -t partitions < <(lsblk -nrpo NAME,TYPE "${loop_device}" | awk '$2 == "part" {print $1}')
  [[ "${#partitions[@]}" -ge 2 ]] && break
  sleep 0.25
done
[[ "${#partitions[@]}" -ge 2 ]] || die "unable to find boot/root partitions in ${image}"

boot_part="${partitions[0]}"
for part in "${partitions[@]}"; do
  mountpoint="$(mktemp -d /tmp/thorch-rocknix-part.XXXXXX)"
  if mount -o ro "${part}" "${mountpoint}" >/dev/null 2>&1; then
    mounts+=("${mountpoint}")
  else
    rmdir "${mountpoint}" >/dev/null 2>&1 || true
  fi
done
[[ "${#mounts[@]}" -gt 0 ]] || die "unable to mount partitions in ${image}"

find_mounted_boot_dir() {
  local mountpoint
  for mountpoint in "${mounts[@]}"; do
    if [[ -f "${mountpoint}/Image" || -f "${mountpoint}/KERNEL" ]]; then
      printf '%s\n' "${mountpoint}"
      return 0
    fi
  done
  return 1
}

find_mounted_root_dir() {
  local mountpoint
  for mountpoint in "${mounts[@]}"; do
    if [[ -d "${mountpoint}/usr/lib/modules" || -d "${mountpoint}/lib/modules" ]]; then
      printf '%s\n' "${mountpoint}"
      return 0
    fi
  done
  return 1
}

extract_android_boot_kernel() {
  local kernel_image="$1" image_out="$2"
  python3 - "${kernel_image}" "${image_out}" <<'PY'
import pathlib
import struct
import sys
import zlib

boot_path = pathlib.Path(sys.argv[1])
image_out = pathlib.Path(sys.argv[2])
data = boot_path.read_bytes()
if data[:8] != b"ANDROID!":
    raise SystemExit(f"{boot_path} is not an Android boot image")

kernel_size = struct.unpack_from("<I", data, 8)[0]
page_size = struct.unpack_from("<I", data, 36)[0]
kernel_offset = page_size
kernel = data[kernel_offset:kernel_offset + kernel_size]
if len(kernel) != kernel_size:
    raise SystemExit("truncated Android boot kernel payload")

dtb_magic = b"\xd0\r\xfe\xed"
try:
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    image = decompressor.decompress(kernel) + decompressor.flush()
    trailer = decompressor.unused_data
except zlib.error:
    dtb_at = kernel.find(dtb_magic)
    if dtb_at < 0:
        raise
    image = kernel[:dtb_at]
    trailer = kernel[dtb_at:]

dtbs = []
pos = 0
while True:
    dtb_at = trailer.find(dtb_magic, pos)
    if dtb_at < 0:
        break
    if len(trailer) < dtb_at + 8:
        raise SystemExit("appended DTB is truncated")
    dtb_size = struct.unpack_from(">I", trailer, dtb_at + 4)[0]
    if dtb_size < 8 or len(trailer) < dtb_at + dtb_size:
        raise SystemExit("appended DTB is truncated")
    dtb = trailer[dtb_at:dtb_at + dtb_size]
    dtbs.append(dtb)
    pos = dtb_at + dtb_size

if not dtbs:
    raise SystemExit("Android boot kernel payload does not contain an appended DTB")

matches = [
    dtb for dtb in dtbs
    if b"AYN Thor\x00" in dtb and b"ayn,thor\x00" in dtb
]
if not matches:
    raise SystemExit(
        "Android boot kernel payload does not contain an AYN Thor DTB; "
        f"found {len(dtbs)} DTB(s)"
    )
if len(matches) > 1:
    raise SystemExit("Android boot kernel payload contains multiple AYN Thor DTBs")
image_out.parent.mkdir(parents=True, exist_ok=True)
image_out.write_bytes(image)
PY
}

normalize_immutable_rocknix_image() {
  local boot_dir="$1"
  [[ -f "${boot_dir}/KERNEL" && -f "${boot_dir}/SYSTEM" ]] || return 1

  work_tree="$(mktemp -d /tmp/thorch-rocknix-tree.XXXXXX)"
  extract_android_boot_kernel \
    "${boot_dir}/KERNEL" \
    "${work_tree}/boot/Image"
  install -Dm644 "${boot_dir}/KERNEL" "${work_tree}/boot/KERNEL"

  log "extracting ROCKNIX kernel modules and runtime files from SYSTEM"
  unsquashfs -no-progress -f -d "${work_tree}/system" \
    "${boot_dir}/SYSTEM" \
    usr/lib/kernel-overlays/base/lib/modules \
    usr/lib/kernel-overlays/base/lib/firmware/qcom/a740_sqe.fw \
    usr/lib/kernel-overlays/base/lib/firmware/qcom/gmu_gen70200.bin \
    usr/lib/kernel-overlays/base/lib/firmware/qcom/sm8550/a740_zap.mbn \
    usr/lib/libvulkan_freedreno.so \
    usr/lib/libdisplay-info.so.0.2.0 \
    usr/lib/libdisplay-info.so.2 \
    'usr/lib/libfmt.so.11*' \
    usr/bin/FEX* \
    usr/lib/fex-emu \
    'usr/lib/binfmt.d/FEX-*.conf' \
    usr/config/fex-emu \
    usr/share/fex-emu \
    usr/share/fex-emu/libvulkan_freedreno.so \
    'usr/share/vulkan/icd.d/freedreno_icd*.json' >/dev/null
  modules_src="${work_tree}/system/usr/lib/kernel-overlays/base/lib/modules"
  [[ -d "${modules_src}" ]] || die "ROCKNIX SYSTEM did not contain kernel modules"
  install -d "${work_tree}/usr/lib"
  mv "${modules_src}" "${work_tree}/usr/lib/modules"
  if [[ -d "${work_tree}/system/usr/lib/kernel-overlays/base/lib/firmware" ]]; then
    install -d "${work_tree}/usr/lib/firmware"
    cp -a "${work_tree}/system/usr/lib/kernel-overlays/base/lib/firmware/." \
      "${work_tree}/usr/lib/firmware/"
  fi
  for firmware in \
    qcom/a740_sqe.fw \
    qcom/gmu_gen70200.bin \
    qcom/sm8550/a740_zap.mbn; do
    [[ -f "${work_tree}/usr/lib/firmware/${firmware}" ]] || die "ROCKNIX SYSTEM did not contain firmware ${firmware}"
  done

  [[ -f "${work_tree}/system/usr/lib/libvulkan_freedreno.so" ]] || die "ROCKNIX SYSTEM did not contain libvulkan_freedreno.so"
  install -Dm755 "${work_tree}/system/usr/lib/libvulkan_freedreno.so" \
    "${work_tree}/usr/lib/libvulkan_freedreno.so"
  install -Dm755 "${work_tree}/system/usr/lib/libdisplay-info.so.0.2.0" \
    "${work_tree}/usr/lib/libdisplay-info.so.0.2.0"
  ln -sfn libdisplay-info.so.0.2.0 "${work_tree}/usr/lib/libdisplay-info.so.2"
  install -Dm755 "${work_tree}/system/usr/share/fex-emu/libvulkan_freedreno.so" \
    "${work_tree}/usr/share/fex-emu/libvulkan_freedreno.so"
  freedreno_icd="$(find "${work_tree}/system/usr/share/vulkan/icd.d" -maxdepth 1 -type f -name 'freedreno_icd*.json' | sort | head -n1)"
  [[ -n "${freedreno_icd}" ]] || die "ROCKNIX SYSTEM did not contain a Freedreno Vulkan ICD"
  install -Dm644 "${freedreno_icd}" "${work_tree}/usr/share/vulkan/icd.d/freedreno_icd.json"

  printf '%s\n' "${work_tree}"
}

boot_mount="$(find_mounted_boot_dir || true)"
root_mount="$(find_mounted_root_dir || true)"
[[ -n "${boot_mount}" ]] || die "unable to find ROCKNIX boot files in ${image}"

import_boot="${boot_mount}"
import_root="${root_mount:-${boot_mount}}"
if [[ -f "${boot_mount}/KERNEL" && -f "${boot_mount}/SYSTEM" && ! -f "${boot_mount}/Image" ]]; then
  normalized_tree="$(normalize_immutable_rocknix_image "${boot_mount}")"
  import_boot="${normalized_tree}"
  import_root="${normalized_tree}"
fi

ref_label="${release:-${image_name}}"
log "importing ROCKNIX kernel artifacts from ${image_name}"
"${script_dir}/import-rocknix-kernel.sh" \
  --boot-dir "${import_boot}" \
  --root-dir "${import_root}" \
  --dest "${dest_abs}" \
  --ref "${ref_label}"

log "importing ROCKNIX runtime artifacts from ${image_name}"
"${script_dir}/import-rocknix-runtime.sh" \
  --root-dir "${import_root}" \
  --dest "${runtime_dest_abs}" \
  --ref "${ref_label}"

runtime_provenance="${runtime_dest_abs}/PROVENANCE"
if [[ -f "${runtime_provenance}" ]]; then
  runtime_provenance_tmp="$(mktemp)"
  grep -Ev '^SOURCE_(ROOT_DIR|RUNTIME_ROOT|FEX|FEX_ROOTFS_FETCHER|FEX_HOST_THUNKS|FEX_GUEST_THUNKS)=' "${runtime_provenance}" > "${runtime_provenance_tmp}" || true
  mv -f "${runtime_provenance_tmp}" "${runtime_provenance}"
  chmod 0644 "${runtime_provenance}"
fi

provenance="${dest_abs}/PROVENANCE"
provenance_tmp="$(mktemp)"
grep -Ev '^SOURCE_(BOOT|ROOT)_DIR=|^SOURCE_(IMAGE|DTB|MODULES|VULKAN_FREEDRENO|DISPLAY_INFO|FEX_VULKAN_FREEDRENO|FREEDRENO_ICD)=' "${provenance}" > "${provenance_tmp}" || true
mv -f "${provenance_tmp}" "${provenance}"
{
  printf 'ROCKNIX_KERNEL_SOURCE=%s\n' "${source_channel}"
  printf 'ROCKNIX_KERNEL_PLATFORM=%s\n' "${platform}"
  printf 'SOURCE_ROCKNIX_IMAGE_URL=%s\n' "${image_url}"
  printf 'SOURCE_ROCKNIX_IMAGE_FILE=%s\n' "${downloaded}"
  printf 'SOURCE_ROCKNIX_BOOT_PAYLOAD=/KERNEL\n'
  printf 'SOURCE_ROCKNIX_SYSTEM_PAYLOAD=/SYSTEM\n'
  printf 'SOURCE_ROCKNIX_FIRMWARE_FILES=/usr/lib/firmware/qcom/a740_sqe.fw /usr/lib/firmware/qcom/gmu_gen70200.bin /usr/lib/firmware/qcom/sm8550/a740_zap.mbn\n'
  printf 'SOURCE_ROCKNIX_RUNTIME_FILES=/usr/lib/libvulkan_freedreno.so /usr/lib/libdisplay-info.so.0.2.0 /usr/share/fex-emu/libvulkan_freedreno.so /usr/share/vulkan/icd.d/freedreno_icd.json\n'
  [[ -z "${image_sha256}" ]] || printf 'SOURCE_ROCKNIX_IMAGE_SHA256=%s\n' "${image_sha256}"
} >> "${dest_abs}/PROVENANCE"

if [[ -f "${runtime_provenance}" ]]; then
  {
    printf 'ROCKNIX_KERNEL_SOURCE=%s\n' "${source_channel}"
    printf 'ROCKNIX_KERNEL_PLATFORM=%s\n' "${platform}"
    printf 'SOURCE_ROCKNIX_IMAGE_URL=%s\n' "${image_url}"
    printf 'SOURCE_ROCKNIX_IMAGE_FILE=%s\n' "${downloaded}"
    printf 'SOURCE_ROCKNIX_SYSTEM_PAYLOAD=/SYSTEM\n'
    printf 'SOURCE_ROCKNIX_RUNTIME_FILES=/usr/bin/FEX* /usr/lib/fex-emu /usr/share/fex-emu /usr/lib/binfmt.d/FEX-*.conf /usr/lib/libfmt.so.11*\n'
    [[ -z "${image_sha256}" ]] || printf 'SOURCE_ROCKNIX_IMAGE_SHA256=%s\n' "${image_sha256}"
  } >> "${runtime_provenance}"
  chmod 0644 "${runtime_provenance}"
fi

find "${dest_abs}" -type d -exec chmod 0755 {} +
find "${dest_abs}" -type f -exec chmod 0644 {} +

log "ROCKNIX kernel artifacts ready in ${dest_abs}"
log "ROCKNIX runtime artifacts ready in ${runtime_dest_abs}"
