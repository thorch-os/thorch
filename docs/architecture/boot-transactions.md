# Boot update transaction

Thor's ABL Linux path boots `/boot/KERNEL`, an Android header-v0 image containing
the kernel, DTBs, command line, and Thorch initramfs. Updating `linux-thorch`
without rebuilding that file can leave the package database, module tree, and
boot payload on different versions.

## Installed sequence

Thorch owns two libalpm hooks:

1. `60-thorch-boot-transaction-prepare.hook` runs before files change and uses
   `AbortOnFail`. It validates and copies the current `KERNEL`, Thorch
   initramfs files, and the running kernel's matching module directory into
   `/var/lib/thorch/boot-transaction/rollback`. Every staged file and directory
   is fsynced before publication. The prior generation is renamed to
   `rollback.old`, the staged generation is renamed into place, and the state
   directory is fsynced before `rollback.old` is removed. An interruption at
   either rename boundary is normalized by the next prepare/restore operation.
2. Pacman applies the complete transaction.
3. `95-thorch-boot-transaction-commit.hook` runs `mkinitcpio -P`, builds a
   candidate on the boot filesystem, validates it with the canonical parser,
   flushes it, retains the former payload as `KERNEL.previous`, and renames the
   candidate into place.
4. If initramfs generation, repacking, or validation fails, the retained
   payload, initramfs, and module directory are restored. Pacman's package
   transaction is already committed, so the recorded state explains that
   package recovery is still required.
5. `thorch-boot-confirm.service` validates the payload after the next boot and
   confirms that the running kernel matches the pending release. One prior
   recovery set remains retained until the next transaction.

`thorch-boot-recover status` reports state. From a Thorch recovery environment,
mount the installed root and boot filesystems and use the transaction command
with the corresponding root/boot paths to restore the retained payload. ABL is
not currently proven to select `KERNEL.previous` automatically, so SD recovery
remains authoritative.

## Legacy image bootstrap

Existing images contain two `/etc/pacman.d/hooks/*mkinitcpio*.hook` symlinks to
`/dev/null`. They also do not have the pre-transaction retention hook. The first
repository migration must therefore be deliberately split:

1. install only the updated `thorch-bsp`/bootstrap payload;
2. run `thorch-update-bootstrap` and confirm it reports ready;
3. only then enable/run the full repository transaction containing
   `linux-thorch`.

Installing the hook during the same transaction that replaces the kernel is
too late: libalpm discovers hooks before applying that transaction.
`linux-thorch` therefore depends on `thorch-boot-bootstrap-ready` and directly
on the minimum BSP version that owns the transaction hooks. The marker also
depends on that BSP, so normal dependency resolution cannot remove the active
coordinator after bootstrap. That marker
is intentionally excluded from the release profile: an unbootstrapped direct
`pacman -Syu` fails dependency resolution before changing the kernel. The
separate `thorch-update-bootstrap` command removes only the exact legacy masks,
generates and installs the machine-local marker package, verifies the installed
hooks and marker, and only then persists readiness. Publishing the marker in a
remote repository would defeat this gate and is prohibited by manifest tests.

## Canonical image validation

`/usr/lib/thorch/boot_image.py` is the only parser for the Android header,
gzip boundary, appended DTB stream, command line, and embedded kernel config.
Build/import/image-validation scripts use the same CLI as the installed boot
checker. Golden fixtures cover bad magic, truncation, missing command-line
requirements, missing overlay symbols, duplicate Thor DTBs, and the forbidden
generic AIM300 DTB. Validation also compares the command line against the
actual root filesystem UUID: exactly one `root=` token must exist and it must
equal `root=UUID=<expected>`. Offline callers must pass the expected UUID;
installed-system callers derive it from the mounted root filesystem.

## Power-loss boundary

Staging, validation, recursive file/directory flushing, parent-directory
flushing, and same-filesystem rename prevent a failed candidate from replacing
the live payload. Deterministic tests exercise interruption immediately after
each rollback-generation rename. These protections do not make power loss
during pacman's root-filesystem transaction harmless. Stable qualification
therefore still requires hardware fault-injection testing plus the documented
SD recovery path and a retained full Thorch/base repository cohort.
