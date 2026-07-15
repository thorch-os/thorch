# Thorch architecture overview

This document describes the contributor boundaries and safety contracts for
the current monorepo. Some runtime source still lives in broad historical
packages such as `thorch-bsp`; the logical boundaries below guide incremental
extraction without requiring a repository rewrite.

## System context

Thorch combines an Arch Linux ARM root filesystem with imported ROCKNIX
hardware assets, a Thorch-built kernel, native Arch packages, and an Android
boot-format payload named `/boot/KERNEL`. The repository owns source,
packaging, image composition, migrations, tests, and release automation so a
behavioral change can land atomically with all of its delivery mechanics.

```text
verified upstream inputs
        |
        v
kernel/runtime import -> Arch package build -> rootfs composition -> image
                              |                      |                 |
                              v                      v                 v
                       package metadata       service/policy       boot check
                              |                                       |
                              +---------- installed update -----------+
```

Source hosting and binary delivery are separate concerns. Contributors change
the monorepo. Installed devices consume coherent packages through pacman; they
must not update by pulling a Git working tree.

## Logical components

| Domain | Current primary locations | Contract |
|---|---|---|
| Boot and kernel | `packages/linux-thorch`, BSP boot tools/initcpio files, kernel/import scripts | Parse, build, stage, validate, and recover the Android boot payload and matching modules |
| Hardware and input | BSP inputd/backlight/fan/RGB/hardware tools, InputPlumber and quirks packages | Stable command/config interfaces over device-specific sysfs/input behavior |
| First boot | `packages/thorch-firstboot` | Idempotent account, network, theme, and storage setup with explicit persistent state |
| Installer/storage | `packages/thorch-installer` | Separate planning/validation from destructive execution; revalidate immediately before writes |
| Desktop integration | KDE defaults, QML settings/quick settings, remaining BSP Plasma files | Use supported extension points and never silently replace unknown upstream state |
| Gaming/Android | Gaming, Gamescope, MangoHud, FEX, Waydroid packages | Optional product capabilities with their own dependency and provenance contracts |
| Build/release | `manifests`, `scripts`, `config`, workflows | Resolve explicit inputs, build packages, compose/validate images, and promote exact cohorts |

`manifests/packages.json` is the single package/profile inventory. Its owner and
test-tier fields connect a changed package to CODEOWNERS and the evidence
expected in a pull request.

## Build flow

The intended build stages are:

1. Resolve and verify upstream revisions, URLs, hashes, and signing identities.
2. Import or build the kernel and hardware assets.
3. Build each package from declared inputs and metadata.
4. Compose the root filesystem from packages.
5. Construct `/boot/KERNEL` from the kernel, initramfs, DTBs, and root identity.
6. Assemble the image and validate partition, rootfs, package, and boot
   invariants.
7. Record the exact inputs and artifacts tested on hardware.

A lower stage must fail when an explicit input is absent. It must not silently
fetch a moving replacement. Promotion copies an already-tested artifact cohort;
it does not rebuild the same source label against newer dependencies.

## Installed update flow

Thorch updates are full pacman transactions, not a second package manager and
not a Thorch-only partial upgrade:

```text
signed retained cohort
        |
        v
preflight -> download full transaction -> retain known-good boot/modules
        -> pacman transaction -> stage candidate KERNEL -> validate
        -> durable replacement -> reboot-required state
```

The Thorch and qualified base-package snapshots together form one release
cohort. Direct `pacman -Syu` must receive the same safety hooks as any future
`thorch-update` front end. A public feed is not safe merely because packages
can be downloaded; the two-version upgrade, failed boot-generation, and
recovery fixtures are channel gates.

See the update and boot decision records for the detailed invariants.

## Boot and recovery invariants

- Never replace the live `/boot/KERNEL` with unvalidated candidate bytes.
- Retain a coherent known-good payload and its matching module set before
  package removal can make them unavailable.
- Installing hooks during a kernel transaction cannot protect that same
  transaction. Legacy hook masks require a separate bootstrap/migration step.
- A post-transaction hook can report failure but cannot roll back pacman's
  completed file transaction by itself.
- `KERNEL.previous` is a recovery artifact, not automatic rollback, until ABL
  alternate-payload selection is proven on supported hardware.
- SD recovery remains authoritative for power-loss and boot-selection failures
  that the installed system cannot repair itself.

## File and state ownership

| Location | Owner and mutability |
|---|---|
| `/usr` | Immutable package payload/vendor defaults |
| `/etc` | Administrator configuration; use PKGBUILD `backup=()` where appropriate |
| `/var/lib/thorch` | Generated persistent Thorch state and migrations |
| `/run/thorch` | Ephemeral state |
| `/boot` | Transactional boot artifacts with explicit staging and recovery rules |

No service or helper may rewrite a file owned by a different package. A
temporary compatibility mutation must recognize the exact upstream version or
hash, preserve the original, and fail closed for unknown content.

Cross-package calls are public interfaces. Keep command names, exit status, and
machine-readable output stable or add a versioned migration. Do not couple
packages through an undocumented file written into another package's payload.

## Validation boundaries

Fast pull-request CI is intentionally rootless. It validates workflows,
package metadata, language/tooling checks, audit rules, and fake-device
fixtures. It does not claim to validate privileged mounts or physical devices.

Privileged integration validates loop devices, filesystems, image composition,
clean package installation, and two-version transactions. Hardware validation
records the exact image/cohort, device revision, install medium, filesystem,
session, cold boot, suspend/resume, and recovery result. A skipped or untested
state is never a pass.

See [`DEVELOPMENT.md`](../../DEVELOPMENT.md) for commands and the change-impact
matrix.

## Ownership and evolution

The repository currently maps each domain to the verified maintainer in
`.github/CODEOWNERS`. Add real organization teams only after they exist and
have write access; an invalid CODEOWNER creates the appearance of review
without enforcement.

Keep the monorepo while extracting broad packages incrementally. A compatible
`thorch-bsp` meta-package can preserve upgrades as boot, hardware, UI, and debug
payloads gain narrower ownership. Directory movement is not a prerequisite for
safe update transactions.

Architecture decisions live in [`decisions/`](decisions/README.md).
