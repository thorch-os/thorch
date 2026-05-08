#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-repair-steam-arm64"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

steam_root="${tmp}/.local/share/Steam"
mkdir -p \
  "${steam_root}/linuxarm64" \
  "${steam_root}/steamrtarm64" \
  "${steam_root}/linux64" \
  "${steam_root}/linux32"
touch \
  "${steam_root}/linuxarm64/steam-launch-wrapper" \
  "${steam_root}/linux64/steamclient.so" \
  "${steam_root}/linux32/steamclient.so"
chmod 755 "${steam_root}/linuxarm64/steam-launch-wrapper"

HOME="${tmp}" STEAM_STORAGE_ROOT="${tmp}" "${script}"

wrapper="${steam_root}/steamrtarm64/steam-launch-wrapper"
[[ -L "${wrapper}" ]] || fail "missing steamrtarm64 launch wrapper link"
[[ "$(readlink "${wrapper}")" == "../linuxarm64/steam-launch-wrapper" ]] ||
  fail "unexpected launch wrapper target: $(readlink "${wrapper}")"

sdk64="${tmp}/.steam/sdk64/steamclient.so"
sdk32="${tmp}/.steam/sdk32/steamclient.so"
[[ -L "${sdk64}" ]] || fail "missing sdk64 steamclient link"
[[ -L "${sdk32}" ]] || fail "missing sdk32 steamclient link"
[[ "$(readlink "${sdk64}")" == "${steam_root}/linux64/steamclient.so" ]] ||
  fail "unexpected sdk64 target: $(readlink "${sdk64}")"
[[ "$(readlink "${sdk32}")" == "${steam_root}/linux32/steamclient.so" ]] ||
  fail "unexpected sdk32 target: $(readlink "${sdk32}")"

printf 'thorch Steam ARM64 repair tests passed\n'
