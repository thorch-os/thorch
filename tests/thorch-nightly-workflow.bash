#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${root}/.github/workflows/nightly.yml"
docs="${root}/docs/nightly-actions.md"
config="${root}/config/thorch.conf"
makefile="${root}/Makefile"
mount_script="${root}/scripts/sync-rocknix-kernel.sh"
mount_test="${root}/tests/thorch-rocknix-mount-integration.bash"
manifest_script="${root}/scripts/create-nightly-build-manifest.sh"
build_gate="${root}/scripts/nightly-build-needed.sh"

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

grep -q 'source config/thorch.conf' "${workflow}" ||
  fail "nightly workflow does not load the committed ROCKNIX pins"

grep -q 'ROCKNIX_REF must be a full committed SHA' "${workflow}" ||
  fail "nightly workflow does not reject a rolling ROCKNIX source ref"

grep -q 'ROCKNIX_KERNEL_RELEASE must be a dated nightly tag' "${workflow}" ||
  fail "nightly workflow does not reject a rolling ROCKNIX kernel release"

! grep -q 'rocknix_ref:' "${workflow}" ||
  fail "nightly workflow still exposes an uncommitted ROCKNIX source override"

! grep -q 'rocknix_kernel_release:' "${workflow}" ||
  fail "nightly workflow still exposes an uncommitted ROCKNIX release override"

rocknix_ref_default="$(
  sed -n 's/^ROCKNIX_REF=.*:-\([^}]*\)}.*$/\1/p' "${config}"
)"
[[ "${rocknix_ref_default}" =~ ^[0-9a-f]{40}$ ]] ||
  fail "default ROCKNIX source is not pinned to a full commit SHA"

rocknix_release_default="$(
  sed -n 's/^ROCKNIX_KERNEL_RELEASE=.*:-\([^}]*\)}.*$/\1/p' "${config}"
)"
[[ "${rocknix_release_default}" =~ ^nightly-[0-9]{8}$ ]] ||
  fail "default ROCKNIX kernel image is not pinned to a dated nightly tag"

grep -q 'run --privileged' "${makefile}" ||
  fail "Docker wrapper does not use a privileged builder container"

grep -q 'check IMAGE=' "${makefile}" ||
  fail "nightly make target does not validate the image before release"

grep -q 'gh release create' "${workflow}" ||
  fail "nightly workflow does not create GitHub releases"

grep -q 'group: thorch-nightly-publisher' "${workflow}" ||
  fail "nightly workflow does not serialize all release publishers"

! grep -q 'group: thorch-nightly-${{ github.ref }}' "${workflow}" ||
  fail "nightly workflow still permits cross-ref release races"

[[ -x "${manifest_script}" ]] ||
  fail "nightly build manifest generator is missing or not executable"

[[ -x "${build_gate}" ]] ||
  fail "nightly Thorch commit gate is missing or not executable"

grep -q 'create-nightly-build-manifest.sh' "${workflow}" ||
  fail "nightly workflow does not create a semantic build manifest"

grep -q './scripts/nightly-build-needed.sh "${GITHUB_SHA}" "${previous}"' "${workflow}" ||
  fail "nightly workflow does not compare the Thorch commit before building"

grep -q 'skipping the build and release' "${workflow}" ||
  fail "nightly workflow does not report an already-published Thorch commit"

! grep -q 'cmp -s "${previous}" "${manifest}"' "${workflow}" ||
  fail "nightly workflow still lets external build-input changes trigger a release"

preflight_line="$(grep -n -m1 'name: Check for an unpublished Thorch commit' "${workflow}" | cut -d: -f1)"
build_line="$(grep -n -m1 'make docker-nightly' "${workflow}" | cut -d: -f1)"
[[ -n "${preflight_line}" && -n "${build_line}" && "${preflight_line}" -lt "${build_line}" ]] ||
  fail "nightly workflow does not check the Thorch commit before building"

grep -q '"${GITHUB_REF}"' "${workflow}" ||
  fail "nightly release namespace does not isolate workflow refs"

grep -q 'printf '\''config=%s\\n'\'' "${config}"' "${workflow}" ||
  fail "nightly workflow does not expose its release configuration key"

grep -q 'config="${{ steps.changes.outputs.config }}"' "${workflow}" ||
  fail "nightly metadata does not consume the release configuration key"

grep -q 'tag="nightly-${build_date}-${config}"' "${workflow}" ||
  fail "nightly release tag is not scoped to its build configuration"

! grep -q 'tag="nightly-${build_date}"' "${workflow}" ||
  fail "nightly release tag can still collide across configurations"

grep -q 'git tag --force "${tag}" "${GITHUB_SHA}"' "${workflow}" ||
  fail "same-day nightly updates do not move the date tag to the new commit"

grep -q 'git push --force origin "refs/tags/${tag}"' "${workflow}" ||
  fail "same-day nightly tag updates are not pushed"

grep -q "steps.changes.outputs.changed == 'true'" "${workflow}" ||
  fail "nightly workflow does not gate build and publication on a new Thorch commit"

grep -q 'releases/assets/${previous_asset_id}' "${workflow}" ||
  fail "nightly workflow does not download the previous build manifest"

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
