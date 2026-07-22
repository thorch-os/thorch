#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf 'SKIP: package repository retention requires GNU/Linux tools\n'
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${root}/scripts/archive-package-repo.sh"
work="$(mktemp -d)"
repo="${work}/repo"
archives="${work}/archives"
trap 'rm -rf "${work}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

install -d "${repo}/.thorch-inputs"
printf 'database generation one\n' > "${repo}/thorch.db.tar.gz"
ln -s thorch.db.tar.gz "${repo}/thorch.db"
printf 'package generation one\n' > "${repo}/fixture-1-1-any.pkg.tar.zst"
printf 'developer fingerprint only\n' > "${repo}/.thorch-inputs/fixture.sha256"

first="$("${tool}" "${repo}" "${archives}")"
[[ -d "${first}" ]] || fail "first repository archive was not created"
(cd "${first}" && sha256sum -c SHA256SUMS >/dev/null) ||
  fail "first repository archive failed its integrity inventory"
[[ -f "${first}/thorch.db" && ! -L "${first}/thorch.db" ]] ||
  fail "database alias was not made self-contained"
[[ ! -e "${first}/.thorch-inputs" ]] ||
  fail "developer input fingerprints leaked into repository bytes"
[[ "$("${tool}" "${repo}" "${archives}")" == "${first}" ]] ||
  fail "identical repository bytes did not reuse their content identity"

cp "${repo}/fixture-1-1-any.pkg.tar.zst" "${work}/saved-package"
printf 'tampered\n' >> "${repo}/fixture-1-1-any.pkg.tar.zst"
if "${tool}" "${repo}" "${archives}" >/dev/null 2>&1; then
  fail "archive accepted changed package bytes under the same database identity"
fi
cp "${work}/saved-package" "${repo}/fixture-1-1-any.pkg.tar.zst"

printf 'database generation two\n' > "${repo}/thorch.db.tar.gz"
second="$("${tool}" "${repo}" "${archives}")"
[[ "${second}" != "${first}" && -d "${second}" ]] ||
  fail "new database bytes did not create a new retained archive"
[[ "$(find "${archives}" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]] ||
  fail "repository retention did not preserve both generations"

printf 'thorch local package repository retention checks passed\n'
