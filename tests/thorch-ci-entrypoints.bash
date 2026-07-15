#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ci="${root}/scripts/ci.sh"
doctor="${root}/scripts/doctor.sh"
workflow="${root}/.github/workflows/ci.yml"
dependabot="${root}/.github/dependabot.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "${ci}" ]] || fail "scripts/ci.sh is missing or not executable"
[[ -x "${doctor}" ]] || fail "scripts/doctor.sh is missing or not executable"
[[ -f "${workflow}" ]] || fail "pull-request CI workflow is missing"
[[ -f "${dependabot}" ]] || fail "dependency update policy is missing"

checks="$(${ci} --list)"
for check in \
  workflow-yaml \
  package-manifest-and-pkgbuild \
  shell \
  python \
  rust \
  qml \
  release-audit \
  behavioral-tests; do
  grep -qx "${check}" <<< "${checks}" || fail "make ci omits ${check}"
done

tools="$(${ci} --list-tools)"
for tool in actionlint shellcheck ruff rustfmt clippy-driver qmlformat qmllint qmlscene6 makepkg vercmp yamllint; do
  grep -qx "${tool}" <<< "${tools}" || fail "CI preflight omits ${tool}"
done

doctor_help="$(${doctor} --help)"
grep -q 'supported next command' <<< "${doctor_help}" ||
  fail "doctor help does not describe its purpose"

grep -q '^doctor:' "${root}/Makefile" || fail "Makefile has no doctor target"
grep -q '^ci:' "${root}/Makefile" || fail "Makefile has no ci target"
grep -q 'pull_request:' "${workflow}" || fail "CI does not run for pull requests"
grep -q 'THORCH_CI_REQUIRE_ROOTLESS: 1' "${workflow}" ||
  fail "CI does not enforce an unprivileged test process"

if grep -Eq 'uses: [^ ]+@v[0-9]+' "${workflow}"; then
  fail "CI workflow contains a floating major-version action"
fi
grep -q 'package-ecosystem: github-actions' "${dependabot}" ||
  fail "dependency updates do not cover GitHub Actions"
grep -q 'package-ecosystem: docker' "${dependabot}" ||
  fail "dependency updates do not cover the pinned builder base"

printf 'thorch CI entrypoint checks passed\n'
