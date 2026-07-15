# ADR 0003: Transactional boot payload

- Status: Accepted
- Date: 2026-07-15

## Context

The device boots an Android-format `/boot/KERNEL` containing a kernel,
initramfs, command line, and DTBs. Updating kernel package files without
rebuilding that payload can mismatch the boot image and modules. Writing the
live path before validation can destroy the current boot path.

## Decision

Treat a kernel/boot update as one staged transaction:

1. Preflight boot mount, space, power policy, and current payload validity.
2. Before package removal, retain the known-good payload and matching modules,
   or use an equivalently coherent side-by-side design.
3. Apply the full pacman transaction.
4. Build the candidate initramfs and Android payload on the boot filesystem in
   a staging path.
5. Validate structure, kernel/DTB identity, command line, and module coherence.
6. Flush the candidate durably and replace the live name only after validation.
7. Record structured success/failure and retain recovery material through a
   confirmed successful boot.

Legacy images that mask stock mkinitcpio hooks require a separate bootstrap
transaction to install Thorch hooks and remove masks before a kernel update.

## Consequences

- Pre- and post-transaction hooks protect direct `pacman -Syu`; a wrapper is
  not the safety boundary.
- Post-transaction failure cannot undo pacman's file transaction, so retention
  must occur before destructive package changes.
- Failure-injection tests must prove corrupt candidates never become live.
- Previous-payload claims require matching previous modules.
- Automatic rollback is not claimed until ABL selection is verified; SD
  recovery remains required.
