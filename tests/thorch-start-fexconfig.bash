#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-fex-bin/payload/usr/bin/thorch-start-fexconfig"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${tmp}/FEXConfig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${FAKE_FEXCONFIG_LOG:?}"
EOF
chmod 755 "${tmp}/FEXConfig"

mkdir -p "${tmp}/home/.fex-emu"
printf '{"Config":{"RootFS":"user-choice"}}\n' > "${tmp}/home/.fex-emu/Config.json"

HOME="${tmp}/home" \
PATH="${tmp}:${PATH}" \
FAKE_FEXCONFIG_LOG="${tmp}/fexconfig.log" \
  "${script}" --example

grep -qx -- '--example' "${tmp}/fexconfig.log" || fail "FEXConfig arguments were not forwarded"
grep -q 'user-choice' "${tmp}/home/.fex-emu/Config.json" || fail "legacy user config was changed"
[[ ! -e "${tmp}/home/.config/fex-emu" ]] || fail "launcher created an ignored duplicate XDG config"

printf 'thorch FEXConfig launcher test passed\n'
