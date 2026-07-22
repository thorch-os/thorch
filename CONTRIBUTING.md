# Contributing

Thorch is experimental hardware bring-up code. Keep changes small, traceable,
and easy to reproduce.

## Before opening a pull request

Run the rootless checks from a supported Linux environment:

```bash
make doctor
git fetch origin main
THORCH_CI_BASE_REF=origin/main make ci
```

`make ci` checks workflows, package metadata, source formatting, and the
rootless behavioral fixtures. It does not prove that image assembly, mounts,
partitioning, or physical hardware work. Run the focused test for the code you
changed and record any privileged image or device testing that applies. A
skipped test is not a pass.

## Package changes

`manifests/packages.json` is the source of truth for package order, profiles,
and declared external inputs. When a package-owned file or declared version
input changes, increase its `epoch:pkgver-pkgrel` using pacman version ordering.
Declare runtime, build, and check dependencies in the PKGBUILD rather than
installing them as an out-of-band build step.

Package defaults belong under `/usr`, administrator configuration under
`/etc`, persistent generated state under `/var/lib/thorch`, and temporary state
under `/run/thorch`. Preserve locally edited configuration during upgrades.

## Safety-sensitive changes

- For installer or block-device changes, document the safety guard being added
  or preserved and test on disposable media.
- For boot-image, kernel, initramfs, or DTB changes, add or update a failure
  fixture and verify the recovery path on hardware before release.
- For root filesystem changes, test both ext4 and Btrfs paths where relevant.
- For hardware controls or input changes, run the fake-device test and record
  the device and hardware revision used for physical testing.

The hosted builder path is:

```bash
make docker-image-pull || make docker-image-build
make docker-nightly
```

## Repository hygiene

- Keep generated artifacts, images, package caches, root filesystems, secrets,
  and signing material out of commits.
- Pin release inputs to immutable revisions and preserve upstream license and
  provenance records.
- Do not add proprietary firmware or client payloads to the repository.
- Keep behavior in `scripts/`; add Make targets only as short entry-point
  aliases.
