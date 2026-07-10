# Nightly GitHub Actions Builds

The nightly workflow builds a full Thorch image on a GitHub-hosted Ubuntu
runner by using the same Docker builder entry points that local developers use.
It publishes the compressed image as a GitHub prerelease asset.
No self-hosted Arch runner is required.

The builder image is defined by `Dockerfile` and published by
`.github/workflows/builder-image.yml` as:

```text
ghcr.io/<owner>/thorch-build:latest
```

Default-branch builds publish both `latest` and a commit-SHA tag. Pull requests
build the image without pushing it, so Dockerfile changes are validated before
merge.

The nightly job pulls that image, or builds it locally as a fallback, then runs
`make docker-nightly`. Package and image rootfs commands use
`THORCH_ROOTFS_RUNNER=chroot`, so the build does not need nested
`systemd-nspawn`.

## Runner Shape

The job runs on:

```text
ubuntu-latest
```

The host step installs only release-side tooling (`zstd`) and uses Docker for
the build environment. The Makefile wrapper runs the Thorch builder with
`docker run --privileged`, matching the ROCKNIX-style "docker target wraps the
normal make target" model. The privileged container is needed for loop devices,
read-only ROCKNIX image imports, and kernel-mounted Btrfs population. The
workspace bind mount disables SELinux relabeling, which avoids the common
Docker-on-SELinux failure mode. Repository Actions workflow permissions must
allow `contents: write` so `GITHUB_TOKEN` can create prereleases.

The nightly target runs:

```bash
make audit
make test
make build
make check IMAGE=output/thorch-arch-aarch64.img
```

Locally, the same path is:

```bash
make docker-image-pull || make docker-image-build
make docker-nightly
```

## Schedule And Releases

`.github/workflows/nightly.yml` runs daily at `13:37 UTC` and can also be run
manually from the Actions tab. Manual runs can override:

- `rocknix_ref`: defaults to `next`.
- `rocknix_kernel_release`: defaults to `latest`.
- `image_size`: defaults to `auto`.
- `root_fstype`: `ext4` or `btrfs`, defaulting to `ext4`.
- `publish_release`: defaults to enabled.

Scheduled runs use the workflow defaults: ROCKNIX `next`, the latest nightly
SM8550 image, an auto-sized ext4 root, and prerelease publication. Manual runs
can select Btrfs for SD-card performance validation without changing the
repository default.

Each published nightly is a prerelease tagged with the UTC date and source
commit, for example:

```text
nightly-<date>-<commit>
```

Release assets include:

- `thorch-arch-aarch64-nightly-<date>-<sha>.img.zst`
- matching `.sha256`

The release notes include the source commit, requested ROCKNIX refs, selected
root filesystem, and kernel provenance copied from the generated build tree.
