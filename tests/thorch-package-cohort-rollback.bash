#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf 'SKIP: package cohort rollback requires Linux\n'
  exit 0
fi
if [[ "${EUID}" -eq 0 ]]; then
  printf 'SKIP: package cohort rollback must run as an unprivileged user\n'
  exit 0
fi
for command in bsdtar fakeroot pacman repo-add; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'SKIP: package cohort rollback requires %s\n' "${command}"
    exit 0
  }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
package=thorch-cohort-fixture
install_root="${work}/root"

make_package() {
  local cohort="$1" version="$2" tree
  tree="${work}/tree-${cohort}"
  install -d "${tree}/usr/share/thorch" "${work}/repos/${cohort}"
  cat > "${tree}/.PKGINFO" <<EOF
pkgname = ${package}
pkgbase = ${package}
pkgver = ${version}-1
pkgdesc = Thorch package cohort rollback fixture
builddate = 1
packager = Thorch tests
size = 1
arch = any
license = MIT
EOF
  printf '%s\n' "${version}" > "${tree}/usr/share/thorch/cohort-version"
  bsdtar -cf "${work}/repos/${cohort}/${package}-${version}-1-any.pkg.tar" \
    -C "${tree}" .PKGINFO usr/share/thorch/cohort-version
  repo-add "${work}/repos/${cohort}/cohort.db.tar.gz" \
    "${work}/repos/${cohort}/${package}-${version}-1-any.pkg.tar" >/dev/null
}

write_config() {
  cat > "${work}/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
DBPath = ${install_root}/var/lib/pacman/
CacheDir = ${install_root}/var/cache/pacman/pkg/
LogFile = ${install_root}/var/log/pacman.log

[cohort]
Server = file://${work}/repos/$1
EOF
}

run_pacman() {
  fakeroot pacman --root "${install_root}" --config "${work}/pacman.conf" \
    --noconfirm "$@"
}

assert_version() {
  local expected="$1"
  pacman --root "${install_root}" --config "${work}/pacman.conf" \
    -Q "${package}" | grep -qx "${package} ${expected}-1"
  grep -qx "${expected}" "${install_root}/usr/share/thorch/cohort-version"
  pacman --root "${install_root}" --config "${work}/pacman.conf" -Dk >/dev/null
}

make_package n 1.0
make_package n1 2.0
install -d "${install_root}/var/cache/pacman/pkg" \
  "${install_root}/var/lib/pacman" "${install_root}/var/log"

write_config n
run_pacman -Sy "${package}" >/dev/null
assert_version 1.0
write_config n1
run_pacman -Syu >/dev/null
assert_version 2.0
write_config n
run_pacman -Syyuu >/dev/null
assert_version 1.0

printf 'thorch package cohort rollback checks passed\n'
