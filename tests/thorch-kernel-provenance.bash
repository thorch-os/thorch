#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "${root}/scripts/lib/common.sh"

work="$(mktemp -d)"
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

kernel_dir="${work}/kernel"
release="test-release+rocknix.1"
ref="topic/rocknix-kernel"
install -d \
  "${kernel_dir}/usr/lib/modules/${release}" \
  "${kernel_dir}/usr/lib/firmware/qcom/sm8550"
: > "${kernel_dir}/usr/lib/firmware/qcom/a740_sqe.fw"
: > "${kernel_dir}/usr/lib/firmware/qcom/gmu_gen70200.bin"
: > "${kernel_dir}/usr/lib/firmware/qcom/sm8550/a740_zap.mbn"
cat > "${kernel_dir}/PROVENANCE" <<EOF
THORCH_KERNEL_REF=${ref}
THORCH_KERNEL_RELEASE=${release}
EOF

THORCH_KERNEL_REF="${ref}" validate_rocknix_kernel_provenance "${kernel_dir}"

if (THORCH_KERNEL_REF=other-ref validate_rocknix_kernel_provenance "${kernel_dir}") >/dev/null 2>&1; then
  fail "kernel provenance accepted a mismatched configured ref"
fi

rm -rf "${kernel_dir}/usr/lib/modules/${release}"
install -d "${kernel_dir}/usr/lib/modules/wrong-release"
if (THORCH_KERNEL_REF="${ref}" validate_rocknix_kernel_provenance "${kernel_dir}") >/dev/null 2>&1; then
  fail "kernel provenance accepted a mismatched module release"
fi

printf 'thorch kernel provenance checks passed\n'
