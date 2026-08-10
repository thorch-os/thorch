#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kwin_pkgbuild="${root}/packages/thorch-kwin/PKGBUILD"
keyboard_pkgbuild="${root}/packages/thorch-plasma-keyboard/PKGBUILD"
defaults_pkgbuild="${root}/packages/thorch-kde-defaults/PKGBUILD"
manifest="${root}/manifests/packages.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

metadata() {
  bash -c 'source "$1"; declare -p pkgname pkgver provides conflicts replaces' _ "$1"
}

kwin_metadata="$(metadata "${kwin_pkgbuild}")"
keyboard_metadata="$(metadata "${keyboard_pkgbuild}")"
defaults_metadata="$(bash -c 'source "$1"; declare -p depends' _ "${defaults_pkgbuild}")"

grep -Fq 'pkgname="thorch-kwin"' <<<"${kwin_metadata}" ||
  fail 'patched KWin still uses the stock package name'
grep -Eq 'provides=.*kwin=[^" ]+' <<<"${kwin_metadata}" ||
  fail 'patched KWin does not provide a versioned stock package identity'
grep -Eq 'conflicts=.*kwin' <<<"${kwin_metadata}" ||
  fail 'patched KWin does not conflict with the stock package'
grep -Eq 'replaces=.*kwin' <<<"${kwin_metadata}" ||
  fail 'patched KWin does not replace the stock package during system upgrades'

grep -Fq 'pkgname="thorch-plasma-keyboard"' <<<"${keyboard_metadata}" ||
  fail 'patched keyboard still uses the stock package name'
grep -Eq 'provides=.*plasma-keyboard=[^" ]+' <<<"${keyboard_metadata}" ||
  fail 'patched keyboard does not provide a versioned stock package identity'
grep -Eq 'conflicts=.*plasma-keyboard' <<<"${keyboard_metadata}" ||
  fail 'patched keyboard does not conflict with the stock package'
grep -Eq 'replaces=.*plasma-keyboard' <<<"${keyboard_metadata}" ||
  fail 'patched keyboard does not replace the stock package during system upgrades'

grep -Eq 'depends=.*thorch-kwin' <<<"${defaults_metadata}" ||
  fail 'KDE defaults do not depend on the protected KWin package identity'
grep -Eq 'depends=.*thorch-plasma-keyboard' <<<"${defaults_metadata}" ||
  fail 'KDE defaults do not depend on the protected keyboard package identity'

python3 - "${manifest}" <<'PY' || fail 'package manifest does not use protected Plasma identities'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
names = {entry["name"] for entry in manifest["packages"]}
expected = {"thorch-kwin", "thorch-plasma-keyboard"}
stock = {"kwin", "plasma-keyboard"}
if not expected <= names or names & stock:
    raise SystemExit(1)
expected_aliases = {
    "kwin": "thorch-kwin",
    "plasma-keyboard": "thorch-plasma-keyboard",
}
if any(manifest["aliases"].get(name) != target for name, target in expected_aliases.items()):
    raise SystemExit(1)
PY

printf 'thorch Plasma package identity checks passed\n'
