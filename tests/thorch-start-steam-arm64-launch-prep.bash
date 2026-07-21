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
binfmt_log="${tmp}/binfmt.log"

mkdir -p "${steam_root}/steamrtarm64" "${proton_dir}" "${system_steam}"
mkdir -p "${tmp}/.local/bin" "${steam_root}/thorch-steamos-bin"
touch "${steam_root}/steamrtarm64/fex-steam"
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
printf '%s\n' "${LD_LIBRARY_PATH:-}" >> "${THORCH_FAKE_STEAM_ENV_LOG:?}"
printf '%s\n' "${PATH:-}" >> "${THORCH_FAKE_STEAM_PATH_LOG:?}"
command -v fex-steam >> "${THORCH_FAKE_FEX_STEAM_LOG:?}"
exit "${THORCH_FAKE_STEAM_EXIT:-0}"
EOF
chmod 755 "${steam_root}/steamrtarm64/steam"
cat > "${steam_root}/steamrtarm64/fex-steam" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "${steam_root}/steamrtarm64/fex-steam"
cat > "${tmp}/thorch-fex-binfmt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${THORCH_FAKE_BINFMT_LOG:?}"
EOF
chmod 755 "${tmp}/thorch-fex-binfmt"

HOME="${tmp}" \
STEAM_STORAGE_ROOT="${tmp}" \
THORCH_STEAM_SYSTEM_DIR="${system_steam}" \
THORCH_STEAM_MODE=deck \
THORCH_STEAM_USE_GAMESCOPE=0 \
THORCH_FEX_BINFMT_HELPER="${tmp}/thorch-fex-binfmt" \
THORCH_FAKE_BINFMT_LOG="${binfmt_log}" \
THORCH_FAKE_STEAM_LOG="${log}" \
THORCH_FAKE_STEAM_ENV_LOG="${tmp}/steam-env.log" \
THORCH_FAKE_STEAM_PATH_LOG="${tmp}/steam-path.log" \
THORCH_FAKE_FEX_STEAM_LOG="${tmp}/fex-steam.log" \
  "${script}"

cmp -s "${system_steam}/toolmanifest.vdf" "${proton_dir}/toolmanifest.vdf" ||
  fail "Proton ARM toolmanifest was not restored from system Steam assets"
if grep -q 'require_tool_appid' "${proton_dir}/toolmanifest.vdf"; then
  fail "Proton ARM manifest still requires Steam Linux Runtime 4.0 - Arm64"
fi

mapfile -t calls < "${log}"
[[ "${#calls[@]}" -eq 2 ]] || fail "expected preflight and final Steam calls, got ${#calls[@]}"
[[ "${calls[0]}" == "-exitsteam" ]] ||
  fail "unexpected preflight args: ${calls[0]}"
[[ "${calls[1]}" == *"-steamdeck -steamos3 -gamepadui"* ]] ||
  fail "final launch is missing Steam Deck args: ${calls[1]}"
for arg in -noverifyfiles -nobootstrapupdate -skipinitialbootstrap -norepairfiles; do
  [[ "${calls[1]}" == *"${arg}"* ]] || fail "final launch is missing ${arg}: ${calls[1]}"
done

while IFS= read -r ld_library_path; do
  [[ "${ld_library_path}" == "${steam_root}/lib/aarch64-linux-gnu" ]] ||
    fail "unexpected LD_LIBRARY_PATH: ${ld_library_path}"
done < "${tmp}/steam-env.log"

while IFS= read -r runtime_path; do
  case ":${runtime_path}:" in
    *":${steam_root}/steamrtarm64:"*) ;;
    *) fail "Steam runtime PATH cannot find colocated fex-steam: ${runtime_path}" ;;
  esac
  case ":${runtime_path}:" in
    *":${tmp}/.local/bin:"*) ;;
    *) fail "Steam runtime PATH cannot find installed user helpers: ${runtime_path}" ;;
  esac
  case ":${runtime_path}:" in
    *":${steam_root}/thorch-steamos-bin:"*) ;;
    *) fail "Steam runtime PATH cannot find SteamOS compatibility helpers: ${runtime_path}" ;;
  esac
done < "${tmp}/steam-path.log"

while IFS= read -r fex_steam; do
  [[ "${fex_steam}" == "${steam_root}/steamrtarm64/fex-steam" ]] ||
    fail "Steam runtime resolved the wrong fex-steam helper: ${fex_steam}"
done < "${tmp}/fex-steam.log"

mapfile -t binfmt_calls < "${binfmt_log}"
[[ "${binfmt_calls[*]}" == "disable enable" ]] ||
  fail "Steam launch did not suspend and restore FEX binfmt: ${binfmt_calls[*]}"

: > "${binfmt_log}"
set +e
HOME="${tmp}" \
STEAM_STORAGE_ROOT="${tmp}" \
THORCH_STEAM_SYSTEM_DIR="${system_steam}" \
THORCH_STEAM_MODE=deck \
THORCH_STEAM_USE_GAMESCOPE=0 \
THORCH_STEAM_PREFLIGHT=0 \
THORCH_FEX_BINFMT_HELPER="${tmp}/thorch-fex-binfmt" \
THORCH_FAKE_BINFMT_LOG="${binfmt_log}" \
THORCH_FAKE_STEAM_EXIT=42 \
THORCH_FAKE_STEAM_LOG="${log}" \
THORCH_FAKE_STEAM_ENV_LOG="${tmp}/steam-env.log" \
THORCH_FAKE_STEAM_PATH_LOG="${tmp}/steam-path.log" \
THORCH_FAKE_FEX_STEAM_LOG="${tmp}/fex-steam.log" \
  "${script}"
rc=$?
set -e
[[ "${rc}" -eq 42 ]] || fail "Steam launch failure was not propagated: ${rc}"
mapfile -t binfmt_calls < "${binfmt_log}"
[[ "${binfmt_calls[*]}" == "disable enable" ]] ||
  fail "failed Steam launch did not restore FEX binfmt: ${binfmt_calls[*]}"

printf 'thorch Steam ARM64 launch prep tests passed\n'
