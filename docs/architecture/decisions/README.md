# Architecture decision records

Decision records define contracts that multiple components or release stages
must preserve. They are intentionally short and remain in Git with the code
whose design they govern.

| ADR | Decision |
|---|---|
| [0001](0001-monorepo-and-package-boundaries.md) | Keep one source monorepo and split runtime ownership through packages |
| [0002](0002-full-cohort-pacman-updates.md) | Deliver installed updates as retained full pacman cohorts |
| [0003](0003-transactional-boot-payload.md) | Treat boot generation as a staged transaction with coherent recovery |
| [0004](0004-release-channels-and-recovery.md) | Promote exact artifacts through gated testing/stable channels |

Use `Proposed`, `Accepted`, `Superseded`, or `Rejected` as the status. An
accepted design is not evidence that every implementation or release gate has
already been completed; verification remains in tests and release records.
