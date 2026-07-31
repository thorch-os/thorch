#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkgbuild="${root}/packages/thorch-kde-defaults/PKGBUILD"
remote="${root}/packages/thorch-kde-defaults/payload/usr/share/flatpak/remotes.d/flathub.flatpakrepo"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

metadata="$(
  startdir="${root}/packages/thorch-kde-defaults"
  # shellcheck source=../packages/thorch-kde-defaults/PKGBUILD
  source "${pkgbuild}"
  printf '%s\n' "${depends[@]}"
)"

grep -qx bazaar <<< "${metadata}" ||
  fail "Bazaar is not a required package in the desktop image"
grep -qx flatpak <<< "${metadata}" ||
  fail "Flatpak is not a required package in the desktop image"
[[ ! -e "${remote}" ]] ||
  fail "Thorch must not duplicate the Flathub descriptor owned by the flatpak package"

printf 'ok\n'
