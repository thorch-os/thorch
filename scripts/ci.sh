#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/ci.sh [--list | --list-tools]

Run the rootless checks required by the pull-request CI workflow.

Environment:
  THORCH_CI_BASE_REF        Git commit/ref used for changed-file and package-version checks.
  THORCH_CI_REQUIRE_ROOTLESS=1
                            Fail if the checks are running as uid 0.
EOF
}

list_tools() {
  cat <<'EOF'
actionlint
bash
bsdtar
cargo
clippy-driver
desktop-file-validate
dtc
fakechroot
fakeroot
git
gpg
gpgv
make
makepkg
mkbootimg
pacman
python3
qmlformat
qmllint
qmlscene6
ruff
rsync
rustc
rustfmt
shellcheck
timeout
repo-add
vercmp
yamllint
EOF
}

list_checks() {
  cat <<'EOF'
workflow-yaml
package-manifest-and-pkgbuild
shell
python
rust
qml
release-audit
behavioral-tests
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    list_checks
    exit 0
    ;;
  --list-tools)
    list_tools
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'error: make ci requires Bash 4 or newer; found %s\n' "${BASH_VERSION}" >&2
  printf 'Run make doctor for the supported environment and missing-tool report.\n' >&2
  exit 2
fi

note() {
  printf '\n==> CI: %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

missing=()
while IFS= read -r tool; do
  command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done < <(list_tools)
if (( ${#missing[@]} > 0 )); then
  printf 'error: make ci is missing required tools:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  printf 'Run make doctor for host-specific guidance.\n' >&2
  exit 2
fi

if [[ "${THORCH_CI_REQUIRE_ROOTLESS:-0}" == "1" && "${EUID}" -eq 0 ]]; then
  die "fast CI must run without root privileges"
fi

cd "${root}"

source_files() {
  local file
  while IFS= read -r file; do
    [[ -f "${file}" ]] && printf '%s\n' "${file}"
  done < <(git ls-files --cached --others --exclude-standard)
}

base_ref="${THORCH_CI_BASE_REF:-}"
if [[ -n "${base_ref}" && "${base_ref}" != "0000000000000000000000000000000000000000" ]] &&
    git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
  comparison_base="$(git merge-base HEAD "${base_ref}")"
else
  comparison_base=""
fi

changed_files() {
  if [[ -n "${comparison_base}" ]]; then
    git diff --name-only --diff-filter=ACMR "${comparison_base}" --
  else
    git diff --name-only --diff-filter=ACMR HEAD --
  fi
  git ls-files --others --exclude-standard
}

note "workflow and YAML validation"
mapfile -t workflow_files < <(
  source_files | grep -E '^\.github/workflows/[^/]+\.ya?ml$' || true
)
(( ${#workflow_files[@]} > 0 )) || die "no GitHub Actions workflows found"
# Workflow release-note snippets intentionally use single-quoted printf
# formats. They are literal strings, so SC2016 is not actionable there.
actionlint -shellcheck 'shellcheck --exclude=SC2016' "${workflow_files[@]}"

mapfile -t yaml_files < <(source_files | grep -E '\.ya?ml$' || true)
if (( ${#yaml_files[@]} > 0 )); then
  yamllint \
    -d '{extends: default, rules: {comments: {min-spaces-from-content: 1}, document-start: disable, line-length: {max: 200}, truthy: disable}}' \
    "${yaml_files[@]}"
fi
scripts/configure-github-repository.sh --validate >/dev/null

note "package manifest and PKGBUILD metadata"
if [[ -f scripts/package-manifest.py ]]; then
  python3 scripts/package-manifest.py validate
fi

mapfile -t pkgbuilds < <(source_files | grep -E '^packages/[^/]+/PKGBUILD$' || true)
(( ${#pkgbuilds[@]} > 0 )) || die "no package recipes found"
srcinfo_tmp="$(mktemp -d)"
trap 'rm -rf "${srcinfo_tmp}"' EXIT
for pkgbuild in "${pkgbuilds[@]}"; do
  package="$(basename "$(dirname "${pkgbuild}")")"
  (
    cd "$(dirname "${pkgbuild}")"
    makepkg --printsrcinfo
  ) > "${srcinfo_tmp}/${package}.SRCINFO"
done
python3 scripts/package-manifest.py validate-dependencies \
  --srcinfo-dir "${srcinfo_tmp}"
rm -rf "${srcinfo_tmp}"
trap - EXIT

if [[ -f scripts/check-package-versions.py ]]; then
  if [[ -n "${comparison_base}" ]]; then
    python3 scripts/check-package-versions.py --base-ref "${comparison_base}"
  else
    printf 'package-version: no valid THORCH_CI_BASE_REF; monotonic comparison skipped\n'
  fi
fi

note "ShellCheck"
shell_files=()
shell_without_shebang=()
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  first_line="$(LC_ALL=C sed -n '1p' "${file}" 2>/dev/null | tr -d '\000')"
  case "${file}" in
    */PKGBUILD|*.install|config/thorch.conf)
      shell_without_shebang+=("${file}")
      ;;
    *.bash|*.sh)
      shell_files+=("${file}")
      ;;
    *)
      if [[ "${first_line}" == '#!'*bash* || "${first_line}" == '#!'*'/bin/sh'* ||
        "${first_line}" == '#!'*'env sh'* || "${first_line}" == *'hint/bash'* ]]; then
        shell_files+=("${file}")
      fi
      ;;
  esac
done < <(source_files)

(( ${#shell_files[@]} > 0 )) && shellcheck --severity=error -- "${shell_files[@]}"
(( ${#shell_without_shebang[@]} > 0 )) &&
  shellcheck --shell=bash --severity=error -- "${shell_without_shebang[@]}"

note "Python compile and focused lint"
python_files=()
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  first_line="$(LC_ALL=C sed -n '1p' "${file}" 2>/dev/null | tr -d '\000')"
  if [[ "${file}" == *.py || "${first_line}" == '#!'*python* ]]; then
    python_files+=("${file}")
  fi
done < <(source_files)

for file in "${python_files[@]}"; do
  python3 - "${file}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
compile(path.read_bytes(), str(path), "exec")
PY
  ruff check --no-cache --select E9,F63,F7,F82 --stdin-filename "${file}" - < "${file}"
done

note "Rust formatting, Clippy, and tests"
mapfile -t cargo_manifests < <(source_files | grep -E '(^|/)Cargo\.toml$' || true)
if (( ${#cargo_manifests[@]} > 0 )); then
  for manifest in "${cargo_manifests[@]}"; do
    manifest_dir="$(dirname "${manifest}")"
    (
      cd "${manifest_dir}"
      cargo fmt --all --check
      cargo clippy --all-targets --all-features -- -D warnings
      cargo test --all-targets --all-features
    )
  done
else
  mapfile -t rust_files < <(source_files | grep -E '\.rs$' || true)
  mapfile -t changed_rust < <(changed_files | grep -E '\.rs$' || true)
  if (( ${#changed_rust[@]} > 0 )); then
    rustfmt --edition 2021 --check "${changed_rust[@]}"
  else
    printf 'rustfmt: no changed standalone Rust sources\n'
  fi

  rust_tmp="$(mktemp -d)"
  trap 'rm -rf "${rust_tmp}"' EXIT
  for file in "${rust_files[@]}"; do
    # The current standalone component predates Cargo. Run Clippy for every
    # source, but introduce warning-as-error together with its Cargo migration.
    clippy-driver --edition=2021 -W clippy::all "${file}" -o "${rust_tmp}/$(basename "${file}" .rs)"
  done
  scripts/test-rust-components.sh
  rm -rf "${rust_tmp}"
  trap - EXIT
fi

note "QML syntax, formatter, linter, and smoke prerequisites"
mapfile -t qml_files < <(source_files | grep -E '\.qml$' || true)
mapfile -t changed_qml < <(changed_files | grep -E '\.qml$' || true)
qml_tmp="$(mktemp -d)"
trap 'rm -rf "${qml_tmp}"' EXIT
for file in "${qml_files[@]}"; do
  qmlformat "${file}" > "${qml_tmp}/formatted.qml"
done
for file in "${changed_qml[@]}"; do
  qmlformat "${file}" > "${qml_tmp}/formatted.qml"
  cmp -s "${file}" "${qml_tmp}/formatted.qml" ||
    die "QML is not qmlformat-clean: ${file}"
done
cat > "${qml_tmp}/LintProbe.qml" <<'QML'
import QtQuick

Item {}
QML
qmllint "${qml_tmp}/LintProbe.qml"
rm -rf "${qml_tmp}"
trap - EXIT

note "release audit"
scripts/audit-release.sh

note "behavioral tests"
THORCH_REQUIRE_QML_SMOKE=1 make test

printf '\nAll rootless CI checks passed.\n'
