#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  unset ROCKNIX_REF ROCKNIX_KERNEL_SOURCE ROCKNIX_KERNEL_RELEASE ROCKNIX_KERNEL_IMAGE_SHA256
  unset THORCH_KERNEL_REF THORCH_KERNEL_TARBALL_SHA256
  # shellcheck source=../config/thorch.conf
  source "${root}/config/thorch.conf"

  [[ "${ROCKNIX_REF}" == "ad6803eb73c4a71d8dfeadd22d2a022f7df16bdc" ]]
  [[ "${ROCKNIX_KERNEL_SOURCE}" == "nightly" ]]
  [[ "${ROCKNIX_KERNEL_RELEASE}" == "nightly-20260913" ]]
  [[ "${ROCKNIX_KERNEL_IMAGE_SHA256}" == "7ac313236503db35e80f1848ad582f3b7beb338a786270d73da0faae4a59c17e" ]]
  [[ "${THORCH_KERNEL_REF}" == "v7.2" ]]
  [[ "${THORCH_KERNEL_TARBALL_SHA256}" == "f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3" ]]
)

(
  startdir="${root}/packages/linux-thorch"
  # shellcheck source=../packages/linux-thorch/PKGBUILD
  source "${root}/packages/linux-thorch/PKGBUILD"
  [[ "${pkgver}" == "7.2.0" ]]
)

(
  startdir="${root}/packages/thorch-fex-bin"
  # shellcheck source=../packages/thorch-fex-bin/PKGBUILD
  source "${root}/packages/thorch-fex-bin/PKGBUILD"
  [[ "${pkgver}" == "2608" ]]
)

(
  # shellcheck source=../packages/thorch-mesa/PKGBUILD
  source "${root}/packages/thorch-mesa/PKGBUILD"
  [[ "${pkgver}" == "26.1.6" ]]
  [[ "${sha256sums[0]}" == "5296b88a0f1e012e2cb9ada150a2bbadf728ca81e5a4fb2ab43c83a4d2158606" ]]
)

printf 'Thorch ROCKNIX, kernel, FEX, and Mesa pins are aligned\n'
