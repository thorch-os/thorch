#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if ! command -v rustc >/dev/null 2>&1; then
  printf 'SKIP: rustc not available\n'
  exit 0
fi

components=(
  "packages/thorch-bsp/inputd/thorch-inputd.rs"
)

for source in "${components[@]}"; do
  name="${source##*/}"
  name="${name%.rs}"
  binary="${tmp}/${name}-tests"

  printf '== rust unit: %s ==\n' "${source}"
  rustc --test "${root}/${source}" --edition=2021 -C opt-level=0 -o "${binary}"
  "${binary}" --test-threads=1
done
