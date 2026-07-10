#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
boot_check="${root}/packages/thorch-bsp/payload/usr/bin/thorch-check-boot"
work="$(mktemp -d)"
uuid=11111111-2222-3333-4444-555555555555

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for cmd in dtc gzip mkbootimg python3 strings; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "missing test command: ${cmd}"
done

install -d "${work}/py/gki"
: > "${work}/py/gki/__init__.py"
printf 'def generate_gki_certificate(*args, **kwargs):\n    return None\n' \
  > "${work}/py/gki/generate_gki_certificate.py"

make_boot() {
  local kernel="$1" ramdisk="$2" output="$3"
  PYTHONPATH="${work}/py" mkbootimg \
    --header_version 0 \
    --pagesize 2048 \
    --kernel "${kernel}" \
    --ramdisk "${ramdisk}" \
    --cmdline "root=UUID=${uuid} rootfstype=btrfs fbcon=rotate:1 allow_mismatched_32bit_el0" \
    -o "${output}"
}

cat > "${work}/thor.dts" <<'DTS'
/dts-v1/;
/ {
    model = "AYN Thor";
    compatible = "ayn,thor", "qcom,qcs8550", "qcom,sm8550";
    test_node: test-node {};
};
DTS
dtc -q -@ -I dts -O dtb -o "${work}/thor.dtb" "${work}/thor.dts"
dtc -q -I dts -O dtb -o "${work}/thor-no-symbols.dtb" "${work}/thor.dts"

cat > "${work}/aim300.dts" <<'DTS'
/dts-v1/;
/ {
    model = "Qualcomm Technologies, Inc. QCS8550 AIM300 AIOT";
    compatible = "qcom,qcs8550-aim300-aiot", "qcom,qcs8550", "qcom,sm8550";
    test_node: test-node {};
};
DTS
dtc -q -@ -I dts -O dtb -o "${work}/aim300.dtb" "${work}/aim300.dts"

printf 'synthetic arm64 kernel payload\n' > "${work}/Image"
printf 'synthetic initramfs\n' > "${work}/initramfs"
gzip -n -c "${work}/Image" > "${work}/Image.gz"

cp "${work}/Image.gz" "${work}/good-payload"
cat "${work}/thor.dtb" >> "${work}/good-payload"
make_boot "${work}/good-payload" "${work}/initramfs" "${work}/source-KERNEL"

install -d "${work}/good"
cp "${work}/initramfs" "${work}/good/initramfs-linux-thorch.img"
"${repacker}" \
  --boot-dir "${work}/good" \
  --root-uuid "${uuid}" \
  --rootfstype btrfs \
  --source-kernel "${work}/source-KERNEL" >/dev/null
"${boot_check}" --boot-dir "${work}/good" >/dev/null
strings -n 8 "${work}/good/KERNEL" | grep -q 'allow_mismatched_32bit_el0' ||
  fail "repacked KERNEL omits ROCKNIX asymmetric CPU compatibility"

expect_rejected() {
  local label="$1" source="$2"
  local boot_dir="${work}/${label}"

  install -d "${boot_dir}"
  cp "${work}/initramfs" "${boot_dir}/initramfs-linux-thorch.img"
  cp "${source}" "${boot_dir}/KERNEL"
  if "${boot_check}" --boot-dir "${boot_dir}" >/dev/null 2>&1; then
    fail "boot checker accepted ${label} payload"
  fi
  if "${repacker}" \
    --boot-dir "${boot_dir}" \
    --root-uuid "${uuid}" \
    --rootfstype btrfs \
    --source-kernel "${source}" >/dev/null 2>&1; then
    fail "boot repacker accepted ${label} payload"
  fi
}

make_boot "${work}/Image.gz" "${work}/thor.dtb" "${work}/thor-in-ramdisk-KERNEL"
expect_rejected thor-in-ramdisk "${work}/thor-in-ramdisk-KERNEL"

make_boot "${work}/thor.dtb" "${work}/initramfs" "${work}/fdt-first-KERNEL"
expect_rejected fdt-first "${work}/fdt-first-KERNEL"

cp "${work}/Image.gz" "${work}/symbol-less-payload"
cat "${work}/thor-no-symbols.dtb" >> "${work}/symbol-less-payload"
make_boot "${work}/symbol-less-payload" "${work}/initramfs" "${work}/symbol-less-KERNEL"
expect_rejected symbol-less "${work}/symbol-less-KERNEL"

cp "${work}/good-payload" "${work}/generic-payload"
cat "${work}/aim300.dtb" >> "${work}/generic-payload"
make_boot "${work}/generic-payload" "${work}/initramfs" "${work}/generic-KERNEL"
expect_rejected generic-aim300 "${work}/generic-KERNEL"

printf 'thorch behavioral boot payload checks passed\n'
