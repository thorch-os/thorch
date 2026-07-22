#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-install-proton-community"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

steam_root="${tmp}/steam"
download_dir="${tmp}/downloads"
fixtures="${tmp}/fixtures"
cachy_dir="proton-cachyos-test-arm64"
ge_dir="GE-Proton-test-aarch64"
cachy_archive="proton-cachyos-test-arm64.tar.xz"
ge_archive="GE-Proton-test-aarch64.tar.gz"
mkdir -p \
  "${fixtures}/cachy/${cachy_dir}/files/bin-arm64" \
  "${fixtures}/ge/${ge_dir}/files/bin-arm64" \
  "${steam_root}/compatibilitytools.d/${cachy_dir}" \
  "${steam_root}/compatibilitytools.d/Proton11ARM"

cat > "${steam_root}/compatibilitytools.d/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "proton11_arm64"
    {
      "install_path" "Proton11ARM"
    }
  }
}
EOF
printf 'preserve unrelated root manifest\n' > "${steam_root}/compatibilitytools.d/user-tool.vdf"

for variant in "cachy/${cachy_dir}" "ge/${ge_dir}"; do
  cat > "${fixtures}/${variant}/proton" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 755 "${fixtures}/${variant}/proton"
  cat > "${fixtures}/${variant}/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "community_test" { "install_path" "." }
  }
}
EOF
  cat > "${fixtures}/${variant}/toolmanifest.vdf" <<'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/proton %verb%"
  "require_tool_appid" "4185400"
}
EOF
done

printf 'preserve incomplete payload\n' > "${steam_root}/compatibilitytools.d/${cachy_dir}/note.txt"
cat > "${steam_root}/compatibilitytools.d/Proton11ARM/compatibilitytool.vdf" <<'EOF'
"compatibilitytools" { "compat_tools" { "proton11_arm64" { } } }
EOF
printf 'legacy manifest\n' > "${steam_root}/compatibilitytools.d/Proton11ARM/toolmanifest.vdf"
: > "${steam_root}/compatibilitytools.d/Proton11ARM/dist.lock"
ln -s /missing/valve-proton "${steam_root}/compatibilitytools.d/Proton11ARM/proton"
printf 'preserve user file\n' > "${steam_root}/compatibilitytools.d/Proton11ARM/user-note.txt"

tar -cJf "${fixtures}/${cachy_archive}" -C "${fixtures}/cachy" "${cachy_dir}"
tar -czf "${fixtures}/${ge_archive}" -C "${fixtures}/ge" "${ge_dir}"
cachy_sha="$(sha256sum "${fixtures}/${cachy_archive}" | awk '{print $1}')"
ge_sha="$(sha256sum "${fixtures}/${ge_archive}" | awk '{print $1}')"
mkdir -p "${download_dir}"
cp "${fixtures}/${cachy_archive}" "${download_dir}/${cachy_archive}.part"

run_installer() {
  THORCH_STEAM_ROOT="${steam_root}" \
  THORCH_PROTON_DOWNLOAD_DIR="${download_dir}" \
  THORCH_PROTON_CACHYOS_VERSION=test \
  THORCH_PROTON_CACHYOS_ARCHIVE="${cachy_archive}" \
  THORCH_PROTON_CACHYOS_DIR="${cachy_dir}" \
  THORCH_PROTON_CACHYOS_URL="file://${fixtures}/${cachy_archive}" \
  THORCH_PROTON_CACHYOS_SHA256="${cachy_sha}" \
  THORCH_PROTON_GE_VERSION=test \
  THORCH_PROTON_GE_ARCHIVE="${ge_archive}" \
  THORCH_PROTON_GE_DIR="${ge_dir}" \
  THORCH_PROTON_GE_URL="file://${fixtures}/${ge_archive}" \
  THORCH_PROTON_GE_SHA256="${ge_sha}" \
    "${script}"
}

run_installer >/dev/null

for directory in "${cachy_dir}" "${ge_dir}"; do
  target="${steam_root}/compatibilitytools.d/${directory}"
  [[ -x "${target}/proton" ]] || fail "${directory} is not launchable"
  [[ -d "${target}/files/bin-arm64" ]] || fail "${directory} lost its ARM64 runtime"
  ! grep -q 'require_tool_appid' "${target}/toolmanifest.vdf" ||
    fail "${directory} still requires an unusable Steam container runtime"
done

backup="$(find "${steam_root}/compatibilitytools.d" -maxdepth 1 -type d -name "${cachy_dir}.incomplete.*" -print -quit)"
[[ -n "${backup}" && -f "${backup}/note.txt" ]] || fail "incomplete community tool was not preserved"
[[ -f "${steam_root}/compatibilitytools.d/Proton11ARM/user-note.txt" ]] ||
  fail "legacy cleanup removed an unrelated user file"
[[ ! -e "${steam_root}/compatibilitytools.d/Proton11ARM/compatibilitytool.vdf" ]] ||
  fail "legacy Valve Proton registration was not removed"
[[ ! -L "${steam_root}/compatibilitytools.d/Proton11ARM/proton" ]] ||
  fail "legacy Valve Proton payload link was not removed"
[[ ! -e "${steam_root}/compatibilitytools.d/Proton11ARM/dist.lock" ]] ||
  fail "legacy Valve Proton lock marker was not removed"
[[ ! -e "${steam_root}/compatibilitytools.d/compatibilitytool.vdf" ]] ||
  fail "legacy root-level Valve Proton registration was not removed"
[[ -f "${steam_root}/compatibilitytools.d/user-tool.vdf" ]] ||
  fail "legacy cleanup removed an unrelated root-level registration"
[[ ! -e "${download_dir}/${cachy_archive}" && ! -e "${download_dir}/${ge_archive}" ]] ||
  fail "verified install archives were not cleared"

printf '  "require_tool_appid" "1628350"\n' >> \
  "${steam_root}/compatibilitytools.d/${cachy_dir}/toolmanifest.vdf"
rm -f "${fixtures}/${cachy_archive}" "${fixtures}/${ge_archive}"
run_installer >/dev/null || fail "idempotent rerun tried to redownload installed variants"
! grep -q 'require_tool_appid' \
  "${steam_root}/compatibilitytools.d/${cachy_dir}/toolmanifest.vdf" ||
  fail "idempotent rerun did not normalize a pre-existing community tool"

bad_root="${tmp}/bad-steam"
mkdir -p "${tmp}/bad-cache"
printf 'corrupt archive\n' > "${tmp}/bad-cache/bad.tar.xz"
set +e
THORCH_STEAM_ROOT="${bad_root}" \
THORCH_PROTON_DOWNLOAD_DIR="${tmp}/bad-cache" \
THORCH_PROTON_CACHYOS_VERSION=test \
THORCH_PROTON_CACHYOS_ARCHIVE=bad.tar.xz \
THORCH_PROTON_CACHYOS_DIR="${cachy_dir}" \
THORCH_PROTON_CACHYOS_URL="file://${tmp}/bad-cache/bad.tar.xz" \
THORCH_PROTON_CACHYOS_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  "${script}" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "failed download was reported as success"
[[ ! -e "${bad_root}/compatibilitytools.d/${cachy_dir}" ]] ||
  fail "failed download left a variant looking installed"

printf 'thorch community Proton installer tests passed\n'
