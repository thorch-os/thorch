# ADR 0004: Release channels and recovery

- Status: Accepted
- Date: 2026-07-15

## Context

Nightly discovery, opted-in testing, and stable users have different risk
budgets. Rebuilding or mutating repositories between those stages invalidates
the hardware result. A rollback label is not useful unless all corresponding
packages and boot recovery material remain available.

## Decision

Use candidate/nightly, testing, and stable channels. Build a cohort once, store
it immutably, and promote that exact cohort only after its automated and
hardware gates pass. Publish package/database metadata after package objects so
clients never observe a database pointing to missing artifacts.

Retain at least the current and previous coherent Thorch/base cohorts and the
recovery image/material needed to restore them. Stable promotion records the
device matrix and exact artifact identities. Signing trust and key rotation are
release contracts; pull-request workflows never receive signing keys.

## Consequences

- A nightly may use discovery inputs only when their resolved values are
  recorded; stable inputs are immutable.
- Testing-to-stable promotion copies artifacts instead of rebuilding.
- Recovery exercises restore the coherent full cohort, not an arbitrary set of
  individually downgraded packages.
- Btrfs snapshots or A/B boot may improve recovery later, but neither is
  promised until the actual filesystem layout and boot selector are proven.
