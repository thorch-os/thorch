#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair="${root}/scripts/repair-thorch-keyboard.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "${fixture}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${fixture}/bin" "${fixture}/source/packages/thorch-kwin" \
  "${fixture}/source/packages/thorch-plasma-keyboard"
printf 'pkgname=thorch-kwin\npkgver=1\npkgrel=1\n' \
  >"${fixture}/source/packages/thorch-kwin/PKGBUILD"
printf 'pkgname=thorch-plasma-keyboard\npkgver=1\npkgrel=1\n' \
  >"${fixture}/source/packages/thorch-plasma-keyboard/PKGBUILD"

cat >"${fixture}/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'aarch64\n'
EOF

cat >"${fixture}/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pacman %q ' "$@" >>"${REPAIR_TEST_LOG}"
printf '\n' >>"${REPAIR_TEST_LOG}"
case "${1:-}" in
  -Qoq)
    [[ -f "${REPAIR_TEST_STATE}" ]] || {
      [[ "${3:-}" == */kwin_wayland ]] && printf 'kwin\n' || printf 'plasma-keyboard\n'
      exit 0
    }
    [[ "${3:-}" == */kwin_wayland ]] && printf 'thorch-kwin\n' || printf 'thorch-plasma-keyboard\n'
    ;;
  -U)
    touch "${REPAIR_TEST_STATE}"
    ;;
esac
EOF

cat >"${fixture}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-v' ]] && exit 0
"$@"
EOF

cat >"${fixture}/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$(sed -n 's/^pkgname=//p' PKGBUILD)"
package="${PWD}/${name}-1-1-aarch64.pkg.tar.zst"
if [[ " $* " == *' --packagelist '* ]]; then
  printf '%s\n' "${package}"
else
  printf 'makepkg %s\n' "${name}" >>"${REPAIR_TEST_LOG}"
  : >"${package}"
fi
EOF

chmod 0755 "${fixture}/bin/"*
export REPAIR_TEST_LOG="${fixture}/commands.log"
export REPAIR_TEST_STATE="${fixture}/repaired"
export PATH="${fixture}/bin:${PATH}"

"${repair}" --source "${fixture}/source" >"${fixture}/first-output"

[[ -f "${REPAIR_TEST_STATE}" ]] || fail 'repair did not install the rebuilt packages'
grep -q '^makepkg thorch-kwin$' "${REPAIR_TEST_LOG}" || fail 'repair did not build patched KWin'
grep -q '^makepkg thorch-plasma-keyboard$' "${REPAIR_TEST_LOG}" || fail 'repair did not build the patched keyboard'
install_line="$(grep '^pacman -U ' "${REPAIR_TEST_LOG}")"
[[ "${install_line}" == *thorch-kwin-1-1-aarch64.pkg.tar.zst* ]] ||
  fail 'repair transaction omitted patched KWin'
[[ "${install_line}" == *thorch-plasma-keyboard-1-1-aarch64.pkg.tar.zst* ]] ||
  fail 'repair transaction omitted the patched keyboard'

before="$(wc -l <"${REPAIR_TEST_LOG}")"
"${repair}" --source "${fixture}/source" >"${fixture}/second-output"
after="$(wc -l <"${REPAIR_TEST_LOG}")"
[[ "${after}" -eq $((before + 2)) ]] || fail 'second repair run performed package work'
grep -q 'already installed; nothing to do' "${fixture}/second-output" ||
  fail 'second repair run did not report its no-op'

printf 'thorch keyboard repair checks passed\n'
