#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

root="$(repo_root)"
failures=0
warnings=0

note() {
  printf '==> %s\n' "$*"
}

warn_audit() {
  printf 'warning: %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

fail_audit() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

require_file() {
  local rel="$1"
  [[ -f "${root}/${rel}" ]] || fail_audit "missing required release file: ${rel}"
}

first_text_line() {
  LC_ALL=C sed -n '1p' "$1" 2>/dev/null | tr -d '\000'
}

source_files() {
  if [[ -d "${root}/.git" ]]; then
    (
      cd "${root}"
      git ls-files --cached --others --exclude-standard
    ) | sed "s#^#${root}/#" | sort
    return
  fi

  find "${root}" \
    \( -path "${root}/.git" \
    -o -path "${root}/build" \
    -o -path "${root}/cache" \
    -o -path "${root}/output" \
    -o -path "${root}/local" \
    -o -path "${root}/vendor/rocknix-kernel" \
    -o -path "${root}/vendor/rocknix-runtime" \
    -o -path "${root}/vendor/rocknix-sm8550" \
    -o -path "${root}/packages/*/build" \
    -o -path "${root}/packages/*/pkg" \
    -o -path "${root}/packages/*/src" \) -prune \
    -o -type f \
    ! -name '*.pkg.tar.*' \
    ! -name '*.img' \
    ! -name '*.img.gz' \
    ! -name '*.img.xz' \
    ! -name '*.img.zst' \
    ! -name 'linux-*.tar.*' \
    -print | sort
}

is_git_ignored_untracked() {
  local rel="$1"

  [[ -d "${root}/.git" ]] || return 1
  (
    cd "${root}"
    if git ls-files --error-unmatch -- "${rel}" >/dev/null 2>&1; then
      exit 1
    fi
    git check-ignore -q -- "${rel}"
  )
}

note "checking release metadata"
for rel in LICENSE NOTICE.md README.md CONTRIBUTING.md SECURITY.md docs/release-checklist.md .gitignore .gitattributes; do
  require_file "${rel}"
done

if [[ ! -d "${root}/.git" ]]; then
  warn_audit "this folder is not currently a git repository"
fi

note "checking generated artifacts are outside the publishable tree"
artifact_paths=()
declare -A seen_artifacts=()
for rel in \
  build \
  cache \
  output \
  local \
  vendor/rocknix-kernel \
  vendor/rocknix-runtime \
  vendor/rocknix-sm8550 \
  packages/linux-thorch/linux-*.tar.* \
  packages/*/*.pkg.tar.* \
  packages/*/build \
  packages/*/pkg \
  packages/*/src; do
  for path in "${root}"/${rel}; do
	    [[ -e "${path}" ]] || continue
	    rel_path="${path#${root}/}"
	    is_git_ignored_untracked "${rel_path}" && continue
	    [[ -z "${seen_artifacts[${rel_path}]:-}" ]] || continue
    seen_artifacts["${rel_path}"]=1
    artifact_paths+=("${rel_path}")
  done
done

if [[ "${#artifact_paths[@]}" -gt 0 ]]; then
  printf 'generated/local artifacts still present:\n' >&2
  printf '  %s\n' "${artifact_paths[@]}" >&2
  fail_audit "remove or move generated artifacts before publishing"
fi

note "checking for secret-shaped source files"
secret_files=()
while IFS= read -r file; do
  secret_files+=("${file#${root}/}")
done < <(
  source_files |
    grep -v '/scripts/audit-release\.sh$' |
    xargs -r grep -IlE 'BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|ghp_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}' 2>/dev/null || true
)
if [[ "${#secret_files[@]}" -gt 0 ]]; then
  printf 'secret-shaped content found in:\n' >&2
  printf '  %s\n' "${secret_files[@]}" >&2
  fail_audit "remove secret material from source files"
fi

note "checking shell syntax"
while IFS= read -r file; do
  rel="${file#${root}/}"
  first_line="$(first_text_line "${file}")"
  if [[ "${rel}" == "config/thorch.conf" ||
    "${rel}" == */PKGBUILD ||
    "${first_line}" == '#!'*bash* ||
    "${first_line}" == '#!'*'/bin/sh'* ||
    "${first_line}" == '#!'*'env sh'* ||
    "${first_line}" == *'hint/bash'* ]]; then
    bash -n "${file}" || fail_audit "shell syntax failed: ${rel}"
  fi
done < <(source_files)

note "checking executable bits"
while IFS= read -r file; do
  rel="${file#${root}/}"
  first_line="$(first_text_line "${file}")"
  if [[ "${first_line}" == '#!'* && ! -x "${file}" ]]; then
    fail_audit "shebang file is not executable: ${rel}"
  fi
done < <(source_files)

note "checking Python syntax"
while IFS= read -r file; do
  rel="${file#${root}/}"
  first_line="$(first_text_line "${file}")"
  case "${first_line}" in
    *python*)
      python3 - "${file}" <<'PY' || fail_audit "python syntax failed: ${rel}"
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY
      ;;
  esac
done < <(source_files)

note "checking desktop entries"
if command -v desktop-file-validate >/dev/null 2>&1; then
  while IFS= read -r file; do
    desktop-file-validate "${file}" || fail_audit "desktop validation failed: ${file#${root}/}"
  done < <(source_files | grep -E '\.desktop$' || true)
else
  warn_audit "desktop-file-validate is not installed"
fi

if [[ "${failures}" -ne 0 ]]; then
  printf 'release audit failed: %d failure(s), %d warning(s)\n' "${failures}" "${warnings}" >&2
  exit 1
fi

printf 'release audit passed: %d warning(s)\n' "${warnings}"
