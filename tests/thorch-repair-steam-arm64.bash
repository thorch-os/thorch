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
system_bin="${tmp}/usr/bin"
mkdir -p \
  "${steam_root}/linuxarm64" \
  "${steam_root}/steamrtarm64" \
  "${steam_root}/linux64" \
  "${steam_root}/linux32" \
  "${system_bin}"
touch \
  "${steam_root}/linuxarm64/steam-launch-wrapper" \
  "${steam_root}/linux64/steamclient.so" \
  "${steam_root}/linux32/steamclient.so"
chmod 755 "${steam_root}/linuxarm64/steam-launch-wrapper"

for helper in thorch-setup-steam-arm64 thorch-start-steam-arm64 thorch-repair-steam-arm64 thorch-install-proton-community; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"${system_bin}/${helper}"
  chmod 755 "${system_bin}/${helper}"
done

HOME="${tmp}" STEAM_STORAGE_ROOT="${tmp}" THORCH_STEAM_SYSTEM_BIN_DIR="${system_bin}" "${script}"

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

for helper in thorch-setup-steam-arm64 thorch-start-steam-arm64 thorch-repair-steam-arm64 thorch-install-proton-community; do
  cmp -s "${system_bin}/${helper}" "${tmp}/.local/bin/${helper}" ||
    fail "repair did not refresh ${helper} from the installed package"
done

printf 'thorch Steam ARM64 repair tests passed\n'
