#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s <output-manifest>\n' "${0##*/}" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=../config/thorch.conf
source "${root}/config/thorch.conf"

output="$1"
rootfs="${THORCH_BUILD_DIR}/image-rootfs"
rootfs_tar="${THORCH_BUILD_DIR}/cache/ArchLinuxARM-aarch64-latest.tar.gz"
source_provenance="${THORCH_ROCKNIX_DIR}/SOURCE_PROVENANCE"
kernel_provenance="${THORCH_ROCKNIX_KERNEL_DIR}/PROVENANCE"

case "${rootfs}" in
  /*) ;;
  *) rootfs="${root}/${rootfs}" ;;
esac
case "${rootfs_tar}" in
  /*) ;;
  *) rootfs_tar="${root}/${rootfs_tar}" ;;
esac
case "${source_provenance}" in
  /*) ;;
  *) source_provenance="${root}/${source_provenance}" ;;
esac
case "${kernel_provenance}" in
  /*) ;;
  *) kernel_provenance="${root}/${kernel_provenance}" ;;
esac

[[ -d "${rootfs}/var/lib/pacman/local" ]] || {
  printf 'nightly image rootfs package database is missing: %s\n' "${rootfs}" >&2
  exit 1
}
[[ -f "${rootfs_tar}" ]] || {
  printf 'verified Arch Linux ARM rootfs is missing: %s\n' "${rootfs_tar}" >&2
  exit 1
}
[[ -f "${source_provenance}" ]] || {
  printf 'ROCKNIX source provenance is missing: %s\n' "${source_provenance}" >&2
  exit 1
}
[[ -f "${kernel_provenance}" ]] || {
  printf 'kernel provenance is missing: %s\n' "${kernel_provenance}" >&2
  exit 1
}

mkdir -p "$(dirname "${output}")"
tmp="$(mktemp "${output}.tmp.XXXXXX")"
cleanup() {
  rm -f "${tmp}"
}
trap cleanup EXIT

commit="${GITHUB_SHA:-$(git -C "${root}" rev-parse HEAD)}"
builder="${THORCH_DOCKER_IMAGE:-unknown}"
alarm_sha256="$(sha256sum "${rootfs_tar}" | awk '{print $1}')"

{
  printf 'THORCH_NIGHTLY_BUILD_MANIFEST=1\n'
  printf 'THORCH_COMMIT=%s\n' "${commit}"
  printf 'THORCH_DOCKER_IMAGE=%s\n' "${builder}"
  printf 'ROCKNIX_REF_REQUEST=%s\n' "${ROCKNIX_REF}"
  printf 'ROCKNIX_KERNEL_SOURCE_REQUEST=%s\n' "${ROCKNIX_KERNEL_SOURCE}"
  printf 'ROCKNIX_KERNEL_RELEASE_REQUEST=%s\n' "${ROCKNIX_KERNEL_RELEASE}"
  printf 'THORCH_IMAGE_SIZE=%s\n' "${THORCH_IMAGE_SIZE}"
  printf 'THORCH_ROOT_FSTYPE=%s\n' "${THORCH_ROOT_FSTYPE}"
  printf 'ALARM_ROOTFS_SHA256=%s\n' "${alarm_sha256}"

  printf '\n[rocknix-source]\n'
  grep -E '^(ROCKNIX_REPO|REQUESTED_REF|RESOLVED_REF)=' "${source_provenance}" |
    LC_ALL=C sort

  printf '\n[kernel]\n'
  grep -E '^(ROCKNIX_REF|ROCKNIX_KERNEL_(SOURCE|PLATFORM)|SOURCE_ROCKNIX_IMAGE_(URL|SHA256)|THORCH_KERNEL_(SOURCE|REPO|REF|RESOLVED_REF|RELEASE)|WAYDROID_KERNEL_BINDERFS)=' \
    "${kernel_provenance}" |
    LC_ALL=C sort

  printf '\n[packages]\n'
  for desc in "${rootfs}"/var/lib/pacman/local/*/desc; do
    [[ -f "${desc}" ]] || continue
    awk '
      $0 == "%NAME%" { getline; name = $0 }
      $0 == "%VERSION%" { getline; version = $0 }
      END {
        if (name == "" || version == "") {
          exit 1
        }
        printf "%s=%s\n", name, version
      }
    ' "${desc}"
  done | LC_ALL=C sort
} > "${tmp}"

mv -f "${tmp}" "${output}"
trap - EXIT
