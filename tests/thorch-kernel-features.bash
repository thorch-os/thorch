#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fragment="${root}/packages/linux-thorch/waydroid-kernel.config"
build_script="${root}/scripts/build-thorch-kernel.sh"
driver_patch="${root}/packages/linux-thorch/patches/0300-mmc-add-qcom-downstream-sdhci-msm-driver.patch"
cleanup_patch="${root}/packages/linux-thorch/patches/0301-mmc-sdhci-msm-downstream-drop-sdhci_pltfm_free.patch"
clock_patch="${root}/packages/linux-thorch/patches/0302-Revert-clk-qcom-gcc-sm8550-Use-floor-ops-for-SDCC-RCGs.patch"
haptics_trace_patch="${root}/packages/linux-thorch/patches/0222-input-qcom-haptics-update-assign-str.patch"
dts_patch="${root}/packages/linux-thorch/dts-patches/0007-arm64-dts-qcom-qcs8550-ayn-thor-enable-sdr104.patch"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for symbol in \
  UNICODE \
  MMC_SDHCI_MSM_DOWNSTREAM \
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

grep -q 'config MMC_SDHCI_MSM_DOWNSTREAM' "${driver_patch}" ||
  fail "downstream SDHCI driver patch is missing its Kconfig symbol"
grep -q 'sdhci-msm-downstream.c' "${driver_patch}" ||
  fail "downstream SDHCI implementation is missing"
grep -q 'sdhci_pltfm_free' "${cleanup_patch}" ||
  fail "7.x downstream SDHCI cleanup patch is missing"
grep -q 'clk_rcg2_shared_ops' "${clock_patch}" ||
  fail "SDCC shared-clock operations patch is missing"
grep -q '__assign_str(id_name);' "${haptics_trace_patch}" ||
  fail "FTRACE-enabled Qualcomm haptics tracepoint fix is missing"
grep -q 'qcs8550-ayn-thor-sd.dtsi' "${dts_patch}" ||
  fail "Thor does not opt into the SDR104 node"
grep -q 'qcom,sdhci-msm-v5-downstream' "${dts_patch}" ||
  fail "Thor SDR104 node does not select the downstream driver"

printf 'thorch LAVD, SteamOS casefold, and SDR104 kernel checks passed\n'
