#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${root}/scripts/check-package-versions.py"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${fixture}/bin" "${fixture}/manifests" "${fixture}/packages/demo/payload"
cat > "${fixture}/bin/vercmp" <<'PY'
#!/usr/bin/env python3
import re
import sys

def key(value):
    return [int(item) if item.isdigit() else item for item in re.split(r"([0-9]+)", value)]

a, b = key(sys.argv[1]), key(sys.argv[2])
print((a > b) - (a < b))
PY
chmod 0755 "${fixture}/bin/vercmp"

cat > "${fixture}/manifests/packages.json" <<'JSON'
{
  "schema_version": 1,
  "aliases": {},
  "packages": [
    {
      "name": "demo",
      "path": "packages/demo",
      "profiles": ["build", "image"],
      "build_inputs": [],
      "version_inputs": ["policy/demo.conf"]
    }
  ]
}
JSON
cat > "${fixture}/packages/demo/PKGBUILD" <<'EOF'
pkgname=demo
pkgver=1.0
pkgrel=1
EOF
printf 'one\n' > "${fixture}/packages/demo/payload/value"
mkdir -p "${fixture}/policy"
printf 'policy=one\n' > "${fixture}/policy/demo.conf"

git -C "${fixture}" init -q
git -C "${fixture}" config user.name 'Thorch Tests'
git -C "${fixture}" config user.email 'tests@thorch.invalid'
git -C "${fixture}" add .
git -C "${fixture}" commit -qm base
base="$(git -C "${fixture}" rev-parse HEAD)"

printf 'two\n' > "${fixture}/packages/demo/payload/value"
if python3 "${checker}" --repo "${fixture}" --base-ref "${base}" \
    --vercmp "${fixture}/bin/vercmp" >"${fixture}/failure" 2>&1; then
  fail "input change without a version bump was accepted"
fi
grep -q 'version did not increase' "${fixture}/failure" || \
  fail "missing actionable error for unchanged version"

sed -i.bak 's/pkgrel=1/pkgrel=2/' "${fixture}/packages/demo/PKGBUILD"
rm -f "${fixture}/packages/demo/PKGBUILD.bak"
python3 "${checker}" --repo "${fixture}" --base-ref "${base}" \
  --vercmp "${fixture}/bin/vercmp" >/dev/null

git -C "${fixture}" show "${base}:packages/demo/PKGBUILD" > \
  "${fixture}/packages/demo/PKGBUILD"
git -C "${fixture}" show "${base}:packages/demo/payload/value" > \
  "${fixture}/packages/demo/payload/value"
printf 'policy=two\n' > "${fixture}/policy/demo.conf"
if python3 "${checker}" --repo "${fixture}" --base-ref "${base}" \
    --vercmp "${fixture}/bin/vercmp" >/dev/null 2>&1; then
  fail "declared version input change without a version bump was accepted"
fi

cat >> "${fixture}/packages/demo/PKGBUILD" <<'EOF'
pkgver() {
  printf '2.0\n'
}
EOF
if python3 "${checker}" --repo "${fixture}" --base-ref "${base}" \
    --vercmp "${fixture}/bin/vercmp" >"${fixture}/dynamic-failure" 2>&1; then
  fail "dynamic pkgver() was accepted by the static version policy"
fi
grep -q 'dynamic version functions are unsupported: pkgver' \
  "${fixture}/dynamic-failure" || \
  fail "dynamic pkgver() rejection was not actionable"

printf 'thorch package version checks passed\n'
