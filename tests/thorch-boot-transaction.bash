#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
transaction="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot-transaction"
hooks="${root}/packages/thorch-bsp/payload/usr/share/libalpm/hooks"
work="$(mktemp -d)"
fake_root="${work}/root"

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

install -d \
  "${fake_root}/boot" \
  "${fake_root}/etc/pacman.d/hooks" \
  "${fake_root}/usr/lib/modules/old-release" \
  "${fake_root}/usr/share/libalpm/hooks" \
  "${fake_root}/var/lib/pacman" \
  "${work}/bin"
printf 'old-kernel\n' > "${fake_root}/boot/KERNEL"
printf 'old-initramfs\n' > "${fake_root}/boot/initramfs-linux-thorch.img"
printf 'old-fallback\n' > "${fake_root}/boot/initramfs-linux-thorch-fallback.img"
printf 'old-module\n' > "${fake_root}/usr/lib/modules/old-release/example.ko"
printf 'old-image\n' > "${fake_root}/usr/lib/modules/old-release/Image"
ln -s /dev/null "${fake_root}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook"
ln -s /dev/null "${fake_root}/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
cp "${hooks}/60-thorch-boot-transaction-prepare.hook" \
  "${hooks}/95-thorch-boot-transaction-commit.hook" \
  "${fake_root}/usr/share/libalpm/hooks/"

cat > "${work}/bin/check" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
boot_dir=/boot
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --boot-dir) boot_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -s "${boot_dir}/KERNEL" && -s "${boot_dir}/initramfs-linux-thorch.img" ]]
! grep -q '^invalid' "${boot_dir}/KERNEL"
EOF

cat > "${work}/bin/rebuild" <<'EOF'
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
cp "${boot_dir}/KERNEL" "${boot_dir}/KERNEL.previous"
printf 'new-kernel\n' > "${boot_dir}/KERNEL"
EOF

cat > "${work}/bin/mkinitcpio-good" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-P" ]]
printf 'new-initramfs\n' > "${THORCH_TEST_BOOT_DIR}/initramfs-linux-thorch.img"
EOF

cat > "${work}/bin/mkinitcpio-fail" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod 755 "${work}/bin/"*

run_transaction() {
  THORCH_BOOT_ALLOW_UNPRIVILEGED=1 \
  THORCH_BOOT_ROOT="${fake_root}" \
  THORCH_BOOT_DIR="${fake_root}/boot" \
  THORCH_BOOT_MODULES_DIR="${fake_root}/usr/lib/modules" \
  THORCH_BOOT_STATE_DIR="${fake_root}/var/lib/thorch/boot-transaction" \
  THORCH_BOOT_LOCK_DIR="${fake_root}/run/boot-transaction.lock" \
  THORCH_BOOT_IMAGE_TOOL="${root}/packages/thorch-bsp/payload/usr/lib/thorch/boot_image.py" \
  THORCH_BOOT_REBUILD_COMMAND="${work}/bin/rebuild" \
  THORCH_BOOT_CHECK_COMMAND="${work}/bin/check" \
  THORCH_BOOT_ROOT_UUID=11111111-2222-3333-4444-555555555555 \
  THORCH_BOOT_ROOT_FSTYPE=ext4 \
  THORCH_BOOT_BACKUP_HEADROOM_KB=0 \
  THORCH_BOOT_SKIP_MOUNT_VERIFY="${THORCH_TEST_SKIP_MOUNT_VERIFY:-1}" \
  THORCH_BOOT_SKIP_MARKER_VERIFY="${THORCH_TEST_SKIP_MARKER_VERIFY:-0}" \
  THORCH_TEST_BOOT_DIR="${fake_root}/boot" \
  "${transaction}" "$@"
}

status="$(run_transaction status)"
grep -q 'bootstrap=required' <<<"${status}" || fail "legacy image was incorrectly marked ready"
if THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare >/dev/null 2>&1; then
  fail "kernel transaction ran before legacy bootstrap"
fi
: > "${fake_root}/var/lib/pacman/db.lck"
if run_transaction migrate >/dev/null 2>&1; then
  fail "legacy migration ran from inside a pacman transaction"
fi
rm -f "${fake_root}/var/lib/pacman/db.lck"
run_transaction migrate
[[ ! -e "${fake_root}/etc/pacman.d/hooks/60-mkinitcpio-remove.hook" ]] ||
  fail "legacy remove hook mask survived migration"
[[ ! -e "${fake_root}/etc/pacman.d/hooks/90-mkinitcpio-install.hook" ]] ||
  fail "legacy install hook mask survived migration"
status="$(run_transaction status)"
grep -q 'bootstrap=required' <<<"${status}" ||
  fail "hook migration bypassed the local readiness-package gate"
THORCH_TEST_SKIP_MARKER_VERIFY=1 run_transaction activate
status="$(run_transaction status)"
grep -q 'bootstrap=ready' <<<"${status}" || fail "bootstrap was not activated"
if THORCH_TEST_SKIP_MOUNT_VERIFY=0 THORCH_BOOT_RUNNING_RELEASE=old-release \
    run_transaction prepare >/dev/null 2>&1; then
  fail "boot transaction accepted an unmounted plain-directory /boot"
fi

# Exercise both rename boundaries deterministically. If power is lost after
# the previous generation is renamed, the next recovery operation must restore
# that name. If it is lost after the new generation is published, both trees
# must remain until the next operation verifies and removes the former one.
THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare
printf 'second-generation-kernel\n' > "${fake_root}/boot/KERNEL"
if THORCH_BOOT_RUNNING_RELEASE=old-release \
    THORCH_BOOT_TEST_PUBLICATION_FAILPOINT=after-previous-renamed \
    run_transaction prepare >/dev/null 2>&1; then
  fail "injected failure after the previous rollback rename was ignored"
fi
[[ ! -e "${fake_root}/var/lib/thorch/boot-transaction/rollback" ]] ||
  fail "failed previous-generation rename unexpectedly published a new rollback"
grep -q old-kernel \
  "${fake_root}/var/lib/thorch/boot-transaction/rollback.old/boot/KERNEL" ||
  fail "previous recovery generation was lost across the first rename boundary"
run_transaction restore
[[ -d "${fake_root}/var/lib/thorch/boot-transaction/rollback" ]] ||
  fail "restore did not normalize an interrupted previous-generation rename"
[[ ! -e "${fake_root}/var/lib/thorch/boot-transaction/rollback.old" ]] ||
  fail "restore left the normalized previous-generation name behind"

printf 'second-generation-kernel\n' > "${fake_root}/boot/KERNEL"
printf 'second-generation-initramfs\n' > "${fake_root}/boot/initramfs-linux-thorch.img"
if THORCH_BOOT_RUNNING_RELEASE=old-release \
    THORCH_BOOT_TEST_PUBLICATION_FAILPOINT=after-new-published \
    run_transaction prepare >/dev/null 2>&1; then
  fail "injected failure after durable rollback publication was ignored"
fi
grep -q second-generation-kernel \
  "${fake_root}/var/lib/thorch/boot-transaction/rollback/boot/KERNEL" ||
  fail "new recovery generation was not retained at the second rename boundary"
grep -q old-kernel \
  "${fake_root}/var/lib/thorch/boot-transaction/rollback.old/boot/KERNEL" ||
  fail "former recovery generation was deleted before the new one was durable"
run_transaction restore
[[ ! -e "${fake_root}/var/lib/thorch/boot-transaction/rollback.old" ]] ||
  fail "recovery did not finish interrupted former-generation cleanup"

# Restore the original live fixture before the normal package transaction.
printf 'old-kernel\n' > "${fake_root}/boot/KERNEL"
printf 'old-initramfs\n' > "${fake_root}/boot/initramfs-linux-thorch.img"
printf 'old-fallback\n' > "${fake_root}/boot/initramfs-linux-thorch-fallback.img"
install -d "${fake_root}/var/lib/thorch/boot-transaction/.rollback.orphan"
printf 'partial-copy\n' > \
  "${fake_root}/var/lib/thorch/boot-transaction/.rollback.orphan/partial"

THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare
[[ ! -e "${fake_root}/var/lib/thorch/boot-transaction/.rollback.orphan" ]] ||
  fail "prepare did not remove staging debris from an interrupted copy"
grep -q old-kernel "${fake_root}/var/lib/thorch/boot-transaction/rollback/boot/KERNEL" ||
  fail "pre-transaction hook did not retain KERNEL"
grep -q old-module "${fake_root}/var/lib/thorch/boot-transaction/rollback/modules/old-release/example.ko" ||
  fail "pre-transaction hook did not retain matching modules"

# Simulate pacman replacing/removing the old package files before PostTransaction.
rm -rf "${fake_root}/usr/lib/modules/old-release"
install -d "${fake_root}/usr/lib/modules/new-release"
printf 'new-module\n' > "${fake_root}/usr/lib/modules/new-release/example.ko"
printf 'new-image\n' > "${fake_root}/usr/lib/modules/new-release/Image"
THORCH_BOOT_MKINITCPIO_COMMAND="${work}/bin/mkinitcpio-good" \
THORCH_BOOT_TARGET_RELEASE=new-release \
  run_transaction commit
grep -q new-kernel "${fake_root}/boot/KERNEL" || fail "commit did not install new KERNEL"
grep -q old-kernel "${fake_root}/boot/KERNEL.previous" || fail "commit did not retain previous KERNEL"
grep -q old-module "${fake_root}/usr/lib/modules/old-release/example.ko" ||
  fail "commit did not keep running-kernel modules live until reboot"
status="$(run_transaction status)"
grep -q 'state=pending-reboot' <<<"${status}" || fail "commit is not pending confirmation"

rollback_hash="$(sha256sum "${fake_root}/var/lib/thorch/boot-transaction/rollback/boot/KERNEL")"
if THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare >/dev/null 2>&1; then
  fail "a second transaction replaced an unconfirmed recovery point"
fi
[[ "$(sha256sum "${fake_root}/var/lib/thorch/boot-transaction/rollback/boot/KERNEL")" == "${rollback_hash}" ]] ||
  fail "pending-update rejection changed the recovery point"
run_transaction restore
[[ ! -f "${fake_root}/var/lib/thorch/boot-transaction/pending-reboot" ]] ||
  fail "manual recovery left stale pending-reboot metadata"

# Repeat the valid transaction so the reboot-confirmation path is also proven.
THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare
rm -rf "${fake_root}/usr/lib/modules/old-release"
install -d "${fake_root}/usr/lib/modules/new-release"
printf 'new-module\n' > "${fake_root}/usr/lib/modules/new-release/example.ko"
printf 'new-image\n' > "${fake_root}/usr/lib/modules/new-release/Image"
THORCH_BOOT_MKINITCPIO_COMMAND="${work}/bin/mkinitcpio-good" \
THORCH_BOOT_TARGET_RELEASE=new-release \
  run_transaction commit

THORCH_BOOT_RUNNING_RELEASE=new-release run_transaction confirm
status="$(run_transaction status)"
grep -q 'state=confirmed' <<<"${status}" || fail "successful reboot was not confirmed"
[[ -d "${fake_root}/var/lib/thorch/boot-transaction/rollback/modules/old-release" ]] ||
  fail "confirmation removed the prior recovery state"
[[ ! -d "${fake_root}/usr/lib/modules/old-release" ]] ||
  fail "confirmation left the former live module tree installed"

run_transaction restore
grep -q old-kernel "${fake_root}/boot/KERNEL" || fail "manual recovery did not restore KERNEL"
grep -q old-module "${fake_root}/usr/lib/modules/old-release/example.ko" ||
  fail "manual recovery did not restore matching modules"

# A changed kernel/module ABI must never reuse the running uname release: the
# old and new trees cannot coexist at modprobe's single lookup path.
THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare
printf 'changed-same-release\n' > "${fake_root}/usr/lib/modules/old-release/example.ko"
if THORCH_BOOT_MKINITCPIO_COMMAND="${work}/bin/mkinitcpio-good" \
  THORCH_BOOT_TARGET_RELEASE=old-release \
    run_transaction commit >/dev/null 2>&1; then
  fail "commit accepted changed modules under the running uname release"
fi
grep -q old-module "${fake_root}/usr/lib/modules/old-release/example.ko" ||
  fail "same-release rejection did not restore the running modules"

# Prove a post-transaction failure restores the pre-transaction state.
THORCH_BOOT_RUNNING_RELEASE=old-release run_transaction prepare
rm -rf "${fake_root}/usr/lib/modules/old-release"
printf 'invalid-new-kernel\n' > "${fake_root}/boot/KERNEL"
if THORCH_BOOT_MKINITCPIO_COMMAND="${work}/bin/mkinitcpio-fail" \
  THORCH_BOOT_TARGET_RELEASE=broken-release \
  run_transaction commit >/dev/null 2>&1; then
  fail "commit accepted a failing mkinitcpio transaction"
fi
grep -q old-kernel "${fake_root}/boot/KERNEL" || fail "failed commit replaced known-good KERNEL"
grep -q old-module "${fake_root}/usr/lib/modules/old-release/example.ko" ||
  fail "failed commit did not restore old modules"
status="$(run_transaction status)"
grep -q 'state=failed' <<<"${status}" || fail "failed transaction status was not recorded"

grep -q '^AbortOnFail$' "${hooks}/60-thorch-boot-transaction-prepare.hook" ||
  fail "pre-transaction hook cannot abort an unsafe package transaction"
grep -q '^When = PreTransaction$' "${hooks}/60-thorch-boot-transaction-prepare.hook" ||
  fail "retention hook is not pre-transaction"
grep -q '^When = PostTransaction$' "${hooks}/95-thorch-boot-transaction-commit.hook" ||
  fail "boot rebuild hook is not post-transaction"
grep -q '^Operation = Install$' "${hooks}/60-thorch-boot-transaction-prepare.hook" ||
  fail "pre-transaction hook does not guard a first kernel installation"
grep -q '^Operation = Install$' "${hooks}/95-thorch-boot-transaction-commit.hook" ||
  fail "post-transaction hook does not guard a first kernel installation"
if grep -Eq '^[[:space:]]*/usr/lib/thorch/boot-transaction[[:space:]]+migrate' \
    "${root}/packages/thorch-bsp/thorch-bsp.install"; then
  fail "package scriptlet can mark bootstrap ready inside a combined kernel transaction"
fi
grep -q 'thorch-update-bootstrap' "${root}/scripts/build-image.sh" ||
  fail "fresh image composition does not complete boot bootstrap after pacman exits"
grep -q '^ConditionPathIsMountPoint=/boot$' \
    "${root}/packages/thorch-bsp/payload/usr/lib/systemd/system/thorch-boot-confirm.service" ||
  fail "boot confirmation service does not require the real boot mount"

printf 'thorch transactional boot-update checks passed\n'
