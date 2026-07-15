# ADR 0001: Monorepo and package boundaries

- Status: Accepted
- Date: 2026-07-15

## Context

Thorch changes often span runtime code, an Arch recipe, image policy, tests,
and documentation. Splitting repositories would make those changes harder to
review and release atomically. The existing `thorch-bsp` package, however,
contains unrelated boot, hardware, debug, and desktop responsibilities.

## Decision

Keep one source monorepo. Improve ownership through explicit logical components
and narrower Arch packages, migrated incrementally behind stable interfaces.
Retain a compatibility meta-package while installed systems move between
package boundaries.

Package boundaries follow ownership and release cadence: boot/core, hardware,
UI integration, first boot, installer, gaming, and debug. The canonical package
manifest owns build/profile order, ownership domain, test tier, and declared
inputs.

## Consequences

- A behavior, package migration, fixtures, and docs can land together.
- Repository-wide CI remains the merge gate.
- Moving directories alone is not architectural progress; extraction must
  reduce ownership/coupling while preserving upgrades.
- Package file collisions and cross-package command contracts require explicit
  tests during each extraction.
