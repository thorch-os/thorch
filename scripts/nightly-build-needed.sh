#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  printf 'usage: %s <current-commit> [previous-build-manifest]\n' "${0##*/}" >&2
  exit 2
fi

current_commit="$1"
previous_manifest="${2:-}"

[[ "${current_commit}" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'current Thorch commit is not a full SHA: %s\n' "${current_commit}" >&2
  exit 1
}

if [[ -z "${previous_manifest}" ]]; then
  printf 'true\n'
  exit 0
fi

[[ -f "${previous_manifest}" ]] || {
  printf 'previous nightly build manifest is missing: %s\n' "${previous_manifest}" >&2
  exit 1
}

previous_commit="$(
  awk -F= '
    $1 == "THORCH_COMMIT" {
      count++
      commit = substr($0, index($0, "=") + 1)
    }
    END {
      if (count != 1) {
        exit 1
      }
      print commit
    }
  ' "${previous_manifest}"
)" || {
  printf 'previous nightly build manifest must contain exactly one THORCH_COMMIT\n' >&2
  exit 1
}

[[ "${previous_commit}" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'previous nightly manifest has an invalid Thorch commit: %s\n' \
    "${previous_commit}" >&2
  exit 1
}

if [[ "${previous_commit}" == "${current_commit}" ]]; then
  printf 'false\n'
else
  printf 'true\n'
fi
