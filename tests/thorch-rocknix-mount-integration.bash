#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="${root}/scripts/sync-rocknix-kernel.sh"
required="${THORCH_REQUIRE_MOUNT_INTEGRATION:-0}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

skip_or_fail() {
  if [[ "${required}" == "1" ]]; then
    fail "$*"
  fi
  printf 'SKIP: %s\n' "$*"
  exit 0
}

[[ "$(uname -s)" == "Linux" ]] || skip_or_fail "partition mount integration requires Linux"
[[ "${EUID}" -eq 0 ]] || skip_or_fail "partition mount integration requires root"

commands=(
  blkid curl file findmnt gzip jq losetup lsblk mkfs.ext4 mkfs.vfat mknod
  mount python3 readlink sha256sum sfdisk stat umount unsquashfs
)
for command in "${commands[@]}"; do
  command -v "${command}" >/dev/null 2>&1 || \
    skip_or_fail "partition mount integration is missing ${command}"
done

if ! losetup --find >/dev/null 2>&1; then
  skip_or_fail "partition mount integration has no usable loop device"
fi

tmp="$(mktemp -d)"
fixture_loop=""
fixture_created_device_nodes=()
cleanup() {
  if [[ -n "${fixture_loop}" ]]; then
    losetup -d "${fixture_loop}" >/dev/null 2>&1 || true
  fi
  local device_node
  for device_node in "${fixture_created_device_nodes[@]}"; do
    rm -f "${device_node}" >/dev/null 2>&1 || true
  done
  rm -rf "${tmp}"
}
trap cleanup EXIT

create_partitioned_image() {
  local image="$1" format_filesystems="$2"
  local name type major_minor major minor

  truncate -s 64M "${image}"
  sfdisk "${image}" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=16384, type=uefi
start=18432, size=65536, type=linux
EOF

  fixture_loop="$(losetup --find --partscan --show "${image}")"
  for _ in {1..20}; do
    [[ "$(lsblk -nrpo NAME,TYPE "${fixture_loop}" | awk '$2 == "part" {count++} END {print count + 0}')" -ge 2 ]] && break
    sleep 0.1
  done
  [[ "$(lsblk -nrpo NAME,TYPE "${fixture_loop}" | awk '$2 == "part" {count++} END {print count + 0}')" -ge 2 ]] || \
    fail "fixture partition metadata did not appear for ${fixture_loop}"

  # A container has no udev daemon to materialize new loop partition nodes.
  # Create them for fixture formatting, then remove them so the production
  # probe must exercise its own missing-node handling.
  while read -r name type major_minor; do
    [[ "${type}" == "part" ]] || continue
    [[ -b "${name}" ]] && continue
    major="${major_minor%%:*}"
    minor="${major_minor#*:}"
    mknod -m 0600 "${name}" b "${major}" "${minor}"
    fixture_created_device_nodes+=("${name}")
  done < <(lsblk -nrpo NAME,TYPE,MAJ:MIN "${fixture_loop}")
  [[ -b "${fixture_loop}p1" && -b "${fixture_loop}p2" ]] || \
    fail "fixture partition device nodes could not be created for ${fixture_loop}"

  if [[ "${format_filesystems}" == "1" ]]; then
    mkfs.vfat -n ROCKNIX "${fixture_loop}p1" >/dev/null
    mkfs.ext4 -F -L THORCH_ROOT "${fixture_loop}p2" >/dev/null 2>&1
  fi

  losetup -d "${fixture_loop}"
  for name in "${fixture_created_device_nodes[@]}"; do
    rm -f "${name}"
  done
  fixture_created_device_nodes=()
  fixture_loop=""
}

valid_image="${tmp}/valid-partitioned.img"
create_partitioned_image "${valid_image}" 1

if ! valid_output="$(
  THORCH_BUILD_DIR="${tmp}/valid-build" \
    "${probe}" --mount-probe-image "${valid_image}" 2>&1
)"; then
  printf '%s\n' "${valid_output}" >&2
  fail "valid partitioned image did not pass the production mount path"
fi
printf '%s\n' "${valid_output}"

grep -q 'ROCKNIX block topology' <<< "${valid_output}" ||
  fail "mount probe did not log lsblk topology"
grep -q 'device-node path=' <<< "${valid_output}" ||
  fail "mount probe did not log device-node stat metadata"
grep -q 'creating missing loop partition node' <<< "${valid_output}" ||
  fail "mount probe did not exercise missing partition-node recovery"
grep -q 'blkid path=' <<< "${valid_output}" ||
  fail "mount probe did not log blkid diagnostics"
grep -q 'filesystem probe path=' <<< "${valid_output}" ||
  fail "mount probe did not log filesystem probes"
grep -q 'options=ro' <<< "${valid_output}" ||
  fail "mount probe did not log requested mount options"
grep -Eq 'mounted .*vfat.* target=' <<< "${valid_output}" ||
  fail "mount probe did not report the mounted FAT filesystem"
grep -Eq 'mounted .*ext4.* target=' <<< "${valid_output}" ||
  fail "mount probe did not report the mounted ext4 filesystem"
grep -q 'partitioned image mount probe passed' <<< "${valid_output}" ||
  fail "mount probe did not report success"

invalid_image="${tmp}/invalid-partitioned.img"
create_partitioned_image "${invalid_image}" 0

set +e
invalid_output="$(
  THORCH_BUILD_DIR="${tmp}/invalid-build" \
    "${probe}" --mount-probe-image "${invalid_image}" 2>&1
)"
invalid_status="$?"
set -e
printf '%s\n' "${invalid_output}"

[[ "${invalid_status}" -ne 0 ]] || fail "unformatted partitions unexpectedly mounted"
grep -q '^mount:' <<< "${invalid_output}" ||
  fail "failed mount did not preserve mount(8) stderr"
grep -q 'mount failed source=' <<< "${invalid_output}" ||
  fail "failed mount did not identify its source and options"
grep -q 'unable to mount partitions' <<< "${invalid_output}" ||
  fail "failed mount did not retain its terminal error"

printf 'ROCKNIX partition mount integration checks passed\n'
