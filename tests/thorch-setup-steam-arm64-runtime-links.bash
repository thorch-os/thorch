#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-setup-steam-arm64"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

steam_root="${tmp}/.local/share/Steam"
runtime_lib_dir="${steam_root}/steam-runtime-steamrt-arm64/fake/files/lib/aarch64-linux-gnu"
system_steam="${tmp}/usr/share/steam"
mkdir -p \
  "${runtime_lib_dir}" \
  "${steam_root}/steamrtarm64" \
  "${system_steam}" \
  "${tmp}/.steam"
touch \
  "${runtime_lib_dir}/libibus-1.0.so.5.0.5200" \
  "${runtime_lib_dir}/libgtk-x11-2.0.so.0.2400.33" \
  "${runtime_lib_dir}/libgdk-x11-2.0.so.0.2400.33" \
  "${steam_root}/steamrtarm64/libvpx.so.6" \
  "${steam_root}/steamrtarm64/gameoverlayrenderer.so"
cat > "${system_steam}/registry.vdf" <<'EOF'
library=@STEAM_LIBRARY@
EOF
printf 'preserve user registry\n' > "${tmp}/.steam/registry.vdf"

HOME="${tmp}" \
STEAM_STORAGE_ROOT="${tmp}" \
THORCH_STEAM_SYSTEM_DIR="${system_steam}" \
  "${script}" --repair-runtime-links

grep -qx 'preserve user registry' "${tmp}/.steam/registry.vdf" ||
  fail "repair overwrote an existing Steam registry"

link_dir="${steam_root}/lib/aarch64-linux-gnu"
for soname in libibus-1.0.so.5 libgtk-x11-2.0.so.0 libgdk-x11-2.0.so.0; do
  [[ -L "${link_dir}/${soname}" ]] || fail "missing ${soname} link"
  target="$(readlink "${link_dir}/${soname}")"
  [[ "${target}" == "${runtime_lib_dir}/${soname}."* ]] ||
    fail "${soname} link points at unexpected target: ${target}"
done

[[ -L "${link_dir}/libvpx.so.6" ]] || fail "missing libvpx.so.6 link"
[[ "$(readlink "${link_dir}/libvpx.so.6")" == "${steam_root}/steamrtarm64/libvpx.so.6" ]] ||
  fail "libvpx.so.6 link points at unexpected target"

[[ -L "${tmp}/.steam/steamrtarm64" ]] || fail "missing steamrtarm64 link"
[[ "$(readlink "${tmp}/.steam/steamrtarm64")" == "${steam_root}/steamrtarm64" ]] ||
  fail "steamrtarm64 link points at unexpected target"

rm -f "${tmp}/.steam/registry.vdf"
HOME="${tmp}" \
STEAM_STORAGE_ROOT="${tmp}" \
THORCH_STEAM_SYSTEM_DIR="${system_steam}" \
  "${script}" --repair-runtime-links
grep -Fqx "library=${steam_root}" "${tmp}/.steam/registry.vdf" ||
  fail "repair did not seed a missing Steam registry"

printf 'thorch Steam ARM64 runtime link tests passed\n'
