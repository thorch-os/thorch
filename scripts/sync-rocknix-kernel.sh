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
available, mounts it read-only, imports firmware/runtime/template artifacts, and
then source-builds the Thorch Thor kernel with BinderFS support enabled.

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
  --mount-probe-image <path>  Attach and mount a local partitioned image, emit
                              diagnostics, then exit. Used by Linux CI.
  --skip-thorch-kernel-build  Keep the imported ROCKNIX kernel payload. This is
                              only for local diagnostics; Waydroid will fail.
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
build_thorch_kernel="${THORCH_KERNEL_SOURCE_BUILD:-1}"
mount_probe_image=""

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
    --mount-probe-image)
      mount_probe_image="${2:-}"
      [[ -n "${mount_probe_image}" ]] || die "--mount-probe-image requires a value"
      shift 2
      ;;
    --skip-thorch-kernel-build)
      build_thorch_kernel=0
      shift
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
require_cmd blkid curl file findmnt gzip jq losetup lsblk mknod mount python3 readlink sha256sum sfdisk stat umount unsquashfs

if [[ -n "${mount_probe_image}" ]]; then
  mount_probe_image="$(readlink -f "${mount_probe_image}")"
  [[ -f "${mount_probe_image}" ]] || die "mount probe image is not a regular file: ${mount_probe_image}"
  image_url="file://${mount_probe_image}"
  sha256_url=""
  allow_unverified=1
fi

root="$(repo_root)"
boot_tool="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py"
[[ -f "${boot_tool}" ]] || die "missing canonical boot image tool: ${boot_tool}"
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
created_device_nodes=()
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
  local device_node
  for device_node in "${created_device_nodes[@]}"; do
    rm -f "${device_node}" >/dev/null 2>&1 || true
  done
  for mountpoint in "${mounts[@]}"; do
    rmdir "${mountpoint}" >/dev/null 2>&1 || true
  done
  [[ -n "${work_tree}" ]] && rm -rf "${work_tree}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ensure_loop_partition_device_nodes() {
  local name type major_minor major minor

  while read -r name type major_minor; do
    [[ "${type}" == "part" ]] || continue
    [[ "${name}" == "${loop_device}"p* ]] || \
      die "unexpected partition path reported for ${loop_device}: ${name}"
    [[ -b "${name}" ]] && continue
    major="${major_minor%%:*}"
    minor="${major_minor#*:}"
    [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || \
      die "invalid major/minor for ${name}: ${major_minor}"
    log "creating missing loop partition node path=${name} major-minor=${major_minor}"
    mknod -m 0600 "${name}" b "${major}" "${minor}"
    created_device_nodes+=("${name}")
  done < <(lsblk -nrpo NAME,TYPE,MAJ:MIN "${loop_device}")
}

log "attaching ${image} read-only"
loop_device="$(losetup --find --partscan --show --read-only "${image}")"
partitions=()
for _ in {1..20}; do
  mapfile -t partitions < <(lsblk -nrpo NAME,TYPE "${loop_device}" | awk '$2 == "part" {print $1}')
  [[ "${#partitions[@]}" -ge 2 ]] && break
  sleep 0.25
done
if [[ "${#partitions[@]}" -lt 2 ]]; then
  log "ROCKNIX block topology after partition discovery failure"
  lsblk --output NAME,MAJ:MIN,TYPE,SIZE,RO,FSTYPE,LABEL,UUID,PARTTYPE,MOUNTPOINTS "${loop_device}" >&2 || \
    lsblk -f "${loop_device}" >&2 || true
  stat -Lc 'device-node path=%n type=%F mode=%A major-minor-hex=%t:%T inode=%i' "${loop_device}" >&2 || true
  die "unable to find boot/root partitions in ${image}"
fi
ensure_loop_partition_device_nodes

log "ROCKNIX block topology"
lsblk --output NAME,MAJ:MIN,TYPE,SIZE,RO,FSTYPE,LABEL,UUID,PARTTYPE,MOUNTPOINTS "${loop_device}" >&2 || \
  lsblk -f "${loop_device}" >&2 || true
for part in "${loop_device}" "${partitions[@]}"; do
  stat -Lc 'device-node path=%n type=%F mode=%A major-minor-hex=%t:%T inode=%i' "${part}" >&2 || true
  log "blkid path=${part}"
  blkid -o full "${part}" >&2 || true
  log "filesystem probe path=${part}"
  file -Ls "${part}" >&2 || true
done

for part in "${partitions[@]}"; do
  mountpoint="$(mktemp -d /tmp/thorch-rocknix-part.XXXXXX)"
  log "mount attempt source=${part} target=${mountpoint} options=ro"
  if mount -v -o ro "${part}" "${mountpoint}"; then
    mounts+=("${mountpoint}")
    mount_details="$(findmnt --noheadings --output SOURCE,FSTYPE,OPTIONS --target "${mountpoint}")"
    log "mounted ${mount_details} target=${mountpoint}"
  else
    warn "mount failed source=${part} target=${mountpoint} options=ro"
    rmdir "${mountpoint}" >/dev/null 2>&1 || true
  fi
done
[[ "${#mounts[@]}" -gt 0 ]] || die "unable to mount partitions in ${image}"

if [[ -n "${mount_probe_image}" ]]; then
  log "partitioned image mount probe passed: ${mount_probe_image}"
  exit 0
fi

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
  python3 "${boot_tool}" extract-kernel \
    "${kernel_image}" \
    "${image_out}" \
    --require-thor
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
grep -Ev '^SOURCE_(BOOT|ROOT)_DIR=|^SOURCE_(IMAGE|DTB|MODULES|VULKAN_FREEDRENO|DISPLAY_INFO|FEX_VULKAN_FREEDRENO|FREEDRENO_ICD)=|^(THORCH_KERNEL_|SOURCE_THORCH_KERNEL_|WAYDROID_KERNEL_)' "${provenance}" > "${provenance_tmp}" || true
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

if [[ "${build_thorch_kernel}" != "0" ]]; then
  log "building Thorch Thor kernel with BinderFS support"
  "${script_dir}/build-thorch-kernel.sh" --dest "${dest_abs}"
else
  warn "leaving imported ROCKNIX kernel payload unchanged; Waydroid BinderFS support is not guaranteed"
fi

find "${dest_abs}" -type d -exec chmod 0755 {} +
find "${dest_abs}" -type f -exec chmod 0644 {} +

log "Thorch kernel artifacts ready in ${dest_abs}"
log "ROCKNIX runtime artifacts ready in ${runtime_dest_abs}"
