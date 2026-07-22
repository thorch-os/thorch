#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="${root}/scripts/check-thorch-image.sh"
work="$(mktemp -d)"

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for cmd in dd mkfs.vfat sfdisk truncate; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "missing test command: ${cmd}"
done

make_boot_filesystem() {
  local output="$1"
  truncate -s 64M "${output}"
  mkfs.vfat -F 32 -n ROCKNIX "${output}" >/dev/null
}

make_rocknix_layout() {
  local output="$1" boot="$2"
  truncate -s 256M "${output}"
  sfdisk "${output}" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=32768, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=system, attrs=LegacyBIOSBootable
start=163840, size=360414, type=linux, name=storage
EOF
  dd if="${boot}" of="${output}" bs=512 seek=32768 conv=notrunc status=none
}

make_esp_layout() {
  local output="$1" boot="$2"
  truncate -s 256M "${output}"
  sfdisk "${output}" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=131072, type=uefi
start=133120, size=391134, type=linux
EOF
  dd if="${boot}" of="${output}" bs=512 seek=2048 conv=notrunc status=none
}

assert_output() {
  local output="$1" expected="$2"
  grep -Fq "${expected}" <<<"${output}" || fail "missing validator result: ${expected}"
}

boot="${work}/boot.vfat"
rocknix_image="${work}/rocknix-layout.img"
esp_image="${work}/esp-layout.img"
make_boot_filesystem "${boot}"
make_rocknix_layout "${rocknix_image}" "${boot}"
make_esp_layout "${esp_image}" "${boot}"

# The synthetic images intentionally omit /KERNEL. Inspect the individual
# layout results rather than expecting whole-image validation to pass.
rocknix_output="$(${validator} "${rocknix_image}" 2>&1 || true)"
assert_output "${rocknix_output}" "ok: disk uses a GPT with exactly two partitions"
assert_output "${rocknix_output}" "ok: boot partition starts at the ROCKNIX 16 MiB offset"
assert_output "${rocknix_output}" "ok: boot partition uses the ROCKNIX Basic Data type"
assert_output "${rocknix_output}" "ok: boot partition is named system"
assert_output "${rocknix_output}" "ok: boot partition carries the legacy boot attribute"
assert_output "${rocknix_output}" "ok: root partition uses the Linux type and storage name"

esp_output="$(${validator} "${esp_image}" 2>&1 || true)"
assert_output "${esp_output}" "FAIL: boot partition starts at the ROCKNIX 16 MiB offset"
assert_output "${esp_output}" "FAIL: boot partition uses the ROCKNIX Basic Data type"
assert_output "${esp_output}" "FAIL: boot partition is named system"
assert_output "${esp_output}" "FAIL: boot partition carries the legacy boot attribute"
assert_output "${esp_output}" "FAIL: root partition uses the Linux type and storage name"

printf 'thorch ROCKNIX boot layout checks passed\n'
