#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
ruleset="${root}/.github/rulesets/main.json"
api_version=2026-03-10
mode="${1:---check}"
repository="${2:-}"

usage() {
  cat >&2 <<'EOF'
usage: scripts/configure-github-repository.sh --validate
       scripts/configure-github-repository.sh --check [OWNER/REPO]
       scripts/configure-github-repository.sh --apply OWNER/REPO

Validate, inspect, or explicitly apply the versioned main-branch ruleset.
--apply changes GitHub repository settings and requires repository
Administration:write permission; it is never run by CI.
EOF
}

validate_ruleset() {
  python3 - "${ruleset}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if data.get("enforcement") != "active":
    raise SystemExit("ruleset must be active")
if data.get("conditions", {}).get("ref_name", {}).get("include") != ["~DEFAULT_BRANCH"]:
    raise SystemExit("ruleset must target only the default branch")
rules = {rule.get("type"): rule for rule in data.get("rules", [])}
for required in ("deletion", "non_fast_forward", "pull_request", "required_status_checks"):
    if required not in rules:
        raise SystemExit(f"ruleset is missing {required}")
pull_request = rules["pull_request"].get("parameters", {})
if pull_request.get("required_approving_review_count") != 0:
    raise SystemExit("single-maintainer bootstrap must not require an unavailable reviewer")
if pull_request.get("required_review_thread_resolution") is not True:
    raise SystemExit("review conversations must be resolved")
checks = rules["required_status_checks"].get("parameters", {})
if checks.get("required_status_checks") != [{"context": "ci"}]:
    raise SystemExit("the aggregate ci check must be required")
if checks.get("strict_required_status_checks_policy") is not True:
    raise SystemExit("required checks must run against the latest target branch")
print(f"repository ruleset valid: {path}")
PY
}

case "${mode}" in
  --validate)
    [[ "$#" -eq 1 ]] || { usage; exit 2; }
    validate_ruleset
    exit 0
    ;;
  --check)
    [[ "$#" -le 2 ]] || { usage; exit 2; }
    ;;
  --apply)
    [[ "$#" -eq 2 ]] || { usage; exit 2; }
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

validate_ruleset >/dev/null
command -v gh >/dev/null 2>&1 || {
  echo "error: gh is required for ${mode}" >&2
  exit 2
}
if [[ -z "${repository}" ]]; then
  repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "error: invalid OWNER/REPO: ${repository}" >&2
  exit 2
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
list="${work}/rulesets.json"
actual="${work}/actual.json"
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: ${api_version}" \
  "repos/${repository}/rulesets?includes_parents=false&per_page=100" > "${list}"
ruleset_id="$({
  python3 - "${list}" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "${ruleset}")" <<'PY'
import json
import pathlib
import sys

items = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
matches = [str(item["id"]) for item in items if item.get("name") == sys.argv[2]]
if len(matches) > 1:
    raise SystemExit("more than one matching repository ruleset exists")
print(matches[0] if matches else "")
PY
} )"

if [[ "${mode}" == "--apply" ]]; then
  if [[ -n "${ruleset_id}" ]]; then
    gh api --method PUT \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: ${api_version}" \
      "repos/${repository}/rulesets/${ruleset_id}" \
      --input "${ruleset}" > "${actual}"
    echo "updated ${repository} ruleset ${ruleset_id}"
  else
    gh api --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: ${api_version}" \
      "repos/${repository}/rulesets" \
      --input "${ruleset}" > "${actual}"
    echo "created ${repository} ruleset"
  fi
  ruleset_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${actual}")"
fi

[[ -n "${ruleset_id}" ]] || {
  echo "error: ${repository} has no 'Thorch main protection' ruleset; run --apply explicitly" >&2
  exit 1
}
gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: ${api_version}" \
  "repos/${repository}/rulesets/${ruleset_id}?includes_parents=false" > "${actual}"
python3 - "${ruleset}" "${actual}" "${repository}" <<'PY'
import json
import pathlib
import sys

expected = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
actual = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
keys = ("name", "target", "enforcement", "bypass_actors", "conditions", "rules")
observed = {key: actual.get(key) for key in keys}
if observed != expected:
    print(f"error: {sys.argv[3]} ruleset differs from the versioned policy", file=sys.stderr)
    print(json.dumps(observed, indent=2, sort_keys=True), file=sys.stderr)
    raise SystemExit(1)
print(f"repository ruleset matches: {sys.argv[3]}")
PY
