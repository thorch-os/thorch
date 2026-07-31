#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  unset ROCKNIX_REF ROCKNIX_KERNEL_SOURCE ROCKNIX_KERNEL_RELEASE ROCKNIX_KERNEL_IMAGE_SHA256
  unset THORCH_KERNEL_REF THORCH_KERNEL_TARBALL_SHA256
  # shellcheck source=../config/thorch.conf
  source "${root}/config/thorch.conf"

  [[ "${ROCKNIX_REF}" == "e7650bd7fc72e610a105e0eb0e04d34316f2be2d" ]]
  [[ "${ROCKNIX_KERNEL_SOURCE}" == "nightly" ]]
  [[ "${ROCKNIX_KERNEL_RELEASE}" == "nightly-20260730" ]]
  [[ "${ROCKNIX_KERNEL_IMAGE_SHA256}" == "83b894b2fa89304f91d554d5f9268d846c42b0a90ad970b7a6900839c531ff99" ]]
  [[ "${THORCH_KERNEL_REF}" == "v7.1.2" ]]
  [[ "${THORCH_KERNEL_TARBALL_SHA256}" == "37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f" ]]
)

(
  startdir="${root}/packages/linux-thorch"
  # shellcheck source=../packages/linux-thorch/PKGBUILD
  source "${root}/packages/linux-thorch/PKGBUILD"
  [[ "${pkgver}" == "7.1.2" ]]
)

(
  startdir="${root}/packages/thorch-fex-bin"
  # shellcheck source=../packages/thorch-fex-bin/PKGBUILD
  source "${root}/packages/thorch-fex-bin/PKGBUILD"
  [[ "${pkgver}" == "2607" ]]
)

(
  # shellcheck source=../packages/thorch-mesa/PKGBUILD
  source "${root}/packages/thorch-mesa/PKGBUILD"
  [[ "${pkgver}" == "26.1.6" ]]
  [[ "${sha256sums[0]}" == "5296b88a0f1e012e2cb9ada150a2bbadf728ca81e5a4fb2ab43c83a4d2158606" ]]
)

printf 'Thorch ROCKNIX, kernel, FEX, and Mesa pins are aligned\n'
