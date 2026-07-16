# Update safety

Thorch does not currently publish a supported package feed. The repository can
build and test a local pacman repository, but that is a development input, not
a public update channel.

Installed updates must be complete `pacman -Syu` transactions. Partial upgrades
or direct replacement of individual package files are unsupported because the
kernel, modules, initramfs, boot payload, firmware, and userspace packages may
need to change together.

## Boot transaction

The `thorch-bsp` package installs libalpm hooks that:

1. retain the current `/boot/KERNEL`, initramfs, and matching modules before a
   transaction changes files;
2. rebuild and validate a candidate boot payload after the transaction; and
3. publish the candidate only after validation succeeds.

If rebuilding or validation fails, the retained boot files and modules are
restored. Pacman's package transaction may already be committed, so repository
rollback can still be required.

## Existing installations

Older images mask the stock mkinitcpio hooks and do not have the pre-transaction
retention hook. Upgrade `thorch-bsp` first, run `thorch-update-bootstrap`, and
confirm it reports ready before allowing the first kernel transaction. The
kernel package depends on the machine-local readiness marker so an
unbootstrapped direct upgrade fails before replacing the kernel.

`KERNEL.previous` is retained recovery material; automatic bootloader selection
of it has not been established. Keep tested SD recovery media available for
failed boots and power-loss recovery.
