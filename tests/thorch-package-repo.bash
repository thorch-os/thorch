#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${root}/scripts/check-package-repo.py"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_package() {
  local name="$1" path="$2" dependency="${3:-bash}" tree
  tree="${fixture}/tree-${name}"
  rm -rf "${tree}"
  mkdir -p "${tree}/$(dirname "${path}")"
  cat > "${tree}/.PKGINFO" <<EOF
pkgname = ${name}
pkgver = 1-1
arch = any
depend = ${dependency}
EOF
  printf '%s\n' "${name}" > "${tree}/${path}"
  bsdtar -cf "${fixture}/${name}-1-1-any.pkg.tar.xz" -C "${tree}" .PKGINFO "${path}"
}

make_package alpha usr/bin/alpha
make_package beta usr/bin/beta
python3 "${checker}" "${fixture}" --require alpha beta >/dev/null
ln -s "${fixture}/outside-package" \
  "${fixture}/symlink-1-1-any.pkg.tar.xz"
if python3 "${checker}" "${fixture}" \
    >/dev/null 2>"${fixture}/archive-symlink-failure"; then
  fail "repository validator accepted a symlinked package archive"
fi
grep -q 'package archive is not a regular file' \
  "${fixture}/archive-symlink-failure" ||
  fail "package archive symlink failure was not actionable"
rm -f "${fixture}/symlink-1-1-any.pkg.tar.xz"

write_binding() {
  local repo="$1" artifact="$2" inputs_sha256="$3" artifact_sha256

  artifact_sha256="$(sha256sum "${repo}/${artifact}" | awk '{print $1}')"
  install -d "${repo}/.thorch-inputs"
  cat > "${repo}/.thorch-inputs/${artifact}.json" <<EOF
{
  "schema_version": 1,
  "artifact": "${artifact}",
  "artifact_sha256": "${artifact_sha256}",
  "inputs_sha256": "${inputs_sha256}"
}
EOF
}

# This fixture is deliberately rootless: it proves a cache no-op is accepted
# only when both its declared inputs and exact artifact bytes remain bound.
cache_repo="${fixture}/cache-repo"
install -d "${cache_repo}"
cp "${fixture}/alpha-1-1-any.pkg.tar.xz" "${cache_repo}/"
cp "${fixture}/beta-1-1-any.pkg.tar.xz" "${cache_repo}/"
inputs_sha256="$(printf 'fixture inputs\n' | sha256sum | awk '{print $1}')"
write_binding "${cache_repo}" alpha-1-1-any.pkg.tar.xz "${inputs_sha256}"
write_binding "${cache_repo}" beta-1-1-any.pkg.tar.xz "${inputs_sha256}"
python3 "${checker}" "${cache_repo}" \
  --bindings-root "${cache_repo}/.thorch-inputs" --require alpha beta >/dev/null ||
  fail "repository validator rejected valid artifact bindings"
python3 "${checker}" "${cache_repo}" \
  --candidate "${cache_repo}/alpha-1-1-any.pkg.tar.xz" \
  --binding "${cache_repo}/.thorch-inputs/alpha-1-1-any.pkg.tar.xz.json" \
  --expected-input-sha256 "${inputs_sha256}" >/dev/null ||
  fail "repository validator rejected a bound no-op reuse"
wrong_inputs_sha256="$(printf 'changed inputs\n' | sha256sum | awk '{print $1}')"
if python3 "${checker}" "${cache_repo}" \
    --candidate "${cache_repo}/alpha-1-1-any.pkg.tar.xz" \
    --binding "${cache_repo}/.thorch-inputs/alpha-1-1-any.pkg.tar.xz.json" \
    --expected-input-sha256 "${wrong_inputs_sha256}" \
    >/dev/null 2>"${fixture}/changed-input-failure"; then
  fail "repository validator reused a package after its declared inputs changed"
fi
grep -q 'declared inputs changed' "${fixture}/changed-input-failure" ||
  fail "changed-input failure did not identify the stale binding"

cp "${cache_repo}/alpha-1-1-any.pkg.tar.xz" "${fixture}/alpha-cache-backup"
printf 'tampered package bytes\n' >> "${cache_repo}/alpha-1-1-any.pkg.tar.xz"
if python3 "${checker}" "${cache_repo}" \
    --bindings-root "${cache_repo}/.thorch-inputs" \
    >/dev/null 2>"${fixture}/binding-tamper-failure"; then
  fail "repository validator accepted artifact bytes changed after binding"
fi
grep -q 'artifact digest does not match' "${fixture}/binding-tamper-failure" ||
  fail "artifact-tamper failure did not identify the broken binding"
mv "${fixture}/alpha-cache-backup" "${cache_repo}/alpha-1-1-any.pkg.tar.xz"

mv "${cache_repo}/.thorch-inputs/beta-1-1-any.pkg.tar.xz.json" \
  "${fixture}/beta-binding-backup"
printf '%s\n' "${inputs_sha256}" > \
  "${cache_repo}/.thorch-inputs/beta-1-1-any.pkg.tar.xz.sha256"
if python3 "${checker}" "${cache_repo}" \
    --bindings-root "${cache_repo}/.thorch-inputs" \
    >/dev/null 2>"${fixture}/legacy-binding-failure"; then
  fail "repository validator accepted a legacy input-only sidecar"
fi
grep -q 'not a regular file' "${fixture}/legacy-binding-failure" ||
  fail "legacy-sidecar failure did not identify the missing artifact binding"
mv "${fixture}/beta-binding-backup" \
  "${cache_repo}/.thorch-inputs/beta-1-1-any.pkg.tar.xz.json"

install -d "${fixture}/candidates" "${fixture}/candidate-tree/usr/bin"
cp "${fixture}/alpha-1-1-any.pkg.tar.xz" \
  "${fixture}/candidates/alpha-exact.pkg.tar.xz"
python3 "${checker}" "${fixture}" \
  --candidate "${fixture}/candidates/alpha-exact.pkg.tar.xz" >/dev/null ||
  fail "repository validator rejected an exact-byte candidate"
cat > "${fixture}/candidate-tree/.PKGINFO" <<'EOF'
pkgname = alpha
pkgver = 1-1
arch = any
depend = bash
EOF
printf 'different bytes\n' > "${fixture}/candidate-tree/usr/bin/alpha"
bsdtar -cf "${fixture}/candidates/alpha-different.pkg.tar.xz" \
  -C "${fixture}/candidate-tree" .PKGINFO usr/bin/alpha
if python3 "${checker}" "${fixture}" \
    --candidate "${fixture}/candidates/alpha-different.pkg.tar.xz" \
    >/dev/null 2>"${fixture}/replacement-failure"; then
  fail "repository validator accepted different bytes under the same package identity"
fi
grep -q 'bump epoch/pkgver/pkgrel' "${fixture}/replacement-failure" ||
  fail "same-version replacement error did not require an actionable version bump"
sed -i 's/pkgver = 1-1/pkgver = 1-2/' "${fixture}/candidate-tree/.PKGINFO"
bsdtar -cf "${fixture}/candidates/alpha-bumped.pkg.tar.xz" \
  -C "${fixture}/candidate-tree" .PKGINFO usr/bin/alpha
python3 "${checker}" "${fixture}" \
  --candidate "${fixture}/candidates/alpha-bumped.pkg.tar.xz" >/dev/null ||
  fail "repository validator rejected a candidate with a bumped package version"

# Replacing the cache with a newly versioned artifact and a new binding is the
# valid repack path; the old identity and its binding must leave together.
rm -f "${cache_repo}/alpha-1-1-any.pkg.tar.xz" \
  "${cache_repo}/.thorch-inputs/alpha-1-1-any.pkg.tar.xz.json"
cp "${fixture}/candidates/alpha-bumped.pkg.tar.xz" "${cache_repo}/"
write_binding "${cache_repo}" alpha-bumped.pkg.tar.xz "${wrong_inputs_sha256}"
python3 "${checker}" "${cache_repo}" \
  --bindings-root "${cache_repo}/.thorch-inputs" --require alpha beta >/dev/null ||
  fail "repository validator rejected a correctly versioned and rebound repack"

install -d "${fixture}/retained/cohort"
cp "${fixture}/candidates/alpha-bumped.pkg.tar.xz" \
  "${fixture}/retained/cohort/alpha-1-2-any.pkg.tar.xz"
printf 'different retained bytes\n' > "${fixture}/candidate-tree/usr/bin/alpha"
bsdtar -cf "${fixture}/candidates/alpha-retained-conflict.pkg.tar.xz" \
  -C "${fixture}/candidate-tree" .PKGINFO usr/bin/alpha
if python3 "${checker}" "${fixture}" \
    --retained-root "${fixture}/retained" \
    --candidate "${fixture}/candidates/alpha-retained-conflict.pkg.tar.xz" \
    >/dev/null 2>"${fixture}/retained-failure"; then
  fail "repository validator ignored a same-version conflict in a retained cohort"
fi
grep -q 'bump epoch/pkgver/pkgrel' "${fixture}/retained-failure" ||
  fail "retained same-version conflict did not require a version bump"

sed -i 's/pkgver = 1-2/pkgver = 1-1/' "${fixture}/candidate-tree/.PKGINFO"
bsdtar -cf "${fixture}/retained/cohort/alpha-current-conflict.pkg.tar.xz" \
  -C "${fixture}/candidate-tree" .PKGINFO usr/bin/alpha
if python3 "${checker}" "${fixture}" \
    --retained-root "${fixture}/retained" \
    >/dev/null 2>"${fixture}/retained-state-failure"; then
  fail "final repository validation ignored a current/retained identity conflict"
fi
grep -q 'retained repositories contain different bytes' \
  "${fixture}/retained-state-failure" ||
  fail "current/retained state failure did not identify conflicting bytes"
rm -f "${fixture}/retained/cohort/alpha-current-conflict.pkg.tar.xz"

make_package thorch-consumer usr/bin/consumer thorch-missing
if python3 "${checker}" "${fixture}" >/dev/null 2>"${fixture}/dependency-failure"; then
  fail "repository validator accepted a missing internal dependency"
fi
grep -q 'thorch-consumer: thorch-missing' "${fixture}/dependency-failure" || \
  fail "dependency error did not identify the consumer and missing package"
rm -f "${fixture}/thorch-consumer-1-1-any.pkg.tar.xz"

make_package thorch-consumer usr/bin/consumer linux-thorch
if python3 "${checker}" "${fixture}" >/dev/null 2>"${fixture}/linux-dependency-failure"; then
  fail "repository validator accepted a missing linux-thorch dependency"
fi
grep -q 'thorch-consumer: linux-thorch' "${fixture}/linux-dependency-failure" || \
  fail "linux-thorch dependency error did not identify the missing provider"
rm -f "${fixture}/thorch-consumer-1-1-any.pkg.tar.xz"

make_package beta usr/bin/alpha
if python3 "${checker}" "${fixture}" >/dev/null 2>"${fixture}/failure"; then
  fail "repository validator accepted a cross-package file collision"
fi
grep -q 'usr/bin/alpha: alpha, beta' "${fixture}/failure" || \
  fail "collision error did not identify both owners"

printf 'thorch package repository checks passed\n'
