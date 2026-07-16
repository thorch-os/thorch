#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="${root}/scripts/package-manifest.py"
builder="${root}/scripts/build-packages.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

python3 "${cli}" --repo "${root}" validate >/dev/null

build_packages=()
while IFS= read -r package; do
  build_packages+=("${package}")
done < <(python3 "${cli}" --repo "${root}" profile build)
image_packages=()
while IFS= read -r package; do
  image_packages+=("${package}")
done < <(python3 "${cli}" --repo "${root}" profile image)
release_packages=()
while IFS= read -r package; do
  release_packages+=("${package}")
done < <(python3 "${cli}" --repo "${root}" profile release)
[[ "${#build_packages[@]}" -gt 0 ]] || fail "build profile is empty"
[[ "${#image_packages[@]}" -gt 0 ]] || fail "image profile is empty"
[[ "${#release_packages[@]}" -gt 0 ]] || fail "release profile is empty"
for package in "${image_packages[@]}"; do
  [[ " ${build_packages[*]} " == *" ${package} "* ]] || \
    fail "image package is missing from the build profile: ${package}"
done
for package in "${release_packages[@]}"; do
  [[ " ${build_packages[*]} " == *" ${package} "* ]] ||
    fail "release package is missing from the build profile: ${package}"
  [[ " ${image_packages[*]} " == *" ${package} "* ]] ||
    fail "release package is not exercised by image composition: ${package}"
done
[[ " ${image_packages[*]} " == *" thorch-boot-bootstrap-ready "* ]] ||
  fail "fresh images do not contain the boot bootstrap readiness dependency"
[[ " ${release_packages[*]} " != *" thorch-boot-bootstrap-ready "* ]] ||
  fail "the locally generated bootstrap readiness marker must never be published"
for package in "${build_packages[@]}"; do
  if [[ "${package}" == thorch-boot-bootstrap-ready ]]; then
    continue
  fi
  [[ " ${release_packages[*]} " == *" ${package} "* ]] ||
    fail "ordinary package is missing from the release profile: ${package}"
done
[[ "${build_packages[0]} ${build_packages[1]} ${build_packages[2]}" == \
  "thorch-bsp thorch-boot-bootstrap-ready linux-thorch" ]] ||
  fail "boot packages are not ordered BSP, readiness marker, then kernel"

package_dirs=()
while IFS= read -r package_dir; do
  package_dirs+=("${package_dir}")
done < <(
  for package_dir in "${root}"/packages/*; do
    [[ -f "${package_dir}/PKGBUILD" ]] || continue
    printf 'packages/%s\n' "${package_dir##*/}"
  done | LC_ALL=C sort
)
manifest_dirs=()
while IFS= read -r package_dir; do
  manifest_dirs+=("${package_dir}")
done < <(
  for package in "${build_packages[@]}"; do
    python3 "${cli}" --repo "${root}" inputs "${package}" | head -n1
  done | LC_ALL=C sort
)
[[ "${package_dirs[*]}" == "${manifest_dirs[*]}" ]] || \
  fail "manifest does not cover exactly the PKGBUILD directories"

selection="$(
  python3 "${cli}" --repo "${root}" select \
    --packages thorch-gaming-installers,thorch-fex,linux-thorch --format csv
)"
[[ "${selection}" == "linux-thorch,thorch-fex-bin,thorch-gaming-installers" ]] || \
  fail "package selection was not alias-resolved and put in manifest order"

if find "${root}/packages" -type f \
    \( -name '.thorch-build-inputs' -o -name '.thorch-build-pacman-deps' \) |
    grep -q .; then
  fail "legacy sidecar package input/dependency manifests remain"
fi

srcinfo_fixture="$(mktemp -d)"
for package in "${build_packages[@]}"; do
  printf 'pkgbase = %s\n\tpkgname = %s\n' "${package}" "${package}" > \
    "${srcinfo_fixture}/${package}.SRCINFO"
done
printf '\tdepends = thorch-bsp>=1-27\n' >> \
  "${srcinfo_fixture}/thorch-boot-bootstrap-ready.SRCINFO"
python3 "${cli}" --repo "${root}" validate-dependencies \
  --srcinfo-dir "${srcinfo_fixture}" >/dev/null || \
  fail "dependency validator rejected a provider ordered before its consumer"
printf '\tmakedepends = linux-thorch\n' >> \
  "${srcinfo_fixture}/thorch-bsp.SRCINFO"
if python3 "${cli}" --repo "${root}" validate-dependencies \
    --srcinfo-dir "${srcinfo_fixture}" >"${srcinfo_fixture}/failure" 2>&1; then
  fail "dependency validator accepted a provider ordered after its consumer"
fi
grep -q 'provider linux-thorch must precede consumer' \
  "${srcinfo_fixture}/failure" || \
  fail "dependency-order failure did not identify the late provider"
rm -rf "${srcinfo_fixture}"

bad_manifest="$(mktemp)"
path_fixture_parent="${root}/build"
install -d "${path_fixture_parent}"
path_fixture="$(mktemp -d "${path_fixture_parent}/package-paths.XXXXXX")"
trap 'rm -f "${bad_manifest}"; rm -rf "${path_fixture}"' EXIT
python3 - "${root}/manifests/packages.json" "${bad_manifest}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data["packages"].append(dict(data["packages"][0]))
pathlib.Path(sys.argv[2]).write_text(json.dumps(data), encoding="utf-8")
PY
if python3 "${cli}" --repo "${root}" --manifest "${bad_manifest}" validate >/dev/null 2>&1; then
  fail "manifest validator accepted a duplicate package"
fi

assert_bad_build_input() {
  local value="$1" expected="$2"

  python3 - "${root}/manifests/packages.json" "${bad_manifest}" "${value}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data["packages"][0]["build_inputs"] = [sys.argv[3]]
pathlib.Path(sys.argv[2]).write_text(json.dumps(data), encoding="utf-8")
PY
  if python3 "${cli}" --repo "${root}" --manifest "${bad_manifest}" \
      validate >"${path_fixture}/manifest-failure" 2>&1; then
    fail "manifest validator accepted unsafe build input: ${value}"
  fi
  grep -q "${expected}" "${path_fixture}/manifest-failure" ||
    fail "unsafe build-input error was not actionable: ${value}"
}

assert_bad_build_input 'THORCH_ROCKNIX_DIR/../outside' 'traversal component'
assert_bad_build_input 'THORCH_ROCKNIX_DIR/./outside' 'traversal component'

"${builder}" --validate-input-paths --packages thorch-bsp >/dev/null ||
  fail "rootless package input-path validation rejected the default configuration"
if THORCH_ROCKNIX_DIR='../outside' \
    "${builder}" --validate-input-paths --packages thorch-bsp \
    >"${path_fixture}/config-traversal" 2>&1; then
  fail "package builder accepted a traversing configured input root"
fi
grep -q 'unsafe path component' "${path_fixture}/config-traversal" ||
  fail "configured input traversal did not produce an actionable error"
if THORCH_ROCKNIX_DIR='/tmp/outside' \
    "${builder}" --validate-input-paths --packages thorch-bsp \
    >"${path_fixture}/config-absolute" 2>&1; then
  fail "package builder accepted an absolute configured input root"
fi
grep -q 'must be repository-relative' "${path_fixture}/config-absolute" ||
  fail "absolute configured input did not produce an actionable error"
if THORCH_LOCAL_REPO_DIR='../outside' \
    "${builder}" --validate-input-paths --packages thorch-bsp \
    >"${path_fixture}/repo-traversal" 2>&1; then
  fail "package builder accepted a traversing local repository path"
fi
grep -q 'unsafe path component' "${path_fixture}/repo-traversal" ||
  fail "local repository traversal did not produce an actionable error"

outside="$(mktemp -d)"
trap 'rm -f "${bad_manifest}"; rm -rf "${path_fixture}" "${outside}"' EXIT
install -d "${path_fixture}/build/pkg-root/thorch-input"
ln -s "${outside}" "${path_fixture}/build/pkg-root/thorch-input/vendor"
if THORCH_BUILD_DIR="${path_fixture}/build" \
    "${builder}" --validate-input-paths --packages linux-thorch \
    >"${path_fixture}/destination-escape" 2>&1; then
  fail "package builder accepted a symlinked input destination outside its root"
fi
grep -q 'package input destination escapes' "${path_fixture}/destination-escape" ||
  fail "canonical destination escape did not produce an actionable error"

printf 'thorch package manifest checks passed\n'
