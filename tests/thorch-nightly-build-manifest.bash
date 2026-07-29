#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${root}/scripts/create-nightly-build-manifest.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

build="${tmpdir}/build"
source_dir="${tmpdir}/rocknix-source"
kernel_dir="${tmpdir}/rocknix-kernel"
pacman_local="${build}/image-rootfs/var/lib/pacman/local"
mkdir -p \
  "${build}/cache" \
  "${source_dir}" \
  "${kernel_dir}" \
  "${pacman_local}/alpha-1.0-1" \
  "${pacman_local}/beta-2.0-3"
printf 'verified rootfs fixture\n' > "${build}/cache/ArchLinuxARM-aarch64-latest.tar.gz"

cat > "${source_dir}/SOURCE_PROVENANCE" <<'EOF'
ROCKNIX_REPO=https://github.com/ROCKNIX/distribution
REQUESTED_REF=next
RESOLVED_REF=0123456789abcdef
SYNCED_AT=2026-07-28T00:00:00Z
EOF
cat > "${kernel_dir}/PROVENANCE" <<'EOF'
ROCKNIX_REF=nightly-20260728
ROCKNIX_KERNEL_SOURCE=nightly
ROCKNIX_KERNEL_PLATFORM=SM8550
SOURCE_ROCKNIX_IMAGE_URL=https://example.invalid/rocknix.img.gz
SOURCE_ROCKNIX_IMAGE_SHA256=abcdef
THORCH_KERNEL_SOURCE=source-built
THORCH_KERNEL_REPO=https://git.kernel.org/example.git
THORCH_KERNEL_REF=v7.1.2
THORCH_KERNEL_RESOLVED_REF=fedcba
THORCH_KERNEL_RELEASE=7.1.2-thorch1
WAYDROID_KERNEL_BINDERFS=enabled
THORCH_KERNEL_BUILT_AT=2026-07-28T00:00:00Z
EOF
cat > "${pacman_local}/alpha-1.0-1/desc" <<'EOF'
%NAME%
alpha

%VERSION%
1.0-1
EOF
cat > "${pacman_local}/beta-2.0-3/desc" <<'EOF'
%NAME%
beta

%VERSION%
2.0-3
EOF

generate() {
  GITHUB_SHA=1111111111111111111111111111111111111111 \
  THORCH_DOCKER_IMAGE=ghcr.io/thorch-os/thorch-build@sha256:fixture \
  THORCH_BUILD_DIR="${build}" \
  THORCH_ROCKNIX_DIR="${source_dir}" \
  THORCH_ROCKNIX_KERNEL_DIR="${kernel_dir}" \
  ROCKNIX_REF=next \
  ROCKNIX_KERNEL_SOURCE=nightly \
  ROCKNIX_KERNEL_RELEASE=latest \
  THORCH_IMAGE_SIZE=auto \
  THORCH_ROOT_FSTYPE=btrfs \
    "${generator}" "$1"
}

generate "${tmpdir}/first"
sed -i.bak 's/2026-07-28T00:00:00Z/2026-07-29T00:00:00Z/g' \
  "${source_dir}/SOURCE_PROVENANCE" "${kernel_dir}/PROVENANCE"
generate "${tmpdir}/second"
cmp -s "${tmpdir}/first" "${tmpdir}/second" ||
  fail "volatile provenance timestamps changed the build manifest"

sed -i.bak 's/2.0-3/2.0-4/' "${pacman_local}/beta-2.0-3/desc"
generate "${tmpdir}/third"
! cmp -s "${tmpdir}/second" "${tmpdir}/third" ||
  fail "package version change did not change the build manifest"

grep -q '^ALARM_ROOTFS_SHA256=[0-9a-f]\{64\}$' "${tmpdir}/first" ||
  fail "build manifest does not record the verified rootfs hash"
grep -q '^RESOLVED_REF=0123456789abcdef$' "${tmpdir}/first" ||
  fail "build manifest does not record resolved ROCKNIX source provenance"

printf 'thorch nightly build manifest checks passed\n'
