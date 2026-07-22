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

release_default="$(sed -n 's/^ROCKNIX_KERNEL_RELEASE=.*:-\([^}]*\)}.*$/\1/p' "${root}/config/thorch.conf")"
[[ "${release_default}" =~ ^nightly-[0-9]{8}$ ]] ||
  fail "default ROCKNIX runtime release is not pinned to an immutable nightly tag"

kernel_dir="${work}/kernel"
release="test-release+rocknix.1"
ref="topic/rocknix-kernel"
install -d \
  "${kernel_dir}/boot" \
  "${kernel_dir}/usr/lib/modules/${release}" \
  "${kernel_dir}/usr/lib/firmware/qcom/sm8550"
: > "${kernel_dir}/boot/Image"
: > "${kernel_dir}/boot/KERNEL"
: > "${kernel_dir}/usr/lib/firmware/qcom/a740_sqe.fw"
: > "${kernel_dir}/usr/lib/firmware/qcom/gmu_gen70200.bin"
: > "${kernel_dir}/usr/lib/firmware/qcom/sm8550/a740_zap.mbn"
cat > "${kernel_dir}/PROVENANCE" <<EOF
THORCH_KERNEL_REF=${ref}
THORCH_KERNEL_RELEASE=${release}
EOF

THORCH_KERNEL_REF="${ref}" validate_rocknix_kernel_provenance "${kernel_dir}" "${release}"
rocknix_kernel_artifacts_current "${kernel_dir}" "${release}" ||
  fail "current kernel artifacts were rejected"

if (THORCH_KERNEL_REF=other-ref validate_rocknix_kernel_provenance "${kernel_dir}" "${release}") >/dev/null 2>&1; then
  fail "kernel provenance accepted a mismatched configured ref"
fi

if (THORCH_KERNEL_REF="${ref}" validate_rocknix_kernel_provenance "${kernel_dir}" wrong-release) >/dev/null 2>&1; then
  fail "kernel provenance accepted a release not required by linux-thorch"
fi

install -d "${kernel_dir}/usr/lib/modules/extra-release"
if rocknix_kernel_artifacts_current "${kernel_dir}" "${release}"; then
  fail "kernel readiness accepted an extra stale module tree"
fi
rm -rf "${kernel_dir}/usr/lib/modules/extra-release"

rm -rf "${kernel_dir}/usr/lib/modules/${release}"
install -d "${kernel_dir}/usr/lib/modules/wrong-release"
if (THORCH_KERNEL_REF="${ref}" validate_rocknix_kernel_provenance "${kernel_dir}" "${release}") >/dev/null 2>&1; then
  fail "kernel provenance accepted a mismatched module release"
fi

pkgbuild="${work}/PKGBUILD"
cat > "${pkgbuild}" <<'EOF'
pkgname=linux-thorch
pkgver=7.1.2
pkgrel=9
EOF
[[ "$(linux_thorch_expected_kernel_release "${pkgbuild}")" == 7.1.2-thorch9 ]] ||
  fail "linux-thorch expected release was derived incorrectly"

printf 'thorch kernel provenance checks passed\n'
