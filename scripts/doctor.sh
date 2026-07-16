#!/usr/bin/env bash
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
warnings=0

usage() {
  cat <<'EOF'
Usage: scripts/doctor.sh

Report whether this host can run the fast contributor checks and show the
supported next command. The command exits non-zero when required tools or a
supported host are missing.
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

value() {
  printf '  %-24s %s\n' "$1" "$2"
}

warn() {
  printf '  WARN: %s\n' "$*"
  warnings=$((warnings + 1))
}

fail() {
  printf '  FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

resolve_tool() {
  tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    command -v "${tool}"
    return 0
  fi
  if [[ -x "/usr/lib/qt6/bin/${tool}" ]]; then
    printf '/usr/lib/qt6/bin/%s\n' "${tool}"
    return 0
  fi
  return 1
}

host_os="$(uname -s 2>/dev/null || printf unknown)"
host_arch="$(uname -m 2>/dev/null || printf unknown)"
bash_major="${BASH_VERSINFO[0]:-0}"

printf 'Thorch contributor environment\n'
value "repository" "${root}"
value "host" "${host_os} ${host_arch}"
value "Bash" "${BASH_VERSION:-unknown}"
value "effective uid" "${EUID:-unknown}"

if (( bash_major < 4 )); then
  fail "Bash 4 or newer is required (the system Bash is too old)"
fi

case "${host_os}/${host_arch}" in
  Linux/x86_64|Linux/amd64)
    value "native fast CI" "supported when every required tool below is present"
    ;;
  *)
    value "native fast CI" "not in the supported host matrix"
    fail "use a Linux x86_64 development environment or the pull-request CI workflow"
    ;;
esac

if [[ "${EUID:-1}" -eq 0 ]]; then
  warn "make ci is intended to run as an unprivileged user"
fi

printf '\nRequired by make ci\n'
while IFS= read -r tool; do
  if path="$(resolve_tool "${tool}")"; then
    value "${tool}" "${path}"
  else
    value "${tool}" "MISSING"
    failures=$((failures + 1))
  fi
done < <("${root}/scripts/ci.sh" --list-tools)

printf '\nContainer provider (full image/integration work)\n'
container_ready=0
for provider in docker podman; do
  if command -v "${provider}" >/dev/null 2>&1; then
    provider_path="$(command -v "${provider}")"
    if "${provider}" info >/dev/null 2>&1; then
      value "${provider}" "${provider_path} (daemon ready)"
      container_ready=1
    else
      value "${provider}" "${provider_path} (installed; daemon unavailable)"
    fi
  fi
done
if (( container_ready == 0 )); then
  warn "no ready Docker or Podman provider was found"
fi

printf '\nPrivilege diagnostics (integration/image tier only)\n'
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    value "non-interactive sudo" "available"
  else
    value "non-interactive sudo" "not available"
  fi
else
  value "sudo" "not installed"
fi

if [[ "${host_os}" == "Linux" ]]; then
  if [[ -e /dev/loop-control ]]; then
    if [[ -r /dev/loop-control && -w /dev/loop-control ]]; then
      value "loop control" "read/write"
    else
      value "loop control" "present; elevated access required"
    fi
  else
    value "loop control" "not present"
  fi
else
  value "loop control" "not applicable on ${host_os}"
fi

printf '\nRecommendation\n'
if (( failures == 0 )); then
  printf '  Environment is ready. Run: make ci\n'
else
  printf '  Environment is not ready for make ci (%d problem(s)).\n' "${failures}"
  if [[ "${host_os}/${host_arch}" == "Linux/x86_64" || "${host_os}/${host_arch}" == "Linux/amd64" ]]; then
    printf '  Install the missing tools listed above (see scripts/ci.sh --list-tools), then rerun make doctor.\n'
  else
    printf '  Use Linux x86_64 or open a pull request and use the pinned rootless CI job.\n'
  fi
fi

printf '\nDoctor result: %d problem(s), %d warning(s)\n' "${failures}" "${warnings}"
(( failures == 0 ))
