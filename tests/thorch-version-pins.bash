#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  unset ROCKNIX_REF ROCKNIX_KERNEL_SOURCE ROCKNIX_KERNEL_RELEASE ROCKNIX_KERNEL_IMAGE_SHA256
  unset THORCH_KERNEL_REF THORCH_KERNEL_TARBALL_SHA256
  # shellcheck source=../config/thorch.conf
  source "${root}/config/thorch.conf"

  [[ "${ROCKNIX_REF}" == "60428a0a4438ec30ca0a440c1d6b6b97036673af" ]]
  [[ "${ROCKNIX_KERNEL_SOURCE}" == "nightly" ]]
  [[ "${ROCKNIX_KERNEL_RELEASE}" == "nightly-20260722" ]]
  [[ "${ROCKNIX_KERNEL_IMAGE_SHA256}" == "d15091074a052ae3241fb7fa4a7e5e9b84f934195a60959aab3739ce84f7c3ad" ]]
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
  [[ "${pkgver}" == "26.1.5" ]]
  [[ "${sha256sums[0]}" == "79e421c7ce18cd9e790b8375920325779f10798630bf30e0b22f1a21c8617122" ]]
)

printf 'Thorch ROCKNIX, kernel, FEX, and Mesa pins are aligned\n'
