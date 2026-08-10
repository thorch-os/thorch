#!/usr/bin/env bash
set -euo pipefail

repo='thorch-os/thorch'
ref='main'
ref_set=0
source_dir=''

usage() {
  cat <<'EOF'
Usage: repair-thorch-keyboard.sh [--ref GIT_REF] [--source DIRECTORY]

Restore Thorch's patched KWin and on-screen keyboard after stock Plasma
packages have replaced them. By default, the script downloads the current
Thorch main branch, builds both packages locally, and installs them together.

Options:
  --ref GIT_REF       Build another Thorch branch or commit instead of main.
  --source DIRECTORY  Build from an existing Thorch source tree without a
                      download. This option cannot be combined with --ref.
  -h, --help          Show this help.

Run this script as the affected desktop user, not as root. Building the two
packages can take a while. Pacman will ask permission to replace the stock
kwin and plasma-keyboard packages; answer yes to both replacement prompts.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

package_owner() {
  pacman -Qoq -- "$1" 2>/dev/null || true
}

keyboard_is_repaired() {
  [[ "$(package_owner /usr/bin/kwin_wayland)" == 'thorch-kwin' ]] &&
    [[ "$(package_owner /usr/bin/plasma-keyboard)" == 'thorch-plasma-keyboard' ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ $# -ge 2 ]] || fail '--ref requires a value'
      ref="$2"
      ref_set=1
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || fail '--source requires a directory'
      source_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

if keyboard_is_repaired; then
  printf 'Thorch keyboard packages are already installed; nothing to do.\n'
  exit 0
fi

[[ "${EUID}" -ne 0 ]] || fail 'run this script as your desktop user, not as root'
[[ "$(uname -m)" == 'aarch64' ]] || fail 'this repair is only for aarch64 Thorch systems'

if [[ -n "${source_dir}" && "${ref_set}" -eq 1 ]]; then
  fail '--source and --ref cannot be used together'
fi
if [[ -z "${source_dir}" ]]; then
  [[ "${ref}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 'invalid --ref value'
  [[ "${ref}" != *..* && "${ref}" != *//* ]] || fail 'invalid --ref value'
fi

for command in makepkg pacman python3 sudo uname; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing required command: ${command}"
done

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
build_source="${work_dir}/source"
install -d "${build_source}/packages"

if [[ -n "${source_dir}" ]]; then
  source_dir="$(cd -- "${source_dir}" && pwd -P)" || fail "cannot open source directory: ${source_dir}"
else
  archive="${work_dir}/source.tar.gz"
  extract_dir="${work_dir}/extract"
  install -d "${extract_dir}"
  url="https://codeload.github.com/${repo}/tar.gz/${ref}"
  printf 'Downloading Thorch source (%s)...\n' "${ref}"
  python3 - "${url}" "${archive}" <<'PY'
import pathlib
import sys
import urllib.request

url, destination = sys.argv[1:]
with urllib.request.urlopen(url, timeout=120) as response:
    pathlib.Path(destination).write_bytes(response.read())
PY
  python3 - "${archive}" "${extract_dir}" <<'PY'
import pathlib
import sys
import tarfile

archive, destination = map(pathlib.Path, sys.argv[1:])
with tarfile.open(archive, "r:gz") as source:
    source.extractall(destination, filter="data")
roots = [path for path in destination.iterdir() if path.is_dir()]
if len(roots) != 1:
    raise SystemExit("downloaded source archive has an unexpected layout")
PY
  source_dir="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
fi

for package_dir in thorch-kwin thorch-plasma-keyboard; do
  [[ -f "${source_dir}/packages/${package_dir}/PKGBUILD" ]] ||
    fail "source tree is missing packages/${package_dir}/PKGBUILD"
  cp -a -- "${source_dir}/packages/${package_dir}" "${build_source}/packages/"
done

sudo -v
printf 'Installing package build tools if needed...\n'
sudo pacman -S --needed --noconfirm -- base-devel

packages=()
for package_dir in thorch-kwin thorch-plasma-keyboard; do
  directory="${build_source}/packages/${package_dir}"
  package_file="$(cd -- "${directory}" && PKGDEST="${directory}" makepkg --packagelist)"
  printf 'Building %s...\n' "$(basename -- "${package_file}")"
  (
    cd -- "${directory}"
    PKGDEST="${directory}" makepkg --cleanbuild --syncdeps --noconfirm
  )
  [[ -f "${package_file}" ]] || fail "package build did not create ${package_file}"
  packages+=("${package_file}")
done

printf '\nPacman will ask to replace stock kwin and plasma-keyboard. Answer yes.\n'
sudo pacman -U -- "${packages[@]}"

keyboard_is_repaired || fail 'package installation finished, but the stock packages still own the keyboard files'

cat <<'EOF'

Thorch's compositor and keyboard packages are restored.
Log out and back in, or reboot, before testing the on-screen keyboard.
EOF
