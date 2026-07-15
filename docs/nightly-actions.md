# Nightly GitHub Actions Builds

The nightly workflow builds a full Thorch image on a GitHub-hosted Ubuntu
runner by using the same Docker builder entry points that local developers use.
It publishes the compressed image as a GitHub prerelease asset.
No self-hosted Arch runner is required.

The builder image is defined by `Dockerfile`. Default-branch runs of
`.github/workflows/builder-image.yml` publish a convenience `latest` tag, a
full commit-SHA tag, and report the resulting content digest. The nightly never
uses the moving tags: it pulls the reviewed digest recorded in its workflow,
for example:

```text
ghcr.io/<owner>/thorch-build@sha256:<64-hex-digest>
```

Pull requests build the image without pushing it, so Dockerfile changes are
validated before merge. The Dockerfile also pins its Arch base image by digest.
After a reviewed builder change lands, copy the new digest from the Builder
Image job summary into `THORCH_BUILDER_DIGEST` and `THORCH_DOCKER_IMAGE` in the
nightly workflow, then verify that exact digest can be pulled before relying on
it for a release.

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
The workflow emits that exact check if its authenticated pull is denied.

An earlier anonymous and nightly pull was denied, but that result alone did not
identify whether package visibility, linkage, Actions access, or the missing
workflow permission was responsible. The workflow change corrects the missing
`packages: read` permission. A package administrator must inspect the remaining
GHCR settings rather than infer them from the denial. If anonymous contributor
pulls are intended, the administrator can make the package public; GitHub warns
that this visibility change cannot be reversed. Until that setting is verified,
contributors can either authenticate with package read access or build the
pinned Dockerfile locally.

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

`make test` includes a real Linux integration fixture that creates a small GPT
image with FAT and ext4 partitions, attaches it through a loop device, and runs
the same read-only mount path as the ROCKNIX import. It also probes an
unformatted image and requires the actual `mount(8)` error to remain visible.
The nightly sets `THORCH_REQUIRE_MOUNT_INTEGRATION=1` inside its privileged
builder so an unsupported or skipped fixture fails the job.

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
root filesystem, immutable builder digest, and kernel provenance copied from
the generated build tree.
