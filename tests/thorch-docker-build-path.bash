#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
makefile="${root}/Makefile"
dockerfile="${root}/Dockerfile"
dockerignore="${root}/.dockerignore"
builder_workflow="${root}/.github/workflows/builder-image.yml"
build_docs="${root}/docs/build.md"
nightly_docs="${root}/docs/nightly-actions.md"
ownership_script="${root}/scripts/fix-container-ownership.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "${dockerfile}" ]] || fail "Dockerfile is missing"
[[ -f "${dockerignore}" ]] || fail ".dockerignore is missing"
[[ -f "${builder_workflow}" ]] || fail "builder image workflow is missing"
[[ -x "${ownership_script}" ]] || fail "container ownership repair script is missing or not executable"

grep -Eq '^FROM archlinux:base-devel@sha256:[0-9a-f]{64}$' "${dockerfile}" ||
  fail "builder image does not pin its archlinux:base-devel digest"

grep -q 'qemu-user-static' "${dockerfile}" ||
  fail "builder image does not include qemu-user-static"

grep -q 'DisableSandbox' "${dockerfile}" ||
  fail "builder image does not support pacman under amd64-on-arm64 emulation"

grep -q 'THORCH_DOCKER_IMAGE ?= ghcr.io/thorch-os/thorch-build:latest' "${makefile}" ||
  fail "Makefile does not define the default Thorch builder image"

grep -q '^docker-%:' "${makefile}" ||
  fail "Makefile does not provide ROCKNIX-style docker-* targets"

grep -q '^docker-shell:' "${makefile}" ||
  fail "Makefile does not provide docker-shell"

grep -q '^docker-image-build:' "${makefile}" ||
  fail "Makefile does not provide docker-image-build"

grep -q '^docker-image-pull:' "${makefile}" ||
  fail "Makefile does not provide docker-image-pull"

grep -q -- '--security-opt label=disable' "${makefile}" ||
  fail "Docker wrapper does not disable SELinux relabeling"

grep -q 'docker-audit docker-check docker-test docker-test-rust: THORCH_DOCKER_FIX_OWNERSHIP=0' "${makefile}" ||
  fail "read-only Docker targets still repair the complete workspace ownership"

grep -q './scripts/fix-container-ownership.sh' "${makefile}" ||
  fail "Docker wrapper does not use the selective ownership repair script"

if (( EUID == 0 )); then
  ownership_fixture="$(mktemp -d)"
  trap 'rm -rf "${ownership_fixture}"' EXIT
  mkdir -p \
    "${ownership_fixture}/build/image-rootfs/etc" \
    "${ownership_fixture}/build/pkg-root/etc" \
    "${ownership_fixture}/build/cache" \
    "${ownership_fixture}/output" \
    "${ownership_fixture}/vendor"
  chown -R 0:0 "${ownership_fixture}"

  "${ownership_script}" 1234 1235 "${ownership_fixture}"

  [[ "$(stat -c '%u:%g' "${ownership_fixture}/build/image-rootfs/etc")" == 0:0 ]] ||
    fail "container ownership repair changed image-rootfs metadata"
  [[ "$(stat -c '%u:%g' "${ownership_fixture}/build/pkg-root/etc")" == 0:0 ]] ||
    fail "container ownership repair changed pkg-root metadata"
  [[ "$(stat -c '%u:%g' "${ownership_fixture}/build/cache")" == 1234:1235 ]] ||
    fail "container ownership repair did not repair ordinary build artifacts"
  [[ "$(stat -c '%u:%g' "${ownership_fixture}/output")" == 1234:1235 ]] ||
    fail "container ownership repair did not repair output artifacts"
  [[ "$(stat -c '%u:%g' "${ownership_fixture}/vendor")" == 1234:1235 ]] ||
    fail "container ownership repair did not repair vendor artifacts"
fi

grep -q 'docker/build-push-action' "${builder_workflow}" ||
  fail "builder workflow does not publish with docker/build-push-action"

if grep -Eq 'uses: [^ ]+@v[0-9]+' "${builder_workflow}"; then
  fail "builder workflow contains a floating major-version action"
fi

grep -q 'type=sha,format=long' "${builder_workflow}" ||
  fail "builder workflow does not publish a full commit-SHA tag"

grep -q 'steps.build.outputs.digest' "${builder_workflow}" ||
  fail "builder workflow does not report its immutable digest"

grep -q 'packages: write' "${builder_workflow}" ||
  fail "builder workflow cannot publish to GHCR"

grep -q 'make docker-<target>' "${build_docs}" ||
  fail "build docs do not describe docker-* targets"

grep -q 'make docker-nightly' "${nightly_docs}" ||
  fail "nightly docs do not describe the Docker nightly path"

printf 'thorch Docker build path checks passed\n'
