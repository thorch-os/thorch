#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-gaming-installers/payload/usr/bin/thorch-install-fex"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${tmp}/FEX" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${*}" == "/bin/uname -m" ]]; then
  printf 'x86_64\n'
  exit 0
fi
printf 'unexpected FEX invocation: %s\n' "$*" >&2
exit 2
EOF
chmod 755 "${tmp}/FEX"

cat > "${tmp}/FEXRootFSFetcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FEXRootFSFetcher %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
mkdir -p "${FEX_ROOTFS_DIR:?}"
printf 'valid squashfs\n' > "${FEX_ROOTFS_DIR}/ArchLinux.sqsh"
EOF
chmod 755 "${tmp}/FEXRootFSFetcher"

cat > "${tmp}/unsquashfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-s" ]]; then
  grep -q 'valid squashfs' "${2:?}"
  exit $?
fi

dest=""
source=""
while [[ "$#" -gt 0 ]]; do
  case "${1}" in
    -d)
      dest="${2:?}"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      source="${1}"
      shift
      ;;
  esac
done

[[ -n "${dest}" && -n "${source}" ]] || exit 2
grep -q 'valid squashfs' "${source}" || exit 1
mkdir -p "${dest}/usr/lib" "${dest}/bin"
printf '#!/bin/sh\n' > "${dest}/bin/sh"
printf 'x86 guest lib\n' > "${dest}/usr/lib/libvulkan_freedreno.so"
EOF
chmod 755 "${tmp}/unsquashfs"

cat > "${tmp}/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s: ELF 64-bit LSB shared object, x86-64\n' "${1:-file}"
EOF
chmod 755 "${tmp}/file"

home="${tmp}/home"
rootfs_dir="${home}/.fex-emu/RootFS"
mkdir -p "${rootfs_dir}"
printf 'truncated download\n' > "${rootfs_dir}/ArchLinux.sqsh"

FAKE_COMMAND_LOG="${tmp}/commands.log" \
  HOME="${home}" \
  FEX_ROOTFS_DIR="${rootfs_dir}" \
  PATH="${tmp}:${PATH}" \
  "${script}" >/dev/null

grep -qx 'FEXRootFSFetcher -y -x --distro-name arch --distro-version rolling' "${tmp}/commands.log" ||
  fail "FEXRootFSFetcher was not invoked after corrupt rootfs was found"

compgen -G "${rootfs_dir}/ArchLinux.sqsh.invalid.*" >/dev/null ||
  fail "corrupt rootfs was not moved aside"

grep -q 'valid squashfs' "${rootfs_dir}/ArchLinux.sqsh" ||
  fail "replacement rootfs was not installed"

[[ -d "${rootfs_dir}/ArchLinux/usr/lib" ]] ||
  fail "replacement rootfs was not unpacked"

grep -q '"RootFS": ".*/ArchLinux"' "${home}/.fex-emu/Config.json" ||
  fail "FEX config was not pointed at unpacked rootfs"

python3 - "${home}/.fex-emu/Config.json" "${tmp}/chosen-rootfs" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["Config"]["RootFS"] = sys.argv[2]
data["Config"]["Multiblock"] = "0"
data["Config"]["UserChoice"] = "keep-me"
data["ThunksDB"]["Vulkan"] = 0
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
mkdir -p "${tmp}/chosen-rootfs/usr/lib" "${tmp}/chosen-rootfs/bin"
touch "${tmp}/chosen-rootfs/bin/sh"

FAKE_COMMAND_LOG="${tmp}/commands.log" \
  HOME="${home}" \
  FEX_ROOTFS_DIR="${rootfs_dir}" \
  PATH="${tmp}:${PATH}" \
  "${script}" >/dev/null

python3 - "${home}/.fex-emu/Config.json" "${tmp}/chosen-rootfs" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["Config"]["RootFS"] == sys.argv[2]
assert data["Config"]["Multiblock"] == "0"
assert data["Config"]["UserChoice"] == "keep-me"
assert data["ThunksDB"]["Vulkan"] == 0
PY

template="${tmp}/Config.template.json"
cat > "${template}" <<'EOF'
{
  "Config": {"RootFS": "ArchLinux", "Multiblock": "1"},
  "ThunksDB": {"Vulkan": 0, "GL": 0}
}
EOF
new_home="${tmp}/new-home"
new_rootfs="${new_home}/.fex-emu/RootFS"
mkdir -p "${new_rootfs}/ArchLinux/usr/lib" "${new_rootfs}/ArchLinux/bin"
touch "${new_rootfs}/ArchLinux/bin/sh"

HOME="${new_home}" \
FEX_ROOTFS_DIR="${new_rootfs}" \
THORCH_FEX_CONFIG_TEMPLATE="${template}" \
PATH="${tmp}:${PATH}" \
  "${script}" >/dev/null

python3 - "${new_home}/.fex-emu/Config.json" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for thunk in ("GL", "Vulkan", "drm", "asound", "WaylandClient"):
    assert data["ThunksDB"][thunk] == 1, (thunk, data["ThunksDB"][thunk])
PY

xdg_home="${tmp}/xdg-home"
xdg_rootfs="${tmp}/xdg-rootfs"
mkdir -p \
  "${xdg_home}/.config/fex-emu/AppConfig" \
  "${xdg_rootfs}/ArchLinux/usr/lib" \
  "${xdg_rootfs}/ArchLinux/bin"
touch "${xdg_rootfs}/ArchLinux/bin/sh"
printf '{"Config":{"RootFS":"user-xdg-rootfs","Multiblock":"0"},"ThunksDB":{"Vulkan":0}}\n' \
  > "${xdg_home}/.config/fex-emu/Config.json"
printf '{"Config":{"UserAppChoice":"keep-me"}}\n' \
  > "${xdg_home}/.config/fex-emu/AppConfig/game.json"

HOME="${xdg_home}" \
FEX_ROOTFS_DIR="${xdg_rootfs}" \
THORCH_FEX_CONFIG_TEMPLATE="${template}" \
PATH="${tmp}:${PATH}" \
  "${script}" >/dev/null

grep -q 'user-xdg-rootfs' "${xdg_home}/.fex-emu/Config.json" ||
  fail "XDG user config was not preserved during legacy-path migration"
grep -q 'UserAppChoice' "${xdg_home}/.fex-emu/AppConfig/game.json" ||
  fail "XDG per-application config was not preserved during migration"

printf 'thorch install FEX corrupt rootfs test passed\n'
