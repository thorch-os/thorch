#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-install-gaming-stack"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${tmp}/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'pacman %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"

case "${1:-}" in
  -Si)
    exit 0
    ;;
  -Q)
    exit 1
    ;;
  -S)
    exit 0
    ;;
  *)
    echo "unexpected fake pacman command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "${tmp}/pacman"

cat > "${tmp}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 2 && "${1}" == "-n" && "${2}" == "true" ]]; then
  exit 0
fi

printf 'sudo %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
exec "$@"
EOF
chmod 755 "${tmp}/sudo"

cat > "${tmp}/thorch-install-fex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'thorch-install-fex %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
EOF
chmod 755 "${tmp}/thorch-install-fex"

cat > "${tmp}/thorch-install-steam-arm64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'thorch-install-steam-arm64 %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
EOF
chmod 755 "${tmp}/thorch-install-steam-arm64"

FAKE_COMMAND_LOG="${tmp}/commands.log" PATH="${tmp}:${PATH}" "${script}" >/dev/null

install_line="$(grep -E '^(sudo )?pacman -S ' "${tmp}/commands.log" | tail -n1 || true)"
[[ -n "${install_line}" ]] || fail "gaming stack did not attempt optional package install"
[[ "${install_line}" == *" --needed "* ]] || fail "pacman install missed --needed: ${install_line}"
[[ "${install_line}" == *" --noconfirm "* ]] || fail "pacman install missed --noconfirm: ${install_line}"
[[ "${install_line}" == *" vulkan-tools"* ]] || fail "pacman install missed vulkan-tools: ${install_line}"

grep -qx 'thorch-install-fex ' "${tmp}/commands.log" || fail "thorch-install-fex was not invoked"
grep -qx 'thorch-install-steam-arm64 --yes' "${tmp}/commands.log" || fail "Steam installer was not invoked with --yes"

printf 'thorch install gaming stack fake pacman tests passed\n'
