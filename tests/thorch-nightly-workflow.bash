#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${root}/.github/workflows/nightly.yml"
docs="${root}/docs/nightly-actions.md"
makefile="${root}/Makefile"

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

grep -q 'runs-on: ubuntu-latest' "${workflow}" ||
  fail "nightly workflow is not using the GitHub-hosted Ubuntu runner"

grep -q 'THORCH_DOCKER_IMAGE: ghcr.io/${{ github.repository_owner }}/thorch-build:latest' "${workflow}" ||
  fail "nightly workflow does not use the published Thorch builder image"

grep -q 'THORCH_ROOTFS_RUNNER: chroot' "${workflow}" ||
  fail "nightly workflow does not force the chroot backend"

grep -q 'make docker-image-pull' "${workflow}" ||
  fail "nightly workflow does not pull the builder image"

grep -q 'make docker-image-build' "${workflow}" ||
  fail "nightly workflow does not fall back to building the builder image"

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

! grep -q 'self-hosted' "${workflow}" ||
  fail "nightly workflow should not require a self-hosted runner"

! grep -q 'pacman -Syu' "${workflow}" ||
  fail "nightly workflow should use the builder image instead of inline pacman installs"

printf 'thorch nightly workflow checks passed\n'
