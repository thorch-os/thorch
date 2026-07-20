#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-copy-fancontrol-package.sh [options] <user@host>

Build only the thorch-bsp package, which contains thorch-fancontrol, copy the
package to a Thorch device over scp, and print the manual pacman install steps.

Options:
  --dest <dir>   Remote directory to copy into. Default: /tmp
  --no-build     Reuse the newest local thorch-bsp package from output/repo.
  -h, --help     Show this help.

Examples:
  scripts/build-copy-fancontrol-package.sh thorch@192.168.1.42
  scripts/build-copy-fancontrol-package.sh --dest /home/thorch thorch@thorch.local
EOF
}

remote=""
remote_dir="/tmp"
build=1

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ "$#" -ge 2 ]] || die "--dest requires a remote directory"
      remote_dir="$2"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      die "unknown argument: $1"
      ;;
    *)
      [[ -z "${remote}" ]] || die "only one target host can be supplied"
      remote="$1"
      shift
      ;;
  esac
done

[[ -n "${remote}" ]] || {
  usage
  die "target host is required, for example thorch@192.168.1.42"
}
[[ "${remote_dir}" = /* ]] || die "--dest must be an absolute path on the device"

if ! command -v nproc >/dev/null 2>&1; then
  nproc() {
    sysctl -n hw.ncpu 2>/dev/null || printf '1\n'
  }
fi
load_thorch_config

root="$(repo_root)"
if [[ "${THORCH_LOCAL_REPO_DIR}" = /* ]]; then
  repo_dir="${THORCH_LOCAL_REPO_DIR%/}"
else
  repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"
fi

latest_bsp_package() {
  local pkg newest=""

  shopt -s nullglob
  for pkg in "${repo_dir}"/thorch-bsp-*.pkg.tar.*; do
    [[ "${pkg}" == *.sig ]] && continue
    if [[ -z "${newest}" || "${pkg}" -nt "${newest}" ]]; then
      newest="${pkg}"
    fi
  done
  shopt -u nullglob

  [[ -n "${newest}" ]] || return 1
  printf '%s\n' "${newest}"
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

run_package_build() {
  local -a build_cmd=("${script_dir}/build-packages.sh" --skip-kernel --packages thorch-bsp)
  local preserve_env

  preserve_env="$(
    IFS=,
    printf '%s' \
      "THORCH_BUILD_DIR,THORCH_OUTPUT_DIR,THORCH_LOCAL_REPO_DIR,"\
"ALARM_ROOTFS_URL,ALARM_ROOTFS_SIG_URL,ALARM_ROOTFS_SHA256,"\
"ALARM_ROOTFS_SIGNING_KEYS,ALARM_ROOTFS_KEYRING_URL,ALARM_ROOTFS_KEYSERVER,"\
"ALARM_ROOTFS_KEY_FETCH_TIMEOUT,ALARM_MIRRORS,ALARM_MIRROR"
  )"

  if [[ "${EUID}" -eq 0 ]]; then
    "${build_cmd[@]}"
  else
    sudo --preserve-env="${preserve_env}" "${build_cmd[@]}"
  fi
}

require_cmd scp ssh

if [[ "${build}" -eq 1 ]]; then
  log "building thorch-bsp package"
  run_package_build
fi

pkg="$(latest_bsp_package)" || die "no thorch-bsp package found in ${repo_dir}; run without --no-build first"
remote_pkg="${remote_dir%/}/$(basename "${pkg}")"

log "copying ${pkg##*/} to ${remote}:${remote_dir%/}/"
ssh "${remote}" "mkdir -p -- $(shell_quote "${remote_dir}")"
scp "${pkg}" "${remote}:${remote_dir%/}/"

cat <<EOF

Copied package:
  ${remote}:${remote_pkg}

Install it manually on the device:
  sudo pacman -U ${remote_pkg}
  sudo systemctl daemon-reload
  sudo systemctl enable thorch-fancontrol.service
  sudo systemctl restart thorch-fancontrol.service
  sudo thorch-fancontrol status
EOF
