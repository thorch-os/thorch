# ADR 0002: Full-cohort pacman updates

- Status: Accepted
- Date: 2026-07-15

## Context

Image composition can install locally staged packages with builder-only
conflict overrides. An installed device instead needs a reproducible full
system transaction. Updating only Thorch packages against a moving base can
produce a state that was never tested.

## Decision

Pacman remains the sole installed package transaction engine. A future
`thorch-update` command may preflight and explain a transaction, but it must
perform a full `pacman -Syu` and must not implement a parallel updater.

Every release cohort identifies and retains both the Thorch package snapshot
and the qualified base-package snapshot needed for the tested transaction.
Testing and stable promote the exact same package files, signatures, databases,
image, and manifest. Stable is not rebuilt from a tag.

## Consequences

- Direct pacman use and any UI/wrapper share package hooks and safety behavior.
- Package versions must increase when their declared inputs change.
- Normal upgrades may not depend on `--overwrite` or `-Rdd`.
- Storage, retention, and security-update policy includes the qualified base
  cohort, not only Thorch packages.
- No public update feed opens before a clean N to N+1 and retained-cohort
  recovery test passes.
