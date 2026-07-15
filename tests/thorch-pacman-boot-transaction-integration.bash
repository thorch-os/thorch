#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'SKIP: the pacman boot-transaction integration fixture requires Linux\n'
  exit 0
fi

for command in bsdtar fakechroot fakeroot makepkg pacman python3 repo-add; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'SKIP: %s is required for the rootless pacman boot-transaction fixture\n' \
      "${command}"
    exit 0
  }
done

if [[ "${EUID}" -eq 0 ]]; then
  printf 'SKIP: run the pacman boot-transaction fixture as an unprivileged user\n'
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
production_bsp="${root}/packages/thorch-bsp/payload"
work="${THORCH_PACMAN_BOOT_FIXTURE_WORK:-$(mktemp -d)}"
install_root="${work}/root"
python_stdlib="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"

cleanup() {
  if [[ "${THORCH_KEEP_PACMAN_BOOT_FIXTURE:-0}" == "1" ]]; then
    printf 'kept pacman boot-transaction fixture at %s\n' "${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Eq "^depends=.*'thorch-boot-bootstrap-ready>=1-1'" \
  "${root}/packages/linux-thorch/PKGBUILD" || \
  fail "production linux-thorch no longer declares the bootstrap marker dependency"
grep -Eq "^depends=.*'thorch-bsp>=1-27'" \
  "${root}/packages/linux-thorch/PKGBUILD" || \
  fail "production linux-thorch no longer declares its transaction-hook BSP dependency"
grep -Eq "^depends=.*'thorch-bsp>=1-27'" \
  "${root}/packages/thorch-boot-bootstrap-ready/PKGBUILD" || \
  fail "production bootstrap marker no longer keeps the transaction-hook BSP installed"

make_payload_package() {
  local package="$1" version="$2" cohort="$3" release="${4:-1}"
  local directory="${work}/build/${cohort}/${package}"
  local metadata=""

  if [[ "${package}" == "linux-thorch" && "${cohort}" == "n1" ]]; then
    metadata="depends=('thorch-boot-bootstrap-ready>=1-1' 'thorch-bsp>=1-27')"
  fi

  if [[ "${THORCH_REUSE_PACMAN_BOOT_FIXTURE:-0}" == "1" ]] &&
      compgen -G "${work}/repos/${cohort}/${package}-${version}-${release}-any.pkg.tar*" \
        >/dev/null; then
    return
  fi

  cat > "${directory}/PKGBUILD" <<EOF
pkgname=${package}
pkgver=${version}
pkgrel=${release}
pkgdesc='Thorch rootless pacman boot-transaction integration fixture'
arch=(any)
license=(MIT)
options=(!strip)
source=()
sha256sums=()
${metadata}

package() {
  cp -a "\${startdir}/payload/." "\${pkgdir}/"
}
EOF
  (
    cd "${directory}"
    PKGDEST="${work}/repos/${cohort}" PKGEXT=.pkg.tar \
      makepkg --nodeps --noconfirm --cleanbuild >/dev/null
  )
}

make_legacy_bsp() {
  local directory="${work}/build/n/thorch-bsp"
  install -d "${directory}/payload/usr/share/thorch-fixture"
  printf 'legacy BSP without transactional hooks\n' \
    > "${directory}/payload/usr/share/thorch-fixture/bsp-version"
  make_payload_package thorch-bsp 1 n 25
}

make_transactional_bsp() {
  local directory="${work}/build/n1/thorch-bsp"
  local payload="${directory}/payload"

  install -Dm755 \
    "${production_bsp}/usr/lib/thorch/boot-transaction" \
    "${payload}/usr/lib/thorch/boot-transaction"
  install -Dm755 \
    "${production_bsp}/usr/bin/thorch-update-bootstrap" \
    "${payload}/usr/bin/thorch-update-bootstrap"
  install -Dm755 \
    "${production_bsp}/usr/lib/thorch/create-bootstrap-ready-package" \
    "${payload}/usr/lib/thorch/create-bootstrap-ready-package"
  install -Dm644 \
    "${production_bsp}/usr/lib/thorch/boot-bootstrap-protocol" \
    "${payload}/usr/lib/thorch/boot-bootstrap-protocol"
  install -Dm644 \
    "${production_bsp}/usr/share/libalpm/hooks/60-thorch-boot-transaction-prepare.hook" \
    "${payload}/usr/share/libalpm/hooks/60-thorch-boot-transaction-prepare.hook"
  install -Dm644 \
    "${production_bsp}/usr/share/libalpm/hooks/95-thorch-boot-transaction-commit.hook" \
    "${payload}/usr/share/libalpm/hooks/95-thorch-boot-transaction-commit.hook"

  install -d "${payload}/usr/bin"
  cat > "${payload}/usr/bin/thorch-check-boot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
boot_dir=/boot
root_uuid=
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --boot-dir) boot_dir="$2"; shift 2 ;;
    --root-uuid) root_uuid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -s "${boot_dir}/KERNEL" ]]
[[ -s "${boot_dir}/initramfs-linux-thorch.img" ]]
if grep -q 'rebuilt N+1 kernel' "${boot_dir}/KERNEL"; then
  [[ "${root_uuid}" == "11111111-2222-3333-4444-555555555555" ]]
fi
EOF
  cat > "${payload}/usr/bin/thorch-rebuild-abl-kernel" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
boot_dir=/boot
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --boot-dir) boot_dir="$2"; shift 2 ;;
    --root-uuid|--rootfstype) shift 2 ;;
    *) shift ;;
  esac
done
cp -p "${boot_dir}/KERNEL" "${boot_dir}/KERNEL.previous"
printf 'rebuilt N+1 kernel\n' > "${boot_dir}/KERNEL"
EOF
  cat > "${payload}/usr/bin/mkinitcpio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-P" ]]
if [[ "${THORCH_FIXTURE_FAIL_POSTTRANSACTION:-0}" == "1" ]]; then
  printf 'injected mkinitcpio failure\n' >&2
  exit 42
fi
printf 'rebuilt N+1 initramfs\n' > /boot/initramfs-linux-thorch.img
EOF
  chmod 755 \
    "${payload}/usr/bin/thorch-check-boot" \
    "${payload}/usr/bin/thorch-rebuild-abl-kernel" \
    "${payload}/usr/bin/mkinitcpio"

  make_payload_package thorch-bsp 1 n1 27
}

make_old_marker() {
  local directory="${work}/build/old/thorch-boot-bootstrap-ready"
  install -d "${directory}/payload/usr/share/thorch"
  printf 'bootstrap_version=0\n' > \
    "${directory}/payload/usr/share/thorch/boot-bootstrap-ready"
  make_payload_package thorch-boot-bootstrap-ready 0 old
}

make_kernel() {
  local version="$1" cohort="$2" release="$3" label="$4"
  local directory="${work}/build/${cohort}/linux-thorch"
  local payload="${directory}/payload"

  install -d \
    "${payload}/boot" \
    "${payload}/etc/mkinitcpio.d" \
    "${payload}/usr/lib/modules/${release}"
  printf '%s kernel\n' "${label}" > "${payload}/boot/KERNEL"
  printf '%s initramfs\n' "${label}" \
    > "${payload}/boot/initramfs-linux-thorch.img"
  printf '%s module\n' "${label}" \
    > "${payload}/usr/lib/modules/${release}/example.ko"
  printf '%s image\n' "${label}" \
    > "${payload}/usr/lib/modules/${release}/Image"
  printf 'ALL_kver="/usr/lib/modules/%s/Image"\n' "${release}" \
    > "${payload}/etc/mkinitcpio.d/linux-thorch.preset"

  make_payload_package linux-thorch "${version}" "${cohort}"
}

copy_runtime_binary() {
  local command="$1" source resolved destination command_path
  source="$(command -v "${command}")"
  resolved="$(readlink -f "${source}")"
  destination="${install_root}${resolved}"
  install -Dm755 "${resolved}" "${destination}"
  command_path="${install_root}/usr/bin/${command}"
  if [[ "${command_path}" != "${destination}" ]]; then
    install -d "$(dirname "${command_path}")"
    ln -sfn "$(basename "${resolved}")" "${command_path}"
  fi
}

install_hook_runtime() {
  local command
  local -a commands=(
    awk bash basename cat chmod cp date df diff dirname du env find grep head id
    install mkdir mktemp mv python3 readlink rm rmdir sed sort sync tail uname
  )

  for command in "${commands[@]}"; do
    copy_runtime_binary "${command}"
  done
}

write_pacman_config() {
  local cohort="$1" repository="cohort_${1}"
  cat > "${work}/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 1
DBPath = ${install_root}/var/lib/pacman/
CacheDir = ${install_root}/var/cache/pacman/pkg/
LogFile = ${install_root}/var/log/pacman.log

[${repository}]
Server = file://${work}/repos/${cohort}
EOF
}

run_pacman() {
  LC_ALL=C \
  FAKECHROOT_EXCLUDE_PATH="/dev:/proc:/sys:${python_stdlib}" \
  THORCH_BOOT_ALLOW_UNPRIVILEGED=1 \
  THORCH_BOOT_RUNNING_RELEASE=thorch-old \
  THORCH_BOOT_ROOT_UUID=11111111-2222-3333-4444-555555555555 \
  THORCH_BOOT_ROOT_FSTYPE=ext4 \
  THORCH_BOOT_BACKUP_HEADROOM_KB=0 \
  THORCH_BOOT_SKIP_MOUNT_VERIFY=1 \
    fakechroot --use-system-libs fakeroot \
      pacman --root "${install_root}" --config "${work}/pacman.conf" \
        --noconfirm "$@"
}

query_pacman() {
  pacman --root "${install_root}" --config "${work}/pacman.conf" "$@"
}

run_bootstrap_in_root() {
  local real_pacman
  real_pacman="$(command -v pacman)"
  install -d "${work}/bin"
  cat > "${work}/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
has_root=0
needs_fakeroot=0
for argument in "$@"; do
  [[ "${argument}" == "--root" ]] && has_root=1
  [[ "${argument}" == "-U" || "${argument}" == "--upgrade" ]] && needs_fakeroot=1
done
command=("${THORCH_FIXTURE_REAL_PACMAN}")
[[ "${has_root}" -eq 1 ]] || command+=(--root "${THORCH_FIXTURE_ROOT}")
command+=("$@")
if [[ "${needs_fakeroot}" -eq 1 ]]; then
  exec fakeroot "${command[@]}"
fi
exec "${command[@]}"
EOF
  chmod 755 "${work}/bin/pacman"

  PATH="${work}/bin:${PATH}" \
  THORCH_FIXTURE_REAL_PACMAN="${real_pacman}" \
  THORCH_FIXTURE_ROOT="${install_root}" \
  THORCH_BOOT_ALLOW_UNPRIVILEGED=1 \
  THORCH_BOOT_ROOT="${install_root}" \
  THORCH_BOOT_TRANSACTION_COMMAND="${install_root}/usr/lib/thorch/boot-transaction" \
  THORCH_BOOT_MARKER_CREATOR="${install_root}/usr/lib/thorch/create-bootstrap-ready-package" \
  THORCH_BOOT_PROTOCOL_FILE="${install_root}/usr/lib/thorch/boot-bootstrap-protocol" \
    "${install_root}/usr/bin/thorch-update-bootstrap"
}

run_root_transaction() {
  THORCH_BOOT_ALLOW_UNPRIVILEGED=1 \
  THORCH_BOOT_ROOT="${install_root}" \
  THORCH_BOOT_ROOT_UUID=11111111-2222-3333-4444-555555555555 \
  THORCH_BOOT_ROOT_FSTYPE=ext4 \
  THORCH_BOOT_BACKUP_HEADROOM_KB=0 \
  THORCH_BOOT_RUNNING_RELEASE=thorch-old \
  THORCH_BOOT_SKIP_MOUNT_VERIFY=1 \
    "${install_root}/usr/lib/thorch/boot-transaction" "$@"
}

for cohort in n n1 old; do
  install -d "${work}/repos/${cohort}"
done
make_legacy_bsp
make_transactional_bsp
make_old_marker
make_kernel 1.0 n thorch-old N
make_kernel 2.0 n1 thorch-new N+1
repo-add "${work}/repos/n/cohort_n.db.tar.gz" "${work}/repos/n/"*-any.pkg.tar* >/dev/null
repo-add "${work}/repos/n1/cohort_n1.db.tar.gz" "${work}/repos/n1/"*-any.pkg.tar* >/dev/null

install -d \
  "${install_root}/etc/pacman.d/hooks" \
  "${install_root}/var/cache/pacman/pkg" \
  "${install_root}/var/lib/pacman" \
  "${install_root}/var/log"
cat > "${install_root}/etc/pacman.conf" <<'EOF'
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
DBPath = /var/lib/pacman/
CacheDir = /var/cache/pacman/pkg/
LogFile = /var/log/pacman.log
EOF
write_pacman_config n
run_pacman -Sy thorch-bsp linux-thorch >/dev/null
query_pacman -Q thorch-bsp | grep -q '1-25' || fail "legacy BSP was not installed"
query_pacman -Q linux-thorch | grep -q '1.0-1' || fail "N kernel was not installed"

# These exact masks model a legacy image. They are intentionally not owned by
# the old package, so only the explicit bootstrap command may remove them.
ln -s /dev/null "${install_root}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook"
ln -s /dev/null "${install_root}/etc/pacman.d/hooks/90-mkinitcpio-install.hook"

install_hook_runtime
write_pacman_config n1
run_pacman -Sy thorch-bsp >"${work}/bsp-only-upgrade.log" 2>&1
query_pacman -Q thorch-bsp | grep -q '1-27' || fail "transactional BSP was not installed"
query_pacman -Q linux-thorch | grep -q '1.0-1' || \
  fail "BSP bootstrap transaction also upgraded the kernel"
for path in \
  usr/bin/thorch-update-bootstrap \
  usr/lib/thorch/boot-transaction \
  usr/lib/thorch/boot-bootstrap-protocol \
  usr/lib/thorch/create-bootstrap-ready-package \
  usr/share/libalpm/hooks/60-thorch-boot-transaction-prepare.hook \
  usr/share/libalpm/hooks/95-thorch-boot-transaction-commit.hook; do
  cmp "${production_bsp}/${path}" "${install_root}/${path}" >/dev/null || \
    fail "fixture package did not install the exact production ${path}"
done
[[ ! -e "${install_root}/var/lib/thorch/boot-transaction/bootstrap.ready" ]] || \
  fail "installing the BSP marked bootstrap ready inside pacman"
[[ -L "${install_root}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook" ]] || \
  fail "BSP-only upgrade unexpectedly removed the legacy hook mask"

old_marker=("${work}/repos/old/"thorch-boot-bootstrap-ready-0-1-any.pkg.tar*)
run_pacman -U "${old_marker[0]}" >/dev/null
query_pacman -Q thorch-boot-bootstrap-ready | grep -q '0-1' || \
  fail "old bootstrap marker fixture was not installed"

# With the production hooks now discoverable by libalpm, the coordinator must
# still reject a direct kernel upgrade until the explicit bootstrap transaction
# installs a sufficiently new local dependency marker.
if run_pacman -Syu >"${work}/pre-bootstrap.log" 2>&1; then
  fail "pacman upgraded the kernel before explicit boot bootstrap"
fi
grep -q "unable to satisfy dependency 'thorch-boot-bootstrap-ready>=1-1'" \
  "${work}/pre-bootstrap.log" || \
  fail "linux-thorch was not gated by the local bootstrap marker dependency"
query_pacman -Q linux-thorch | grep -q '1.0-1' || \
  fail "the rejected pre-bootstrap transaction changed the kernel package"

run_bootstrap_in_root >/dev/null
query_pacman -Q thorch-boot-bootstrap-ready | grep -q '1-1' || \
  fail "separate bootstrap transaction did not install its readiness package"
if run_pacman -R thorch-bsp >"${work}/bsp-removal.log" 2>&1; then
  fail "pacman removed the transaction-hook BSP while the readiness marker was installed"
fi
grep -Eq "thorch-bsp>=1-27.*thorch-boot-bootstrap-ready" \
  "${work}/bsp-removal.log" || \
  fail "the marker's BSP dependency did not produce an actionable removal error"
[[ -f "${install_root}/var/lib/thorch/boot-transaction/bootstrap.ready" ]] || \
  fail "separate BSP bootstrap did not mark the coordinator ready"
[[ ! -e "${install_root}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook" ]] || \
  fail "separate BSP bootstrap did not remove the legacy remove-hook mask"
[[ ! -e "${install_root}/etc/pacman.d/hooks/90-mkinitcpio-install.hook" ]] || \
  fail "separate BSP bootstrap did not remove the legacy install-hook mask"

run_pacman -Syu >"${work}/upgrade.log" 2>&1
grep -q 'Retaining the current Thorch boot payload' "${work}/upgrade.log" || \
  fail "pacman did not discover the production pre-transaction hook"
grep -q 'Building and validating the updated Thorch boot payload' \
  "${work}/upgrade.log" || \
  fail "pacman did not discover the production post-transaction hook"
query_pacman -Q linux-thorch | grep -q '2.0-1' || fail "N to N+1 package upgrade failed"
grep -q 'rebuilt N+1 kernel' "${install_root}/boot/KERNEL" || \
  fail "post-transaction hook did not publish the rebuilt kernel"
grep -q 'N module' "${install_root}/usr/lib/modules/thorch-old/example.ko" || \
  fail "unique N+1 release did not retain running N modules"
grep -q 'N+1 module' "${install_root}/usr/lib/modules/thorch-new/example.ko" || \
  fail "N+1 module tree was not installed"
grep -q '^TARGET_RELEASE=thorch-new$' \
  "${install_root}/var/lib/thorch/boot-transaction/pending-reboot" || \
  fail "pending reboot does not identify the unique N+1 target release"

if run_pacman -S linux-thorch >"${work}/pending-gate.log" 2>&1; then
  fail "pending reboot gate allowed another kernel transaction"
fi
grep -q 'still pending reboot confirmation' "${work}/pending-gate.log" || \
  fail "pending reboot gate was not enforced by pacman hook execution"

run_root_transaction restore >/dev/null
grep -q 'N kernel' "${install_root}/boot/KERNEL" || \
  fail "retained rollback did not restore the N kernel"
grep -q 'N initramfs' "${install_root}/boot/initramfs-linux-thorch.img" || \
  fail "retained rollback did not restore the N initramfs"
grep -q 'N module' "${install_root}/usr/lib/modules/thorch-old/example.ko" || \
  fail "retained rollback did not restore matching N modules"
[[ ! -e "${install_root}/var/lib/thorch/boot-transaction/pending-reboot" ]] || \
  fail "retained rollback did not clear the pending gate"

# A PostTransaction failure happens after pacman has committed its package
# database, so the invariant under test is boot-state recovery, not package DB
# rollback. The same production commit path must restore the retained N state.
THORCH_FIXTURE_FAIL_POSTTRANSACTION=1 \
  run_pacman -S linux-thorch >"${work}/injected-failure.log" 2>&1 || true
grep -q 'injected mkinitcpio failure' "${work}/injected-failure.log" || \
  fail "post-transaction failure was not injected through the real hook"
grep -q '^state=failed$' \
  "${install_root}/var/lib/thorch/boot-transaction/status" || \
  fail "post-transaction recovery did not record failed state"
grep -q 'N kernel' "${install_root}/boot/KERNEL" || \
  fail "failed PostTransaction hook did not restore the N kernel"
grep -q 'N initramfs' "${install_root}/boot/initramfs-linux-thorch.img" || \
  fail "failed PostTransaction hook did not restore the N initramfs"
grep -q 'N module' "${install_root}/usr/lib/modules/thorch-old/example.ko" || \
  fail "failed PostTransaction hook did not restore running N modules"

printf 'thorch rootless pacman boot-transaction integration checks passed\n'
