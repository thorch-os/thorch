#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kde_pkgbuild="${root}/packages/thorch-kde-defaults/PKGBUILD"
kde_install="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
image_builder="${root}/scripts/build-image.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for pkg in bluez bluez-utils bluedevil; do
  grep -Eq "depends=.*(^|[ (])${pkg}([ )]|$)" "${kde_pkgbuild}" ||
    fail "thorch-kde-defaults does not depend on ${pkg}"
done

grep -q '^install=thorch-kde-defaults\.install$' "${kde_pkgbuild}" ||
  fail "thorch-kde-defaults install script is not registered"

grep -q 'systemctl enable --now bluetooth\.service' "${kde_install}" ||
  fail "package install script does not enable bluetooth.service"

grep -q '^[[:space:]]*bluetooth\.service$' "${image_builder}" ||
  fail "image builder does not enable bluetooth.service"

printf 'thorch bluetooth base image checks passed\n'
