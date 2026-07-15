# Developing Thorch

Thorch combines boot-chain, Arch packaging, hardware-control, desktop, and
installer code. A change is ready for review only when its affected package,
migration, automated tests, and hardware evidence agree.

## Quick start

From a fresh clone:

```bash
make doctor
make ci
```

`make doctor` reports the host, Bash version, required commands, container
provider, and privilege capabilities. It exits non-zero when the host cannot
run the same fast checks as pull-request CI. `make ci` never builds an image or
requires root; it runs the required lint, metadata, audit, and behavioral
fixtures.

Do not work around a failed doctor result by running `make ci` as root. Use the
supported environment or let the pull-request workflow establish the result.

## Supported environments

| Environment | Fast `make ci` | Full package/image build | Status |
|---|---:|---:|---|
| GitHub Actions CI job | Yes | No | Canonical fast-check environment; pinned Arch Linux amd64 container, checks run as an unprivileged user |
| Arch Linux x86_64 | Yes, when `make doctor` passes | Yes, with the documented container/root requirements | Supported native contributor environment |
| Other Linux x86_64 | Possible when every doctor check passes | Not established | Best effort; reproduce failures in the canonical environment |
| macOS / Apple Silicon | No | No | Not currently supported; the project builder is amd64-only and the native path has not passed the suite |
| AArch64 Linux host | Not established | Not established | Do not treat a partial result as equivalent to the required CI job |

The fast CI container is deliberately separate from the privileged nightly
image path. A green `make ci` does not establish that loop devices, mounts,
cross-architecture chroots, image assembly, or hardware boot work.

On a current Arch Linux x86_64 host, the canonical fast-check dependencies are:

```bash
sudo pacman -Syu --needed \
  actionlint android-tools desktop-file-utils dtc fakechroot git gnupg kirigami \
  libarchive pacman-contrib plasma5support python qt6-declarative ruff rsync rust \
  shadow shellcheck yamllint
export PATH="/usr/lib/qt6/bin:${PATH}"
make doctor
```

This package list matches `.github/workflows/ci.yml`. The workflow pins its
base container and every third-party Action to immutable digests/commits. When
updating a pin, record the upstream tag in the adjacent comment and verify the
commit or digest against the official upstream repository.

## Validation tiers

| Tier | Entry point | Privileges | Establishes |
|---|---|---:|---|
| Fast | `make ci` | None | Workflow/YAML validity, package metadata, ShellCheck, Python, Rust, QML, release audit, fake-device and behavioral fixtures |
| Integration | Targeted test or `make docker-<target>` | Sometimes root/container | Package clean-build, loop-device, mount, chroot, image, and upgrade behavior |
| Image | `make nightly` and `make check IMAGE=...` | Root plus container | Complete composed image and offline validation |
| Hardware | Recorded device test | Physical recovery access | Cold boot, input/display/audio/network, suspend/resume, update, failed-update recovery |

Environment-dependent skips are not passes. Required CI tooling is installed
up front, and CI sets `THORCH_REQUIRE_QML_SMOKE=1` so the QML smoke cannot
silently skip. Privileged mount tests may skip in fast CI because they belong to
the integration/nightly tier; a release gate must run them in a capable job.

## What `make ci` runs

1. `actionlint` and `yamllint` over repository workflows/YAML.
2. The canonical package/profile manifest validator and `makepkg
   --printsrcinfo` for every PKGBUILD.
3. Monotonic package-version validation against `THORCH_CI_BASE_REF` when a
   comparison commit is available.
4. ShellCheck and the existing release audit.
5. Python compilation plus focused Ruff correctness rules.
6. Cargo fmt/Clippy/test when a Cargo package exists; the current standalone
   Rust component receives changed-file formatting, Clippy, and direct unit
   tests until its Cargo migration.
7. QML parsing/format checks, a `qmllint` probe, and the project QML smoke.
8. Every rootless Bash fixture in `tests/`.

To compare package versions locally against main:

```bash
git fetch origin main
THORCH_CI_BASE_REF=origin/main make ci
```

Without a valid base ref, all other checks run but the monotonic comparison is
reported as skipped. Pull requests and pushes provide a base commit and must not
skip it.

## Package and profile rules

`manifests/packages.json` is the canonical package order and image/build
profile. Do not add a second hard-coded package inventory. Each record declares
the package directory, owner domain, test tier, and external inputs.

When any package-owned file or declared version input changes:

- increase `epoch:pkgver-pkgrel` using Arch version ordering;
- keep the package record and PKGBUILD path consistent;
- generate/parse `.SRCINFO` successfully with `makepkg --printsrcinfo`;
- update dependencies, `provides`, `conflicts`, `replaces`, and `backup=()` to
  describe the real ownership contract;
- do not rely on image-only `pacman -Rdd` or `--overwrite` behavior;
- preserve administrator configuration and add a migration fixture where a
  path or owner changes.

Packages own immutable vendor defaults in `/usr`. Administrator configuration
belongs in `/etc`, generated persistent state in `/var/lib/thorch`, and
ephemeral state in `/run/thorch`. A Thorch process must not rewrite a file owned
by a different package.

## Change impact

| Area changed | Minimum automated evidence | Additional evidence before release |
|---|---|---|
| Documentation, metadata, CI | `make ci`; action pins remain immutable | None unless release policy changed |
| Shell/Python/Rust helper | Focused unit/fake fixture plus `make ci` | Integration result if it invokes privileged/platform tools |
| QML/desktop integration | Parser/lint/smoke plus focused UI fixture | Screenshot or device/session result for visual or private-Plasma behavior |
| PKGBUILD/payload | Manifest/version checks and clean package build | N to N+1 install/upgrade result without overwrite/remove escapes |
| Hardware controls/input | Fake sysfs/input tests | Named hardware revision and tested states |
| Kernel/initramfs/boot payload | Golden boot fixtures and corrupt-candidate failure test | Cold boot plus documented previous-payload/module recovery |
| Installer/partition/filesystem | Plan/safety/failure fixtures for ext4 and Btrfs | Disposable-device install and SD recovery result |
| Update/repository policy | Two-version full-cohort upgrade and downgrade fixture | Exact candidate hardware canary before channel promotion |

## Pull-request workflow

1. Fork or branch from current `main`; keep one coherent change per pull
   request.
2. Read `docs/architecture/overview.md` and the relevant decision records.
   Use `MAINTAINERS.md` and `.github/CODEOWNERS` to find the current safety
   owner for the affected domain.
3. Update implementation, package metadata, migration, tests, and docs in the
   same change.
4. Run `make doctor`, then `THORCH_CI_BASE_REF=origin/main make ci`.
5. Fill in the pull-request template with exact command output and distinguish
   pass, fail, and not tested.
6. Request the CODEOWNER for the affected safety domain. Boot, installer,
   storage, and update changes require particularly explicit failure evidence.

Do not commit build directories, package caches, root filesystems, raw images,
private/proprietary firmware, credentials, or signing material. Preserve
upstream notices and add integrity metadata for downloaded sources.

## Architecture changes

Consequential changes to package boundaries, persistent state, boot/update
transactions, release channels, or recovery guarantees require a short ADR in
`docs/architecture/decisions/`. An ADR records the decision and constraints; it
must not claim that an unimplemented gate already works.

The current architecture and its non-negotiable safety invariants are described
in [`docs/architecture/overview.md`](docs/architecture/overview.md).

Repository administrators should also read
[`docs/repository-settings.md`](docs/repository-settings.md). The versioned
ruleset requires the aggregate `ci` check, but it changes live GitHub state only
when an administrator explicitly applies it and verifies it with the provided
setup command.
