#!/usr/bin/env bash
set -euo pipefail

for command in makepkg pacman repo-add; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'SKIP: %s is required for the full package-upgrade fixture\n' "${command}"
    exit 0
  }
done

work="${THORCH_UPGRADE_FIXTURE_WORK:-$(mktemp -d)}"
install -d "${work}"
cleanup() {
  if [[ "${THORCH_KEEP_UPGRADE_FIXTURE:-0}" == "1" ]]; then
    printf 'kept upgrade fixture at %s\n' "${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

build_package() {
  local name="$1" version="$2" release="$3" cohort="$4"
  local dependency_csv="${5:-}" replacement="${6:-}" dependency
  local directory="${work}/build/${cohort}/${name}"
  install -d "${directory}/payload"
  printf '%s %s-%s from %s\n' "${name}" "${version}" "${release}" "${cohort}" \
    > "${directory}/payload/version"
  cat > "${directory}/PKGBUILD" <<EOF
pkgname=${name}
pkgver=${version}
pkgrel=${release}
pkgdesc='Thorch full-upgrade integration fixture'
arch=(any)
license=(MIT)
source=()
sha256sums=()
EOF
  if [[ -n "${dependency_csv}" ]]; then
    printf 'depends=(' >> "${directory}/PKGBUILD"
    IFS=, read -r -a dependencies <<< "${dependency_csv}"
    for dependency in "${dependencies[@]}"; do
      printf "'%s' " "${dependency}" >> "${directory}/PKGBUILD"
    done
    printf ')\n' >> "${directory}/PKGBUILD"
  fi
  if [[ -n "${replacement}" ]]; then
    cat >> "${directory}/PKGBUILD" <<EOF
provides=('${replacement}')
conflicts=('${replacement}')
replaces=('${replacement}')
EOF
  fi
  if [[ "${name}" == "thorch-upgrade-fixture" ]]; then
    printf 'backup=(etc/thorch-upgrade-fixture.conf)\n' >> "${directory}/PKGBUILD"
  fi
  cat >> "${directory}/PKGBUILD" <<EOF
package() {
  install -Dm644 "\${startdir}/payload/version" \
    "\${pkgdir}/usr/share/thorch-upgrade-fixture/${name}"
EOF
  if [[ "${name}" == "thorch-upgrade-fixture" ]]; then
    cat >> "${directory}/PKGBUILD" <<'EOF'
  install -d "${pkgdir}/etc"
  printf 'managed_default=%s\n' "${pkgver}" > "${pkgdir}/etc/thorch-upgrade-fixture.conf"
EOF
    if [[ "${version}" == "2.0" ]]; then
      cat >> "${directory}/PKGBUILD" <<'EOF'
  install -d "${pkgdir}/etc/sudoers.d"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "${pkgdir}/etc/sudoers.d/20-thorch-wheel"
EOF
    fi
  fi
  cat >> "${directory}/PKGBUILD" <<'EOF'
}
EOF
  (
    cd "${directory}"
    PKGDEST="${work}/repos/${cohort}" makepkg --nodeps --noconfirm --cleanbuild >/dev/null
  )
}

for cohort in n0 n n1; do
  install -d "${work}/repos/${cohort}"
done
build_package stock-kernel-fixture 1.0 1 n0
build_package alarm-base-fixture 1.0 1 n
build_package thorch-kernel-fixture 1.0 1 n '' stock-kernel-fixture
build_package thorch-upgrade-fixture 1.0 1 n \
  'alarm-base-fixture>=1.0,thorch-kernel-fixture'
build_package alarm-base-fixture 2.0 1 n1
build_package thorch-kernel-fixture 2.0 1 n1 '' stock-kernel-fixture
build_package thorch-upgrade-fixture 2.0 1 n1 \
  'alarm-base-fixture>=2.0,thorch-kernel-fixture'
repo-add "${work}/repos/n0/cohort-n0.db.tar.gz" "${work}/repos/n0/"*.pkg.tar.* >/dev/null
repo-add "${work}/repos/n/cohort-n.db.tar.gz" "${work}/repos/n/"*.pkg.tar.* >/dev/null
repo-add "${work}/repos/n1/cohort-n1.db.tar.gz" "${work}/repos/n1/"*.pkg.tar.* >/dev/null

install_root="${work}/installed"
install -d \
  "${install_root}/etc" \
  "${install_root}/var/cache/pacman/pkg" \
  "${install_root}/var/lib/pacman" \
  "${install_root}/var/log"

write_pacman_config() {
  local cohort="$1"
  cat > "${work}/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 1
DBPath = ${install_root}/var/lib/pacman/
CacheDir = ${install_root}/var/cache/pacman/pkg/
LogFile = ${install_root}/var/log/pacman.log

[cohort-${cohort}]
Server = file://${work}/repos/${cohort}
EOF
}

run_pacman() {
  if [[ "${EUID}" -eq 0 ]]; then
    pacman --root "${install_root}" --config "${work}/pacman.conf" --noconfirm "$@"
  else
    command -v fakeroot >/dev/null 2>&1 ||
      fail "fakeroot is required to exercise pacman from rootless CI"
    fakeroot pacman --root "${install_root}" --config "${work}/pacman.conf" --noconfirm "$@"
  fi
}

query_pacman() {
  pacman --root "${install_root}" --config "${work}/pacman.conf" "$@"
}

package_is_installed_exactly() {
  local package="$1"

  # pacman -Q also resolves providers (for example, querying `sh` can return
  # bash). Use the installed-name inventory when replacement is under test.
  query_pacman -Qq | grep -Fxq "${package}"
}

write_pacman_config n0
run_pacman -Sy stock-kernel-fixture >/dev/null
package_is_installed_exactly stock-kernel-fixture || fail "stock migration fixture was not installed"
write_pacman_config n
run_pacman -Syu thorch-upgrade-fixture >/dev/null
query_pacman -Q alarm-base-fixture | grep -q '1.0-1' || fail "N base package was not installed"
query_pacman -Q thorch-upgrade-fixture | grep -q '1.0-1' || fail "N Thorch package was not installed"
query_pacman -Q thorch-kernel-fixture | grep -q '1.0-1' || fail "N Thorch kernel was not installed"
if package_is_installed_exactly stock-kernel-fixture; then
  fail "normal N repository transaction retained the replaced stock package"
fi
printf 'administrator_value=preserve-me\n' > "${install_root}/etc/thorch-upgrade-fixture.conf"
# Existing images created this exact path outside pacman. N+1 deliberately
# claims a different package path so libalpm's pre-transaction file-conflict
# check can complete before the exact-content migration removes the legacy file.
install -d "${install_root}/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > \
  "${install_root}/etc/sudoers.d/10-thorch-wheel"

write_pacman_config n1
run_pacman -Syu >/dev/null
query_pacman -Q alarm-base-fixture | grep -q '2.0-1' || fail "full upgrade omitted base package"
query_pacman -Q thorch-upgrade-fixture | grep -q '2.0-1' || fail "full upgrade omitted Thorch package"
query_pacman -Q thorch-kernel-fixture | grep -q '2.0-1' ||
  fail "normal repository transaction did not install the replacement package"
if package_is_installed_exactly stock-kernel-fixture; then
  fail "normal repository transaction retained the replaced stock package"
fi
grep -q 'administrator_value=preserve-me' "${install_root}/etc/thorch-upgrade-fixture.conf" ||
  fail "full upgrade overwrote administrator configuration"
grep -q 'managed_default=2.0' "${install_root}/etc/thorch-upgrade-fixture.conf.pacnew" ||
  fail "new vendor configuration was not delivered as .pacnew"
[[ -f "${install_root}/etc/sudoers.d/20-thorch-wheel" ]] ||
  fail "N+1 package-owned policy was not installed beside the unowned legacy path"
query_pacman -Dk >/dev/null || fail "package dependency database is inconsistent after upgrade"

# Retaining the complete N cohort permits a coherent package downgrade. This
# deliberately uses pacman's double-refresh/downgrade mode against only N.
write_pacman_config n
run_pacman -Syyuu >/dev/null
query_pacman -Q alarm-base-fixture | grep -q '1.0-1' || fail "base rollback was not coherent"
query_pacman -Q thorch-upgrade-fixture | grep -q '1.0-1' || fail "Thorch rollback was not coherent"
query_pacman -Q thorch-kernel-fixture | grep -q '1.0-1' ||
  fail "retained cohort did not restore the prior Thorch kernel"
if package_is_installed_exactly stock-kernel-fixture; then
  fail "rollback reintroduced the stock package outside the supported Thorch cohort"
fi
grep -q 'administrator_value=preserve-me' "${install_root}/etc/thorch-upgrade-fixture.conf" ||
  fail "rollback overwrote administrator configuration"
query_pacman -Dk >/dev/null || fail "package dependency database is inconsistent after rollback"

printf 'thorch full N-to-N+1 and retained-cohort rollback checks passed\n'
