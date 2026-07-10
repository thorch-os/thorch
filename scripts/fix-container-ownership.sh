#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 HOST_UID HOST_GID [WORKSPACE]" >&2
  exit 2
fi

host_uid="$1"
host_gid="$2"
workspace="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

[[ "${host_uid}" =~ ^[0-9]+$ ]] || {
  echo "HOST_UID must be numeric" >&2
  exit 2
}
[[ "${host_gid}" =~ ^[0-9]+$ ]] || {
  echo "HOST_GID must be numeric" >&2
  exit 2
}
[[ -d "${workspace}" ]] || {
  echo "workspace does not exist: ${workspace}" >&2
  exit 2
}

owner="${host_uid}:${host_gid}"

# image-rootfs and pkg-root are chroots. Their internal ownership is image
# metadata, so changing it to the host user corrupts both generated images and
# subsequent --reuse-rootfs builds.
if [[ -d "${workspace}/build" ]]; then
  chown "${owner}" -- "${workspace}/build"
  while IFS= read -r -d '' path; do
    chown -R "${owner}" -- "${path}"
  done < <(
    find "${workspace}/build" -mindepth 1 -maxdepth 1 \
      ! -name image-rootfs \
      ! -name pkg-root \
      -print0
  )
fi

for path in "${workspace}/output" "${workspace}/vendor"; do
  [[ -e "${path}" ]] || continue
  chown -R "${owner}" -- "${path}"
done
