# Maintainers

Thorch currently has one verified repository maintainer: `@jaewun`. The
CODEOWNERS file routes every area to that account until real organization teams
exist; do not add placeholder teams that cannot review a pull request.

| Domain | Paths | Current owner | Release evidence |
|---|---|---|---|
| Boot and kernel | `packages/linux-thorch`, boot transaction code in `packages/thorch-bsp` | `@jaewun` | Golden/corrupt payload tests plus named hardware boot and recovery result |
| Installer and storage | `packages/thorch-installer`, image partition/filesystem code | `@jaewun` | Destructive-plan fixtures, disposable media install, and recovery result |
| Board support and hardware | `packages/thorch-bsp`, firmware and ROCKNIX quirks | `@jaewun` | Fake-device tests plus named device/revision evidence |
| Input | `packages/thorch-inputplumber`, input daemon and calibration | `@jaewun` | Unit/fake-input tests plus controller and suspend/resume result |
| Desktop and gaming | KDE defaults, firstboot, Gamescope, FEX and launchers | `@jaewun` | CI/QML checks plus session result for behavior changes |
| Packages and releases | `manifests`, package/repository scripts, workflows | `@jaewun` | Version/dependency checks, upgrade fixture, provenance, and cohort validation |

Safety-critical changes may merge with zero approvals only while no second
verified maintainer has write access; the main-branch ruleset still requires
CI and resolved review conversations. When another maintainer is established,
replace the relevant CODEOWNERS entries with a real team, document its members
here, and then raise the approval requirement without creating a review
deadlock.
