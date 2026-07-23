#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${root}/.github/workflows/nightly.yml"
docs="${root}/docs/nightly-actions.md"
makefile="${root}/Makefile"
mount_script="${root}/scripts/sync-rocknix-kernel.sh"
mount_test="${root}/tests/thorch-rocknix-mount-integration.bash"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "${workflow}" ]] || fail "nightly workflow is missing"
[[ -f "${docs}" ]] || fail "nightly workflow docs are missing"

grep -q 'cron: "37 13 \* \* \*"' "${workflow}" ||
  fail "nightly workflow does not have the expected daily schedule"

grep -q 'contents: write' "${workflow}" ||
  fail "nightly workflow cannot publish releases"

grep -q 'packages: read' "${workflow}" ||
  fail "nightly workflow cannot authenticate to its GHCR builder"

grep -q 'runs-on: ubuntu-24.04-arm' "${workflow}" ||
  fail "nightly workflow is not using GitHub's native ARM64 runner"

! grep -q 'docker/setup-qemu-action' "${workflow}" ||
  fail "native ARM64 nightly still registers CPU emulation"

grep -Eq 'THORCH_DOCKER_IMAGE: ghcr.io/[$][{][{] github[.]repository_owner [}][}]/thorch-build@sha256:[0-9a-f]{64}$' "${workflow}" ||
  fail "nightly workflow does not pin the published Thorch builder by digest"

grep -Eq 'THORCH_BUILDER_DIGEST: sha256:[0-9a-f]{64}$' "${workflow}" ||
  fail "nightly workflow does not record the expected builder digest"

grep -q 'THORCH_REQUIRE_MOUNT_INTEGRATION=1' "${workflow}" ||
  fail "nightly workflow permits its real mount integration test to skip"

grep -q 'THORCH_ROOTFS_RUNNER: chroot' "${workflow}" ||
  fail "nightly workflow does not force the chroot backend"

grep -q 'make docker-image-pull' "${workflow}" ||
  fail "nightly workflow does not pull the builder image"

! grep -q 'make docker-image-build' "${workflow}" ||
  fail "nightly workflow can silently replace its pinned builder with a local build"

grep -q 'make docker-nightly' "${workflow}" ||
  fail "nightly workflow does not use the Docker nightly target"

grep -q 'run --privileged' "${makefile}" ||
  fail "Docker wrapper does not use a privileged builder container"

grep -q 'check IMAGE=' "${makefile}" ||
  fail "nightly make target does not validate the image before release"

grep -q 'gh release create' "${workflow}" ||
  fail "nightly workflow does not create GitHub releases"

grep -q 'sha256sum "$(basename "${asset}")"' "${workflow}" ||
  fail "nightly checksum does not use the downloadable asset basename"

grep -q 'GitHub-hosted Ubuntu' "${docs}" ||
  fail "nightly docs do not describe the hosted runner"

[[ -x "${mount_test}" ]] || fail "partitioned-image mount integration test is missing or not executable"
grep -q -- '--mount-probe-image' "${mount_test}" ||
  fail "partitioned-image integration test does not exercise the production mount path"
grep -q 'mount -v -o ro' "${mount_script}" ||
  fail "ROCKNIX partition mount still suppresses mount diagnostics"
grep -q 'ROCKNIX block topology' "${mount_script}" ||
  fail "ROCKNIX partition mount does not log lsblk topology"
grep -q 'blkid path=' "${mount_script}" ||
  fail "ROCKNIX partition mount does not log blkid output"
grep -q 'device-node path=' "${mount_script}" ||
  fail "ROCKNIX partition mount does not log device metadata"

if grep -Eq 'uses: [^ ]+@v[0-9]+' "${workflow}"; then
  fail "nightly workflow contains a floating major-version action"
fi

! grep -q 'self-hosted' "${workflow}" ||
  fail "nightly workflow should not require a self-hosted runner"

! grep -q 'pacman -Syu' "${workflow}" ||
  fail "nightly workflow should use the builder image instead of inline pacman installs"

printf 'thorch nightly workflow checks passed\n'
