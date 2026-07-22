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

The nightly authenticates to GHCR, pulls only that digest, verifies the pulled
repository digest, then runs `make docker-nightly`. It intentionally does not
fall back to a local build: such a fallback could publish with an unreviewed
toolchain. Package and image rootfs commands use
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
ubuntu-latest
```

The host step installs only release-side tooling (`zstd`) and uses Docker for
the build environment. The Makefile wrapper runs the Thorch builder with
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

- `rocknix_ref`: defaults to `next`.
- `rocknix_kernel_release`: defaults to `latest`.
- `image_size`: defaults to `auto`.
- `root_fstype`: `btrfs` or `ext4`, defaulting to `btrfs`.
- `publish_release`: defaults to enabled.

Scheduled runs use the workflow defaults: ROCKNIX `next`, the latest nightly
SM8550 image, an auto-sized compressed Btrfs root, and prerelease publication.
Manual runs can select ext4 when an uncompressed compatibility image is needed.

Each published nightly is a prerelease tagged with the UTC date and source
commit, for example:

```text
nightly-<date>-<commit>
```

Release assets include:

- `thorch-arch-aarch64-nightly-<date>-<sha>.img.zst`
- matching `.sha256`

The release notes include the source commit, requested ROCKNIX refs, selected
root filesystem, immutable builder digest, and kernel provenance copied from
the generated build tree.
