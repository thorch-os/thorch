#!/usr/bin/env bash
set -euo pipefail

repo_dir="${1:-}"
archive_root="${2:-${repo_dir}.cohorts}"
[[ -n "${repo_dir}" ]] || {
  echo "usage: archive-package-repo.sh REPOSITORY [ARCHIVE_ROOT]" >&2
  exit 2
}
[[ -d "${repo_dir}" ]] || {
  echo "error: package repository does not exist: ${repo_dir}" >&2
  exit 1
}
[[ -e "${repo_dir}/thorch.db" ]] || exit 0

for command in awk find install mktemp mv readlink rm rsync sha256sum sort sync; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "error: ${command} is required to retain package repository bytes" >&2
    exit 1
  }
done

database="$(readlink -f "${repo_dir}/thorch.db")"
[[ -f "${database}" ]] || {
  echo "error: local repository database alias is broken" >&2
  exit 1
}
hash="$(sha256sum "${database}" | awk '{print $1}')"
destination="${archive_root}/${hash}"
if [[ -d "${destination}" ]]; then
  (cd "${destination}" && sha256sum -c SHA256SUMS >/dev/null) || {
    echo "error: retained local repository archive is corrupt: ${destination}" >&2
    exit 1
  }
  [[ -z "$(rsync -aL --omit-dir-times --checksum --dry-run --itemize-changes --delete \
    --exclude='.thorch-inputs/' --exclude=SHA256SUMS \
    "${repo_dir}/" "${destination}/")" ]] || {
    echo "error: local repository bytes changed without a database identity change" >&2
    exit 1
  }
  printf '%s\n' "${destination}"
  exit 0
fi

install -d "${archive_root}"
staging="$(mktemp -d "${archive_root}/.${hash}.XXXXXX")"
cleanup() {
  [[ -z "${staging:-}" ]] || rm -rf "${staging}"
}
trap cleanup EXIT

# These are unsigned developer-build archives, not release cohorts. Copy
# aliases as regular files so the archive is self-contained if repo_dir is
# later regenerated.
rsync -aL --omit-dir-times --exclude='.thorch-inputs/' \
  "${repo_dir}/" "${staging}/"
(
  cd "${staging}"
  while IFS= read -r -d '' file; do
    sha256sum "${file#./}"
  done < <(find . -type f ! -name SHA256SUMS -print0 | sort -z)
) > "${staging}/SHA256SUMS"
sync -f "${staging}/SHA256SUMS"
mv "${staging}" "${destination}"
staging=
sync -f "${archive_root}"
printf '%s\n' "${destination}"
