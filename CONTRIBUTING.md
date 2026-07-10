# Contributing

Thorch is experimental hardware bring-up code. Keep changes small,
traceable, and easy to reproduce.

Before opening a change:

- Run `./scripts/audit-release.sh`.
- Run `make test` and account for any environment-dependent skips.
- Keep generated artifacts out of the source tree and out of commits.
- Pin ROCKNIX refs with full commits for release builds.
- Preserve upstream license notices and provenance files.
- Do not add proprietary firmware, Steam client payloads, private keys, tokens,
  local root filesystems, package caches, or raw images.
- For installer or block-device changes, document the safety guard being added
  or preserved.
- For boot-image, kernel, or DTB changes, add or update a behavioral fixture in
  `tests/thorch-boot-payload-validation.bash`.
- For root filesystem changes, test both ext4 and Btrfs paths, including image
  sizing, expansion, internal install, and cache tmpfs behavior where relevant.

Useful validation:

```bash
./scripts/audit-release.sh
make test
./scripts/check-thorch-image.sh output/thorch-arch-aarch64.img
```

To use the same hosted-builder path as GitHub Actions:

```bash
make docker-image-pull || make docker-image-build
make docker-nightly
```

The Docker build uses the plain `chroot` rootfs backend. Do not introduce a
self-hosted runner or make nested `systemd-nspawn` a release requirement.

The top-level `Makefile` wraps the common script entry points. Keep behavior in
`scripts/`; add Make targets only as short aliases for common workflows.
