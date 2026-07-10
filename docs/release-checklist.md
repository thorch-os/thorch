# Release Checklist

Use this before publishing the repository or building public images.

## Source Tree

- Run `./scripts/audit-release.sh`.
- Confirm the source tree does not contain `build/`, `output/`, `local/`,
  synced `vendor/` trees, imported kernel/runtime artifacts, package
  `src/`/`pkg/` directories, package archives, raw images, rootfs images, logs,
  or caches.
- Confirm no local rootfs files such as `etc/shadow`, SSH keys, tokens, or
  personal host paths are present.
- Confirm `LICENSE`, `NOTICE.md`, `SECURITY.md`, and `CONTRIBUTING.md` are
  present.
- Confirm shell syntax checks, executable-bit checks, Python syntax checks, and
  desktop entry validation pass where the audit script can run them.
- Run `make test` and review any environment-dependent skips.

## Build Inputs

- Sync ROCKNIX sources with a full commit SHA.
- Confirm `ROCKNIX_REF`, `THORCH_KERNEL_REF`, and the imported ROCKNIX image are
  an intentional matching baseline. Read the requested refs from
  `config/thorch.conf` and confirm the exact resolved inputs in the generated
  source, kernel, and runtime provenance files.
- Import kernel and runtime artifacts from a verified upstream ROCKNIX image,
  not from local `makepkg` output or previous Thorch build artifacts.
- Verify the Arch Linux ARM rootfs through its detached signature or a pinned
  `ALARM_ROOTFS_SHA256`.
- Preserve `SOURCE_PROVENANCE`, `THORCH_FIRMWARE_PROVENANCE`, kernel
  `PROVENANCE`, and runtime `PROVENANCE` in generated artifacts.

## Public Image Builds

- Confirm the intended `THORCH_PASSWORD` for the image build; it defaults to
  `1234` unless overridden.
- Record the intended `THORCH_ROOT_FSTYPE`, Btrfs mount options when applicable,
  image headroom, and cache tmpfs size. Exercise both ext4 and Btrfs before
  changing the default.
- Prefer the hosted Docker path (`make docker-nightly`) used by GitHub Actions;
  it uses `THORCH_ROOTFS_RUNNER=chroot` and does not require a self-hosted Arch
  runner or nested `systemd-nspawn`.
- Run `./scripts/check-thorch-image.sh` on the generated image.
- Confirm strict boot checks pass: the image root UUID, framebuffer rotation,
  `allow_mismatched_32bit_el0`, BinderFS, exactly one symbol-bearing Thor DTB,
  and no generic AIM300 DTB.
- For Btrfs, confirm the build completed its full-file readback and run a data
  checksum scrub/check on the filesystem image or written card. Confirm the
  auto-sized image has only the requested headroom rather than unexplained free
  space.
- Validate the written card by passing the whole block device to
  `make check IMAGE=/dev/sdX` before hardware boot testing.
- Keep generated images and packages as release artifacts, not repository
  source files.

## Nightly Publication

- Confirm the builder image workflow builds on pull requests and publishes
  `latest` plus commit-SHA tags only from the default branch.
- Confirm the nightly uses a GitHub-hosted Ubuntu runner and records the selected
  root filesystem in its release notes.
- Confirm the `.img.zst`, matching `.sha256`, source commit, requested ROCKNIX
  refs, and kernel provenance are present in the prerelease.
