# Nightly GitHub Actions Builds

The nightly workflow builds a full Thorch image on a GitHub-hosted Ubuntu
runner by using the same Docker builder entry points that local developers use.
It publishes the compressed image as a GitHub prerelease asset.
No self-hosted Arch runner is required.

The builder image is defined by `Dockerfile`. Default-branch runs of
`.github/workflows/builder-image.yml` publish the existing AMD64 `latest` and
full commit-SHA tags plus separate ARM64 `latest-arm64` and commit-SHA tags.
Both jobs report their resulting content digest. The nightly never uses the
moving tags: it pulls the reviewed, architecture-matched digest recorded in its
workflow, for example:

```text
ghcr.io/<owner>/thorch-build@sha256:<64-hex-digest>
```

Pull requests build both images without pushing them, so Dockerfile and
architecture-specific base changes are validated before merge. The AMD64 and
ARM64 base images are both pinned by digest. After a reviewed builder change
lands, copy the matching digest from the Builder Image job summary into
`THORCH_BUILDER_DIGEST` and `THORCH_DOCKER_IMAGE` in the nightly workflow, then
verify that exact digest can be pulled before relying on it for a release.

The nightly authenticates to GHCR, pulls only the ARM64 digest, verifies the
pulled repository digest, then runs `make docker-nightly`. It intentionally
does not fall back to a local build: such a fallback could publish with an
unreviewed toolchain. Package and image rootfs commands use
`THORCH_ROOTFS_RUNNER=chroot`, so the build does not need nested
`systemd-nspawn`.

## GHCR Access

The nightly job grants its `GITHUB_TOKEN` `packages: read`; the builder job has
`packages: write`. The `thorch-build` package must also be linked to this
repository and list it under the package's **Manage Actions access** settings.
If a pull is denied, verify package visibility, repository linkage, and Actions
access in GitHub before changing the workflow.

## Runner Shape

The job runs on:

```text
ubuntu-24.04-arm
```

This four-core ARM64 runner builds the aarch64 kernel, packages, and rootfs
natively; it does not register QEMU binfmt handlers. The host step installs
only release-side tooling (`zstd`) and uses Docker for the build environment.
The Makefile wrapper runs the Thorch builder with
`docker run --privileged`, matching the ROCKNIX-style "docker target wraps the
normal make target" model. The privileged container is needed for loop devices,
read-only ROCKNIX image imports, and kernel-mounted Btrfs population. The
workspace bind mount disables SELinux relabeling, which avoids the common
Docker-on-SELinux failure mode. Repository Actions workflow permissions must
allow `contents: write` so `GITHUB_TOKEN` can create prereleases and
`packages: read` so it can fetch the builder.

The nightly requires the privileged mount integration test; an unsupported or
skipped result fails the job.

The nightly target runs:

```bash
make audit
make test
make build
make check IMAGE=output/thorch-arch-aarch64.img
```

On a supported Linux x86_64 host, the same path is:

```bash
make docker-image-pull || make docker-image-build
make docker-nightly
```

For release-equivalent testing, set `THORCH_DOCKER_IMAGE` to the exact digest
from the nightly workflow instead of using the local convenience tag.

## Schedule And Releases

`.github/workflows/nightly.yml` runs daily at `13:37 UTC` and can also be run
manually from the Actions tab. Manual runs can override:

- `image_size`: defaults to `auto`.
- `root_fstype`: `btrfs` or `ext4`, defaulting to `btrfs`.
- `publish_release`: defaults to enabled.

Scheduled and manual runs load `ROCKNIX_REF`, `ROCKNIX_KERNEL_SOURCE`, and
`ROCKNIX_KERNEL_RELEASE` from the versioned defaults in `config/thorch.conf`.
The workflow requires a full source commit SHA and a dated nightly release tag;
it rejects rolling values such as `next` and `latest`. Advance those pins in a
reviewed commit after validating the new combination. Manual runs can select
ext4 when an uncompressed compatibility image is needed.

The current kernel-image pin is `nightly-20260728`, whose SM8550 asset was
validated by successful Thorch nightly run
[`30375469331`](https://github.com/thorch-os/thorch/actions/runs/30375469331).
That run recorded the source image SHA-256 as
`a8c2994b0a4cf243c7cfead04539f13b4e9688c5f1628fec310914afb1b27577`.

Before preparing the host or starting Docker, the workflow downloads the most
recent build manifest for the requested configuration. If that manifest already
records the current Thorch commit, the job succeeds without building,
compressing, or publishing. A new Thorch commit (or a configuration with no
previous manifest) permits one validated build and prerelease.

Arch Linux ARM remains rolling at build time: a build triggered by a new Thorch
commit picks up the then-current rootfs and packages. Arch package, rootfs, or
other external movement cannot trigger a release by itself because the commit
gate runs before those inputs are downloaded. After validation, the workflow
records the Thorch commit, immutable builder digest, requested settings,
resolved ROCKNIX source and kernel provenance, verified Arch Linux ARM rootfs
hash, and complete installed package/version set in the release manifest.

Each workflow ref and requested build configuration has a stable 16-character
key. Published nightlies combine that key with the UTC date:

```text
nightly-<YYYYMMDD>-<configuration>
```

The key covers the workflow ref, committed ROCKNIX source and kernel pins,
image size, and root filesystem type. Different branches and ext4 compatibility
images therefore publish to separate releases. Nightly workflow runs are also
serialized across refs so mutable release updates cannot race.

If another Thorch commit for the same configuration is published on the same
UTC date, the workflow moves only that configuration's date tag to the newer
commit and replaces its release assets together.

Release assets include:

- `thorch-arch-aarch64-nightly-<YYYYMMDD>-<configuration>.img.zst`
- matching `.sha256`
- `thorch-nightly-<configuration>.build-manifest`, used to identify the Thorch
  commit already published for that configuration

The release notes include the source commit, requested ROCKNIX refs, selected
root filesystem, immutable builder digest, and kernel provenance copied from
the generated build tree.
