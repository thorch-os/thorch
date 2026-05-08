#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-start-steam-arm64"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

steam_root="${tmp}/.local/share/Steam"
system_steam="${tmp}/usr/share/steam"
proton_dir="${steam_root}/steamapps/common/Proton 11.0 (ARM64)"
log="${tmp}/steam-args.log"

mkdir -p "${steam_root}/steamrtarm64" "${proton_dir}" "${system_steam}"
cat > "${system_steam}/toolmanifest.vdf" <<'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/proton %verb%"
  "use_sessions" "1"
  "compatmanager_layer_name" "proton"
}
EOF
cat > "${proton_dir}/toolmanifest.vdf" <<'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/proton %verb%"
  "require_tool_appid" "4185400"
}
EOF
cat > "${steam_root}/steamrtarm64/steam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${THORCH_FAKE_STEAM_LOG:?}"
exit 0
EOF
chmod 755 "${steam_root}/steamrtarm64/steam"

HOME="${tmp}" \
STEAM_STORAGE_ROOT="${tmp}" \
THORCH_STEAM_SYSTEM_DIR="${system_steam}" \
THORCH_STEAM_MODE=deck \
THORCH_STEAM_USE_GAMESCOPE=0 \
THORCH_FAKE_STEAM_LOG="${log}" \
  "${script}"

cmp -s "${system_steam}/toolmanifest.vdf" "${proton_dir}/toolmanifest.vdf" ||
  fail "Proton ARM toolmanifest was not restored from system Steam assets"
if grep -q 'require_tool_appid' "${proton_dir}/toolmanifest.vdf"; then
  fail "Proton ARM manifest still requires Steam Linux Runtime 4.0 - Arm64"
fi

mapfile -t calls < "${log}"
[[ "${#calls[@]}" -eq 2 ]] || fail "expected preflight and final Steam calls, got ${#calls[@]}"
[[ "${calls[0]}" == "-steamdeck -exitsteam" ]] ||
  fail "unexpected preflight args: ${calls[0]}"
[[ "${calls[1]}" == *"-steamdeck -steamos3 -gamepadui"* ]] ||
  fail "final launch is missing Steam Deck args: ${calls[1]}"
for arg in -noverifyfiles -nobootstrapupdate -skipinitialbootstrap -norepairfiles; do
  [[ "${calls[1]}" == *"${arg}"* ]] || fail "final launch is missing ${arg}: ${calls[1]}"
done

printf 'thorch Steam ARM64 launch prep tests passed\n'
