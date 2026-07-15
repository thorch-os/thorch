#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup="${root}/scripts/configure-github-repository.sh"

"${setup}" --validate >/dev/null
grep -q '^    name: ci$' "${root}/.github/workflows/ci.yml" || {
  echo "FAIL: the required ruleset context does not match the CI job name" >&2
  exit 1
}
grep -q 'scripts/configure-github-repository.sh --check' \
  "${root}/docs/repository-settings.md" || {
  echo "FAIL: live repository-rule verification is undocumented" >&2
  exit 1
}

printf 'thorch repository ruleset checks passed\n'
