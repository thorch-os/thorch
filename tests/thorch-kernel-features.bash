#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fragment="${root}/packages/linux-thorch/waydroid-kernel.config"
build_script="${root}/scripts/build-thorch-kernel.sh"
driver_patch="${root}/packages/linux-thorch/patches/0300-mmc-add-qcom-downstream-sdhci-msm-driver.patch"
cleanup_patch="${root}/packages/linux-thorch/patches/0301-mmc-sdhci-msm-downstream-drop-sdhci_pltfm_free.patch"
clock_patch="${root}/packages/linux-thorch/patches/0302-Revert-clk-qcom-gcc-sm8550-Use-floor-ops-for-SDCC-RCGs.patch"
haptics_trace_patch="${root}/packages/linux-thorch/patches/0222-input-qcom-haptics-update-assign-str.patch"
retired_sdr104_patch="${root}/packages/linux-thorch/dts-patches/0007-arm64-dts-qcom-qcs8550-ayn-thor-enable-sdr104.patch"
gamepad_axis_patch="${root}/packages/linux-thorch/dts-patches/0007-arm64-dts-qcom-qcs8550-ayn-thor-set-gamepad-axis-range.patch"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for symbol in \
  UNICODE \
  DEBUG_INFO_BTF \
  SCHED_CLASS_EXT \
  FTRACE \
  FUNCTION_TRACER \
  DYNAMIC_FTRACE \
  KPROBES \
  KPROBE_EVENTS \
  UPROBE_EVENTS \
  PERF_EVENTS \
  BPF_EVENTS \
  CPU_FREQ_DEFAULT_GOV_SCHEDUTIL; do
  grep -qx "CONFIG_${symbol}=y" "${fragment}" ||
    fail "kernel fragment does not enable CONFIG_${symbol}"
done
grep -qx '# CONFIG_DEBUG_INFO_REDUCED is not set' "${fragment}" ||
  fail "kernel fragment leaves reduced debug info enabled"
grep -qx '# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set' "${fragment}" ||
  fail "kernel fragment leaves the performance governor as the default"

grep -q 'require_cmd .*pahole' "${build_script}" ||
  fail "kernel builder does not require pahole for BTF generation"
grep -q 'DYNAMIC_FTRACE_WITH_DIRECT_CALLS' "${build_script}" ||
  fail "kernel builder does not validate arm64 BPF trampoline support"
grep -q 'kernel patch or DTS inputs changed; rerun without --no-fetch' "${build_script}" ||
  fail "incremental kernel builds do not reject stale removed patches"
grep -q 'patch_input_digest="$(kernel_input_digest)"' "${build_script}" ||
  fail "kernel builder does not fingerprint its patch and DTS inputs"

for removed_patch in "${driver_patch}" "${cleanup_patch}" "${clock_patch}" "${retired_sdr104_patch}"; do
  [[ ! -e "${removed_patch}" ]] ||
    fail "retired SDR104 patch is still present: $(basename "${removed_patch}")"
done
! grep -q 'CONFIG_MMC_SDHCI_MSM_DOWNSTREAM' "${fragment}" ||
  fail "kernel fragment still enables the downstream SDHCI driver"
! grep -q 'MMC_SDHCI_MSM_DOWNSTREAM' "${build_script}" ||
  fail "kernel builder still requires the downstream SDHCI driver"
grep -q '__assign_str(id_name);' "${haptics_trace_patch}" ||
  fail "FTRACE-enabled Qualcomm haptics tracepoint fix is missing"
grep -Fq 'max-sd-hs-hz = <37500000>;' "${build_script}" ||
  fail "kernel builder does not enforce the 37.5 MHz board cap"
grep -Fq 'sdhci-caps-mask = <0x3 0x0>;' "${build_script}" ||
  fail "kernel builder does not enforce the unsupported UHS capability mask"
grep -Fq 'final ROCKNIX AYN DTS does not retain the 37.5 MHz SD clock cap' "${build_script}" ||
  fail "kernel builder does not fail when the board clock cap is absent"
grep -Fq 'final ROCKNIX AYN DTS does not mask unsupported UHS capabilities' "${build_script}" ||
  fail "kernel builder does not fail when the UHS capability mask is absent"
grep -Fq 'axis-range = <1024>;' "${gamepad_axis_patch}" ||
  fail "Thor DTS does not override the rsinput stick range to 1024 counts"
grep -Fq 'final ROCKNIX Thor DTS does not advertise the calibrated 1024-count stick range' "${build_script}" ||
  fail "kernel builder does not fail when the Thor stick range override is absent"
grep -q "printf 'THORCH_SD_DRIVER=upstream" "${build_script}" ||
  fail "kernel provenance does not identify the upstream SD driver"
grep -q "printf 'THORCH_SD_MAX_CLOCK_HZ=37500000" "${build_script}" ||
  fail "kernel provenance does not record the 37.5 MHz board cap"

printf 'thorch LAVD, SteamOS casefold, and upstream SD kernel checks passed\n'
