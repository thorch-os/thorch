#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${root}/config/thorch.conf"
sleep_conf="${root}/packages/thorch-bsp/payload/etc/systemd/sleep.conf.d/50-thorch-native-suspend.conf"
repacker="${root}/packages/thorch-bsp/payload/usr/bin/thorch-rebuild-abl-kernel"
patch_dir="${root}/packages/linux-thorch/patches"
opp_patch="${patch_dir}/0221-arm64-dts-qcom-sm8550-mark-pcie-suspend-opp.patch"
board_patch="${root}/packages/linux-thorch/dts-patches/0006-arm64-dts-qcom-qcs8550-ayn-common-s2idle-power.patch"
usb_rule="${root}/packages/thorch-bsp/payload/usr/lib/udev/rules.d/99-thorch-sm8550-usb-autosuspend.rules"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'ROCKNIX_REF="${ROCKNIX_REF:-f88efbedf4b0326e75a24ee111b907f7ec566d30}"' "${config}" ||
  fail "ROCKNIX source baseline changed instead of keeping the suspend stack local"

required_patches=(
  0210-PCI-host-common-add-d3cold-eligibility-helper.patch
  0211-PCI-qcom-add-get_ltssm-helper.patch
  0212-PCI-qcom-power-down-phy-via-PARF_PHY_CTRL.patch
  0213-PCI-dwc-use-d3cold-eligibility-helper-in-suspend-path.patch
  0214-PCI-qcom-add-d3cold-support.patch
  0215-PCI-qcom-skip-l23-ready-after-pme-sm8550.patch
  0218-regulator-qcom-rpmh-add-suspend-state-support.patch
  0219-regulator-core-apply-mem-state-for-s2idle.patch
  0220-PCI-qcom-use-suspend-opp-for-non-s2ram.patch
  0221-arm64-dts-qcom-sm8550-mark-pcie-suspend-opp.patch
)
for patch in "${required_patches[@]}"; do
  [[ -f "${patch_dir}/${patch}" ]] || fail "missing local suspend patch: ${patch}"
done

grep -qx 'MemorySleepMode=s2idle' "${sleep_conf}" ||
  fail "systemd does not select s2idle"
grep -q 'mem_sleep_default=s2idle' "${repacker}" ||
  fail "rebuilt boot images do not default to s2idle"
! grep -q 'mem_sleep_default=deep' "${repacker}" ||
  fail "rebuilt boot images still default to deep suspend"

[[ "$(grep -c '^+.*opp-hz = /bits/ 64 <1>;' "${opp_patch}")" -eq 2 ]] ||
  fail "both PCIe controllers need a synthetic suspend-only OPP"
[[ "$(grep -c '^+.*opp-peak-kBps = <5000 1>;' "${opp_patch}")" -eq 2 ]] ||
  fail "both PCIe suspend OPPs need the 5 MB/s wake floor"
[[ "$(grep -c '^+.*opp-suspend;' "${opp_patch}")" -eq 2 ]] ||
  fail "both synthetic OPPs must be marked for suspend"
[[ "$(grep -c 'opp-suspend;' "${opp_patch}")" -eq 2 ]] ||
  fail "only the two synthetic OPPs may be suspend OPPs"

grep -q 'regulator-off-in-suspend' "${board_patch}" ||
  fail "board patch does not turn off the gamepad MCU rail"
grep -q 'regulator-mode = <RPMH_REGULATOR_MODE_LPM>' "${board_patch}" ||
  fail "board patch does not lower the retained 1.8 V rail"
grep -q '^+.*wake-gpios = <&tlmm 96 GPIO_ACTIVE_LOW>;' "${board_patch}" ||
  fail "board patch does not correct PCIe WAKE# polarity"

grep -q 'KERNEL=="a600000.usb"' "${usb_rule}" ||
  fail "USB autosuspend rule does not target the primary SM8550 controller"
grep -q 'ATTR{power/control}="auto"' "${usb_rule}" ||
  fail "USB autosuspend rule does not enable runtime PM"

printf 'thorch cluster sleep policy checks passed\n'
