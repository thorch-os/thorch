#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${root}/scripts/base-snapshot.py"
work="$(mktemp -d)"
trusted_home="${work}/trusted-gnupg"
unallowed_home="${work}/unallowed-gnupg"
keyring="${work}/combined.gpg"
fixture_policy="${work}/fixture-policy.json"

cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

for command in fakeroot gpg gpgv pacman python3 timeout; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'SKIP: %s is required for base snapshot integration\n' "${command}"
    exit 0
  }
done

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

install -d -m 0700 "${trusted_home}" "${unallowed_home}"
gpg --homedir "${trusted_home}" --batch --pinentry-mode loopback \
  --passphrase '' --quick-generate-key \
  'Thorch trusted fixture <trusted@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
gpg --homedir "${unallowed_home}" --batch --pinentry-mode loopback \
  --passphrase '' --quick-generate-key \
  'Thorch unallowed fixture <unallowed@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
trusted_fingerprint="$(
  gpg --homedir "${trusted_home}" --batch --with-colons --fingerprint |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
gpg --homedir "${trusted_home}" --batch --export > "${keyring}"
gpg --homedir "${unallowed_home}" --batch --export >> "${keyring}"

# Production policy pins the authoritative ALARM signer. The isolated fixture
# substitutes only the generated test signer while retaining every other byte
# of the production policy contract.
python3 - "${root}/manifests/base-snapshot-policy.json" \
  "${fixture_policy}" "${trusted_fingerprint}" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
fixture_fingerprint = sys.argv[3]
policy = json.loads(source.read_text())
assert policy["allowed_package_signer_fingerprints"] == [
    "68B3537F39A313B3E574D06777193F152BDBE6A6"
]
policy["allowed_package_signer_fingerprints"] = [fixture_fingerprint]
destination.write_text(json.dumps(policy, indent=2) + "\n")
PY
snapshot=(python3 "${tool}" --policy "${fixture_policy}")

sign_file() {
  local home="$1" path="$2"
  gpg --homedir "${home}" --batch --yes --pinentry-mode loopback \
    --passphrase '' --detach-sign --output "${path}.sig" "${path}"
}

make_repo() {
  local directory="$1" repo="$2" package="$3" payload="$4"
  install -d "${directory}"
  printf '%s\n' "${payload}" > "${directory}/${package}"
  sign_file "${trusted_home}" "${directory}/${package}"
  python3 - "${directory}/${repo}.db.tar.gz" \
    "${directory}/${package}" "${package}" <<'PY'
import hashlib
import io
import pathlib
import tarfile
import sys

database = pathlib.Path(sys.argv[1])
package = pathlib.Path(sys.argv[2])
filename = sys.argv[3]
payload = package.read_bytes()
desc = (
    "%NAME%\nfixture\n\n"
    "%VERSION%\n1-1\n\n"
    f"%FILENAME%\n{filename}\n\n"
    f"%CSIZE%\n{len(payload)}\n\n"
    f"%SHA256SUM%\n{hashlib.sha256(payload).hexdigest()}\n\n"
).encode()
with tarfile.open(database, "w:gz") as archive:
    info = tarfile.TarInfo("fixture-1-1/desc")
    info.size = len(desc)
    archive.addfile(info, io.BytesIO(desc))
PY
}

write_evidence() {
  local cohort="$1" name="$2" evidence_type="$3" result="$4"
  local artifact_sha256="$5" destination="$6"
  python3 - "${cohort}/cohort.json" "${name}" "${evidence_type}" \
    "${result}" "${artifact_sha256}" "${destination}" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
document = {
    "schema_version": 1,
    "cohort": manifest["cohort"],
    "cohort_content_identity": manifest["content_identity"],
    "name": sys.argv[2],
    "type": sys.argv[3],
    "result": sys.argv[4],
    "thorch_artifact_sha256": sys.argv[5],
}
pathlib.Path(sys.argv[6]).write_text(json.dumps(document, indent=2) + "\n")
PY
}

repositories=(core extra alarm aur)
cohort_one_repos=()
cohort_two_repos=()
for repo in "${repositories[@]}"; do
  make_repo "${work}/source-one/${repo}" "${repo}" \
    "${repo}-fixture-1-1-aarch64.pkg.tar.zst" "first-${repo}"
  make_repo "${work}/source-two/${repo}" "${repo}" \
    "${repo}-fixture-2-1-aarch64.pkg.tar.zst" "second-${repo}"
  cohort_one_repos+=(--repo "${repo}=${work}/source-one/${repo}")
  cohort_two_repos+=(--repo "${repo}=${work}/source-two/${repo}")
done

if "${snapshot[@]}" create --cohort missing-assertion \
    --output-root "${work}/missing-assertion" --keyring "${keyring}" \
    "${cohort_one_repos[@]}" >/dev/null 2>&1; then
  fail "capture accepted unsigned ALARM databases without an operator assertion"
fi

cohort_one="$("${snapshot[@]}" create \
  --cohort 2026-07-15.1 \
  --output-root "${work}/publish" \
  --assert-trusted-mirror-inventory \
  --keyring "${keyring}" \
  "${cohort_one_repos[@]}")"
"${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" |
  grep -q 'base snapshot valid' || fail "captured cohort did not verify"

python3 - "${cohort_one}/cohort.json" "${trusted_fingerprint}" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest["mirror_inventory_assertion"]["asserted"] is True
for repository in manifest["repositories"]:
    assert repository["database_sha256"]
    assert repository["package_signers"] == [
        {
            "primary_fingerprint": sys.argv[2],
            "signing_fingerprint": sys.argv[2],
        }
    ]
PY

# The unsigned-database assertion is bound to the exact copied database
# digests and cannot be edited independently of the cohort.
cp "${cohort_one}/cohort.json" "${work}/saved-cohort.json"
python3 - "${cohort_one}/cohort.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["mirror_inventory_assertion"]["repositories"][0]["database_sha256"] = "0" * 64
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
if "${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" \
    >/dev/null 2>&1; then
  fail "verification accepted a mirror assertion detached from its database digest"
fi
cp "${work}/saved-cohort.json" "${cohort_one}/cohort.json"
"${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" >/dev/null

# A captured repository exposes the exact endpoint pacman requests, not only
# the archive's long filename.
install -d "${work}/pacman-db" "${work}/pacman-cache"
cat > "${work}/pacman.conf" <<EOF
[options]
Architecture = aarch64
DBPath = ${work}/pacman-db/
CacheDir = ${work}/pacman-cache/
LogFile = ${work}/pacman.log
SigLevel = Never
DisableSandbox

[core]
Server = file://${cohort_one}/repos/core/aarch64
EOF
pacman_command=(pacman)
if [[ "${EUID}" -ne 0 ]]; then
  pacman_command=(fakeroot pacman)
fi
"${pacman_command[@]}" --config "${work}/pacman.conf" --noconfirm -Sy >/dev/null ||
  fail "pacman could not synchronize the captured core.db endpoint"
[[ -s "${work}/pacman-db/sync/core.db" ]] ||
  fail "pacman did not retain the snapshot database"

if "${snapshot[@]}" create --cohort 2026-07-15.1 \
    --output-root "${work}/publish" --assert-trusted-mirror-inventory \
    --keyring "${keyring}" "${cohort_one_repos[@]}" >/dev/null 2>&1; then
  fail "immutable cohort identifier was overwritten"
fi

if "${snapshot[@]}" create --cohort incomplete --output-root "${work}/incomplete" \
    --assert-trusted-mirror-inventory --keyring "${keyring}" \
    --repo "core=${work}/source-one/core" >/dev/null 2>&1; then
  fail "snapshot capture accepted an incomplete repository set"
fi

if "${snapshot[@]}" promote "${cohort_one}" \
    --channels-root "${work}/channels" --channel stable \
    --keyring "${keyring}" >/dev/null 2>&1; then
  fail "unqualified cohort was promoted to stable"
fi

captured_package="${cohort_one}/repos/core/aarch64/core-fixture-1-1-aarch64.pkg.tar.zst"
cp "${captured_package}" "${work}/saved-package"
printf 'tampered\n' >> "${captured_package}"
if "${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" \
    >/dev/null 2>&1; then
  fail "cohort verifier accepted a changed package"
fi
cp "${work}/saved-package" "${captured_package}"
"${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" >/dev/null

# Simulate a moving-mirror race: the filename and allowed signature are valid,
# but the package bytes no longer match CSIZE/SHA256SUM in the copied database.
cp -a "${work}/source-one" "${work}/source-db-tamper"
tampered_source="${work}/source-db-tamper/core/core-fixture-1-1-aarch64.pkg.tar.zst"
printf 'mirror-race\n' >> "${tampered_source}"
sign_file "${trusted_home}" "${tampered_source}"
tampered_repos=()
for repo in "${repositories[@]}"; do
  tampered_repos+=(--repo "${repo}=${work}/source-db-tamper/${repo}")
done
if "${snapshot[@]}" create --cohort database-race \
    --output-root "${work}/database-race" --assert-trusted-mirror-inventory \
    --keyring "${keyring}" "${tampered_repos[@]}" >/dev/null 2>&1; then
  fail "capture accepted package bytes not bound by the copied database"
fi

# Metadata fields used to bind package bytes must occur exactly once. A
# repeated marker at end-of-entry has no following value and must not evade
# duplicate-field detection.
cp -a "${work}/source-one" "${work}/source-duplicate-field"
python3 - "${work}/source-duplicate-field/core/core.db.tar.gz" <<'PY'
import io
import os
import pathlib
import sys
import tarfile

database = pathlib.Path(sys.argv[1])
replacement = database.with_suffix(database.suffix + ".new")
with tarfile.open(database, "r:*") as source, tarfile.open(replacement, "w:gz") as output:
    for member in source.getmembers():
        extracted = source.extractfile(member) if member.isfile() else None
        payload = extracted.read() if extracted is not None else None
        if member.name.endswith("/desc") and payload is not None:
            payload += b"%CSIZE%\n"
            member.size = len(payload)
        output.addfile(member, io.BytesIO(payload) if payload is not None else None)
os.replace(replacement, database)
PY
duplicate_field_repos=()
for repo in "${repositories[@]}"; do
  duplicate_field_repos+=(--repo "${repo}=${work}/source-duplicate-field/${repo}")
done
if "${snapshot[@]}" create --cohort duplicate-database-field \
    --output-root "${work}/duplicate-database-field" \
    --assert-trusted-mirror-inventory --keyring "${keyring}" \
    "${duplicate_field_repos[@]}" >/dev/null 2>&1; then
  fail "capture accepted a repeated repository database metadata field"
fi

# The keyring deliberately contains two valid keys; policy pins only the first.
cp -a "${work}/source-one" "${work}/source-unallowed"
unallowed_package="${work}/source-unallowed/core/core-fixture-1-1-aarch64.pkg.tar.zst"
sign_file "${unallowed_home}" "${unallowed_package}"
unallowed_repos=()
for repo in "${repositories[@]}"; do
  unallowed_repos+=(--repo "${repo}=${work}/source-unallowed/${repo}")
done
if "${snapshot[@]}" create --cohort unallowed-signer \
    --output-root "${work}/unallowed-signer" --assert-trusted-mirror-inventory \
    --keyring "${keyring}" "${unallowed_repos[@]}" >/dev/null 2>&1; then
  fail "capture accepted a valid signature from an unallowed key"
fi

install -d "${work}/fake-bin"
printf '#!/bin/sh\nexit 0\n' > "${work}/fake-bin/gpgv"
chmod +x "${work}/fake-bin/gpgv"
if PATH="${work}/fake-bin:${PATH}" "${snapshot[@]}" verify "${cohort_one}" \
    --keyring "${keyring}" >/dev/null 2>&1; then
  fail "verification accepted gpgv success without a VALIDSIG fingerprint"
fi

# ALARM repository databases are unsigned. Supplying a detached database
# signature is rejected so it cannot be mistaken for authenticated inventory.
cp -a "${work}/source-one" "${work}/source-signed-db"
sign_file "${trusted_home}" "${work}/source-signed-db/core/core.db.tar.gz"
signed_db_repos=()
for repo in "${repositories[@]}"; do
  signed_db_repos+=(--repo "${repo}=${work}/source-signed-db/${repo}")
done
if "${snapshot[@]}" create --cohort unexpected-database-signature \
    --output-root "${work}/signed-db" --assert-trusted-mirror-inventory \
    --keyring "${keyring}" "${signed_db_repos[@]}" >/dev/null 2>&1; then
  fail "capture accepted a database signature under the unsigned-ALARM policy"
fi

artifact_one="$(printf 'a%.0s' {1..64})"
artifact_two="$(printf 'b%.0s' {1..64})"
write_evidence "${cohort_one}" hardware hardware pass "${artifact_one}" \
  "${work}/hardware.json"
write_evidence "${cohort_one}" upgrade upgrade pass "${artifact_one}" \
  "${work}/upgrade.json"
if "${snapshot[@]}" qualify "${cohort_one}" --keyring "${keyring}" \
    --evidence "hardware=${work}/hardware.json" \
    --evidence "upgrade=${work}/upgrade.json" >/dev/null 2>&1; then
  fail "qualification accepted unsigned M2 evidence without manual trust assertion"
fi

write_evidence "${cohort_one}" upgrade upgrade fail "${artifact_one}" \
  "${work}/upgrade-failed.json"
if "${snapshot[@]}" qualify "${cohort_one}" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware.json" \
    --evidence "upgrade=${work}/upgrade-failed.json" >/dev/null 2>&1; then
  fail "qualification accepted failed evidence"
fi

write_evidence "${cohort_one}" upgrade upgrade pass "${artifact_two}" \
  "${work}/upgrade-mismatch.json"
if "${snapshot[@]}" qualify "${cohort_one}" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware.json" \
    --evidence "upgrade=${work}/upgrade-mismatch.json" >/dev/null 2>&1; then
  fail "qualification accepted evidence bound to different Thorch artifacts"
fi

"${snapshot[@]}" qualify "${cohort_one}" --assert-manual-trust \
  --keyring "${keyring}" --evidence "hardware=${work}/hardware.json" \
  --evidence "upgrade=${work}/upgrade.json" >/dev/null
[[ -s "${cohort_one}/qualification-evidence/upgrade/upgrade.json" ]] ||
  fail "qualification did not retain upgrade evidence"
[[ -s "${cohort_one}/qualification-evidence/hardware/hardware.json" ]] ||
  fail "qualification did not retain hardware evidence"
rm -f "${work}/upgrade.json" "${work}/hardware.json"
"${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" >/dev/null ||
  fail "qualification still depended on an external evidence path"
if "${snapshot[@]}" qualify "${cohort_one}" --assert-manual-trust \
    --keyring "${keyring}" \
    --evidence "upgrade=${cohort_one}/qualification-evidence/upgrade/upgrade.json" \
    --evidence "hardware=${cohort_one}/qualification-evidence/hardware/hardware.json" \
    >/dev/null 2>&1; then
  fail "append-only qualification was overwritten"
fi
cp "${cohort_one}/qualification-evidence/upgrade/upgrade.json" \
  "${work}/saved-evidence"
printf 'tampered\n' >> "${cohort_one}/qualification-evidence/upgrade/upgrade.json"
if "${snapshot[@]}" promote "${cohort_one}" --channels-root "${work}/channels" \
    --channel stable --keyring "${keyring}" >/dev/null 2>&1; then
  fail "stable promotion accepted changed qualification evidence"
fi
cp "${work}/saved-evidence" \
  "${cohort_one}/qualification-evidence/upgrade/upgrade.json"
if "${snapshot[@]}" promote "${cohort_one}" --channels-root "${work}/channels" \
    --channel stable --keyring "${keyring}" >/dev/null 2>&1; then
  fail "stable promotion accepted fewer than two retained cohorts"
fi

cohort_two="$("${snapshot[@]}" create \
  --cohort 2026-07-15.2 \
  --output-root "${work}/publish" \
  --assert-trusted-mirror-inventory \
  --keyring "${keyring}" \
  "${cohort_two_repos[@]}")"
"${snapshot[@]}" verify "${cohort_two}" --keyring "${keyring}" >/dev/null

if "${snapshot[@]}" promote "${cohort_one}" --channels-root "${work}/channels" \
    --channel stable --keyring "${keyring}" >/dev/null 2>&1; then
  fail "stable promotion accepted an unqualified rollback cohort"
fi

write_evidence "${cohort_two}" hardware hardware pass "${artifact_two}" \
  "${work}/hardware-two.json"
write_evidence "${cohort_two}" upgrade upgrade pass "${artifact_two}" \
  "${work}/upgrade-two.json"

# Recovery must verify a real cohort and a durable intent before deleting
# anything. An arbitrary directory with a qualification-like name is not
# cleanup authority.
install -d "${work}/not-a-cohort/qualification-evidence"
printf 'sentinel\n' > "${work}/not-a-cohort/qualification-evidence/sentinel"
if "${snapshot[@]}" qualify "${work}/not-a-cohort" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
    --evidence "upgrade=${work}/upgrade-two.json" >/dev/null 2>&1; then
  fail "qualification accepted an arbitrary directory"
fi
[[ -f "${work}/not-a-cohort/qualification-evidence/sentinel" ]] ||
  fail "qualification recovery deleted state before verifying a cohort"

# A kill after the journal-bound evidence directory rename but before the
# durable qualification record is recoverable on the next identical request.
stale_preintent="$(dirname "${cohort_two}")/.2026-07-15.2.qualification-stage.stale"
stale_intent_write="$(dirname "${cohort_two}")/.2026-07-15.2.qualification-intent-write.stale.tmp"
install -d "${stale_preintent}"
printf 'stale pre-intent staging\n' > "${stale_preintent}/sentinel"
printf 'partial intent JSON\n' > "${stale_intent_write}"
if THORCH_BASE_SNAPSHOT_TEST_FAILPOINT=raise-after-qualification-intent \
    "${snapshot[@]}" qualify "${cohort_two}" --assert-manual-trust \
      --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
      --evidence "upgrade=${work}/upgrade-two.json" >/dev/null 2>&1; then
  fail "qualification intent exception failpoint unexpectedly succeeded"
fi
[[ -f "${cohort_two}/.qualification-intent.json" ]] ||
  fail "ordinary post-intent failure discarded its recovery journal"
find "$(dirname "${cohort_two}")" -maxdepth 1 -type d \
  -name '.2026-07-15.2.qualification-stage.*' | grep -q . ||
  fail "ordinary post-intent failure discarded journal-bound staging"
set +e
THORCH_BASE_SNAPSHOT_TEST_FAILPOINT=after-qualification-evidence \
  "${snapshot[@]}" qualify "${cohort_two}" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
    --evidence "upgrade=${work}/upgrade-two.json" >/dev/null 2>&1
qualification_interrupt_status=$?
set -e
[[ "${qualification_interrupt_status}" -eq 87 ]] ||
  fail "qualification failpoint did not interrupt at the expected boundary"
[[ ! -e "${stale_preintent}" ]] ||
  fail "verified qualification recovery leaked pre-intent staging"
[[ ! -e "${stale_intent_write}" ]] ||
  fail "verified qualification recovery leaked a pre-intent JSON temporary"
[[ -f "${cohort_two}/.qualification-intent.json" && \
    -d "${cohort_two}/qualification-evidence" && \
    ! -e "${cohort_two}/qualification.json" ]] ||
  fail "qualification interruption did not preserve journal-bound recovery state"
stale_record_write="$(dirname "${cohort_two}")/.2026-07-15.2.qualification-record-write.stale.tmp"
printf 'partial qualification JSON\n' > "${stale_record_write}"
set +e
THORCH_BASE_SNAPSHOT_TEST_FAILPOINT=after-qualification-discard \
  "${snapshot[@]}" qualify "${cohort_two}" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
    --evidence "upgrade=${work}/upgrade-two.json" >/dev/null 2>&1
qualification_discard_status=$?
set -e
[[ "${qualification_discard_status}" -eq 88 ]] ||
  fail "qualification discard failpoint did not interrupt at the expected boundary"
[[ -f "${cohort_two}/.qualification-intent.json" && \
    ! -e "${cohort_two}/qualification-evidence" ]] ||
  fail "qualification discard interruption lost its durable recovery intent"
[[ ! -e "${stale_record_write}" ]] ||
  fail "qualification recovery leaked a pre-record JSON temporary"
find "$(dirname "${cohort_two}")" -maxdepth 1 -type d \
  -name '.2026-07-15.2.qualification-discard.*' | grep -q . ||
  fail "qualification discard interruption lost its journaled evidence bytes"
"${snapshot[@]}" qualify "${cohort_two}" --assert-manual-trust \
  --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
  --evidence "upgrade=${work}/upgrade-two.json" >/dev/null
[[ ! -e "${cohort_two}/.qualification-intent.json" ]] ||
  fail "qualification recovery left its intent journal behind"

# Deleting the record from a completed qualification is tampering, not a crash
# window. Without a matching intent, requalification fails and surviving
# evidence is not silently removed.
install -d "${work}/tampered-qualified"
cp -a "${cohort_two}" "${work}/tampered-qualified/2026-07-15.2"
tampered_qualification="${work}/tampered-qualified/2026-07-15.2"
rm "${tampered_qualification}/qualification.json"
if "${snapshot[@]}" qualify "${tampered_qualification}" --assert-manual-trust \
    --keyring "${keyring}" --evidence "hardware=${work}/hardware-two.json" \
    --evidence "upgrade=${work}/upgrade-two.json" >/dev/null 2>&1; then
  fail "qualification treated deleted completed metadata as an interrupted write"
fi
[[ -f "${tampered_qualification}/qualification-evidence/hardware/hardware-two.json" ]] ||
  fail "qualification tamper handling deleted surviving completed evidence"

"${snapshot[@]}" promote "${cohort_one}" \
  --channels-root "${work}/channels" --channel stable \
  --keyring "${keyring}" >/dev/null
cmp "${captured_package}" \
  "${work}/channels/stable/repos/core/aarch64/core-fixture-1-1-aarch64.pkg.tar.zst" ||
  fail "stable channel package differs from qualified cohort"

# A byte-for-byte copy cannot satisfy retention under another directory name.
cp -a "${cohort_one}" "${work}/publish/cohorts/copied-cohort"
if "${snapshot[@]}" retention-check --output-root "${work}/publish" \
    --keyring "${keyring}" >/dev/null 2>&1; then
  fail "retention accepted a copied cohort with a mismatched directory identity"
fi
rm -rf "${work}/publish/cohorts/copied-cohort/qualification.json" \
  "${work}/publish/cohorts/copied-cohort/qualification-evidence"
python3 - "${work}/publish/cohorts/copied-cohort/cohort.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["cohort"] = "copied-cohort"
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
if "${snapshot[@]}" retention-check --output-root "${work}/publish" \
    --keyring "${keyring}" >/dev/null 2>&1; then
  fail "retention counted two directory names with one content identity"
fi
rm -rf "${work}/publish/cohorts/copied-cohort"

# The currently published stable cohort is an acceptable rollback even if its
# retained qualification record is unavailable; provenance is checked through
# stable channel metadata and the exact retained cohort manifest digest.
rm -rf "${cohort_one}/qualification.json" \
  "${cohort_one}/qualification-evidence"

# A pre-exchange interruption leaves the published path on the old identity.
# The next invocation verifies the journal's old/new identities, discards the
# unpublished candidate, and can then perform the promotion normally.
"${snapshot[@]}" promote "${cohort_one}" \
  --channels-root "${work}/channels" --channel testing \
  --keyring "${keyring}" >/dev/null

# Publishers serialize per channel. A second invocation cannot enter recovery
# or overwrite the shared journal while another process holds the channel lock.
lock_ready="${work}/testing-lock-ready"
python3 - "${work}/channels/.testing.lock" "${lock_ready}" <<'PY' &
import fcntl
import pathlib
import sys
import time

with pathlib.Path(sys.argv[1]).open("a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(2)
PY
lock_holder=$!
for _attempt in {1..50}; do
  [[ -e "${lock_ready}" ]] && break
  sleep 0.1
done
[[ -e "${lock_ready}" ]] || fail "channel lock fixture did not become ready"
set +e
timeout 1s "${snapshot[@]}" promote "${cohort_two}" \
  --channels-root "${work}/channels" --channel testing \
  --keyring "${keyring}" >/dev/null 2>&1
lock_status=$?
set -e
[[ "${lock_status}" -eq 124 ]] ||
  fail "concurrent channel promotion was not serialized by the channel lock"
wait "${lock_holder}"
set +e
THORCH_BASE_SNAPSHOT_TEST_FAILPOINT=before-channel-exchange \
  "${snapshot[@]}" promote "${cohort_two}" \
    --channels-root "${work}/channels" --channel testing \
    --keyring "${keyring}" >/dev/null 2>&1
pre_exchange_status=$?
set -e
[[ "${pre_exchange_status}" -eq 85 ]] ||
  fail "pre-exchange failpoint did not interrupt at the expected boundary"
python3 - "${work}/channels/testing/channel.json" <<'PY'
import json
import pathlib
import sys

channel = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert channel["cohort"] == "2026-07-15.1"
PY
"${snapshot[@]}" promote "${cohort_two}" \
  --channels-root "${work}/channels" --channel testing \
  --keyring "${keyring}" >/dev/null

# RENAME_EXCHANGE makes the new stable and old stable swap atomically. A kill
# immediately afterwards must still leave stable present; the next invocation
# moves the verified old identity to .stable.previous before rejecting a
# redundant promotion of the already-published candidate.
set +e
THORCH_BASE_SNAPSHOT_TEST_FAILPOINT=after-channel-exchange \
  "${snapshot[@]}" promote "${cohort_two}" \
    --channels-root "${work}/channels" --channel stable \
    --keyring "${keyring}" >/dev/null 2>&1
post_exchange_status=$?
set -e
[[ "${post_exchange_status}" -eq 86 ]] ||
  fail "post-exchange failpoint did not interrupt at the expected boundary"
[[ -d "${work}/channels/stable" ]] ||
  fail "atomic exchange interruption made stable unavailable"
if "${snapshot[@]}" promote "${cohort_two}" \
    --channels-root "${work}/channels" --channel stable \
    --keyring "${keyring}" >/dev/null 2>&1; then
  fail "recovery accepted a redundant promotion of current stable"
fi
[[ ! -e "${work}/channels/.stable.promotion.json" ]] ||
  fail "stable recovery left its promotion journal behind"
python3 - "${work}/channels/.stable.previous/channel.json" \
  "${work}/channels/stable/channel.json" <<'PY'
import json
import pathlib
import sys

previous = json.loads(pathlib.Path(sys.argv[1]).read_text())
current = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert previous["cohort"] == "2026-07-15.1"
assert current["cohort"] == "2026-07-15.2"
assert previous["content_identity"] != current["content_identity"]
PY

ln -s /etc/passwd "${cohort_one}/unexpected-link"
if "${snapshot[@]}" verify "${cohort_one}" --keyring "${keyring}" \
    >/dev/null 2>&1; then
  fail "cohort verifier accepted a symbolic-link injection"
fi
rm -f "${cohort_one}/unexpected-link"
"${snapshot[@]}" retention-check --output-root "${work}/publish" \
  --keyring "${keyring}" | grep -q '2 cohorts' ||
  fail "retention policy did not require two distinct complete cohorts"

rm "${work}/source-two/core/core-fixture-2-1-aarch64.pkg.tar.zst.sig"
if "${snapshot[@]}" create --cohort unsigned --output-root "${work}/unsigned" \
    --assert-trusted-mirror-inventory --keyring "${keyring}" \
    "${cohort_two_repos[@]}" >/dev/null 2>&1; then
  fail "snapshot capture accepted an unsigned package"
fi

if "${snapshot[@]}" create --cohort traversal --output-root "${work}/traversal" \
    --architecture '../../../../../escape' --assert-trusted-mirror-inventory \
    --keyring "${keyring}" --repo "core=${work}/source-one/core" \
    >/dev/null 2>&1; then
  fail "snapshot capture accepted an architecture traversal"
fi
[[ ! -e "${work}/traversal" ]] ||
  fail "invalid architecture wrote files before validation"

# Cohorts are bound to the exact reviewed policy bytes, not merely a caller's
# relaxed or differently formatted interpretation of similar fields.
cp "${fixture_policy}" "${work}/alternate-policy.json"
printf '\n' >> "${work}/alternate-policy.json"
alternate="$(python3 "${tool}" --policy "${work}/alternate-policy.json" create \
  --cohort alternate --output-root "${work}/alternate" \
  --assert-trusted-mirror-inventory --keyring "${keyring}" \
  "${cohort_one_repos[@]}")"
if "${snapshot[@]}" promote "${alternate}" --channels-root "${work}/channels" \
    --channel testing --keyring "${keyring}" >/dev/null 2>&1; then
  fail "promotion accepted a cohort captured under different policy bytes"
fi

printf 'thorch qualified base snapshot checks passed\n'
