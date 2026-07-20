#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-steamos-mode"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${tmp}/bin" "${tmp}/runtime" "${tmp}/home/.local/bin"

cat >"${tmp}/bin/setsid" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"${tmp}/bin/failing-supervisor" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
cat >"${tmp}/home/.local/bin/thorch-start-steam-arm64" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "${tmp}/bin/setsid" "${tmp}/bin/failing-supervisor" \
  "${tmp}/home/.local/bin/thorch-start-steam-arm64"

set +e
output="$(
  HOME="${tmp}/home" \
  XDG_RUNTIME_DIR="${tmp}/runtime" \
  XDG_STATE_HOME="${tmp}/state" \
  THORCH_STEAMOS_SELF="${tmp}/bin/failing-supervisor" \
  THORCH_STEAMOS_STARTUP_WAIT_TICKS=5 \
  PATH="${tmp}/bin:${PATH}" \
    "${script}" start 2>&1
)"
status=$?
set -e

[[ "${status}" -eq 42 ]] || fail "launch failure returned ${status}, expected 42"
grep -q 'SteamOS mode failed to start (exit 42)' <<<"${output}" ||
  fail "launch failure was not reported"
if grep -q '^Started SteamOS mode' <<<"${output}"; then
  fail "launch failure was reported as a successful start"
fi

printf 'thorch SteamOS launch failure checks passed\n'
