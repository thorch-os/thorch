# Base repository snapshot policy

Thorch updates are full `pacman -Syu` transactions. A stable candidate is
therefore defined by both the Thorch artifact and the exact Arch Linux ARM
(ALARM) repository databases and packages used during qualification. Testing
against a live base mirror and later serving a different mirror state is not an
exactly tested release and cannot provide coherent package rollback.

`manifests/base-snapshot-policy.json` is the machine-enforced schema-2 policy:

- stable may not use a moving upstream repository;
- capture includes the complete default ALARM aarch64 repository set: `core`,
  `extra`, `alarm`, and `aur`;
- every package named by each database is retained with its detached signature;
- each staged package must match that database entry's `%CSIZE%` and
  `%SHA256SUM%` before its signature is accepted;
- `gpgv` must report exactly one `VALIDSIG`, and its signing or primary key
  fingerprint must match the policy allowlist. The production policy pins
  `68B3537F39A313B3E574D06777193F152BDBE6A6`, as published on the
  [ALARM package-signing page](https://archlinuxarm.org/about/package-signing);
- the cohort manifest records the observed package signing and primary
  fingerprints, database digests, and every retained file digest;
- promotion copies and re-verifies exact bytes rather than rebuilding packages;
  and
- stable requires a distinct qualified or previous-stable rollback cohort.

Schema-1 policies, cohorts, qualifications, and channel records are not accepted
by the schema-2 verifier. Existing material must be recaptured and requalified;
silently upgrading an old manifest would claim trust evidence that was never
collected.

## Unsigned ALARM repository databases

ALARM repository databases are unsigned. A package signature authenticates the
package bytes and signer, but it does not authenticate which package inventory
the mirror chose to put in an unsigned database. Capture consequently requires
the explicit `--assert-trusted-mirror-inventory` flag. That assertion means a
trusted operator has selected and reviewed the intended mirror inventory. The
tool binds the assertion to every copied repository database SHA-256 in
`cohort.json`. Missing assertions, changed database digests, or unexpected
database `.sig` files are rejected.

This is deliberately an assertion, not a synthetic signature. It must not be
described as upstream-authenticated metadata.

## Capture and verification

Use a keyring whose provenance has been checked independently. Merely adding a
key to the keyring does not authorize it: the fingerprint also has to appear in
the active policy.

```text
scripts/base-snapshot.py create \
  --cohort 2026-07-15.1 \
  --output-root output/base-snapshots \
  --assert-trusted-mirror-inventory \
  --keyring /etc/pacman.d/gnupg/pubring.gpg \
  --repo core=/srv/alarm/core \
  --repo extra=/srv/alarm/extra \
  --repo alarm=/srv/alarm/alarm \
  --repo aur=/srv/alarm/aur

scripts/base-snapshot.py verify \
  output/base-snapshots/cohorts/2026-07-15.1 \
  --keyring /etc/pacman.d/gnupg/pubring.gpg
```

Capture first copies the database, parses those immutable staged bytes, and
then validates the copied packages against them. This ordering closes the
same-filename moving-mirror race: a newly signed package that differs from the
captured database's size or digest is rejected. Verification repeats the
database metadata and package signature checks.

The repository set comes from the enabled sections in ALARM's packaged
`/etc/pacman.conf`. If that default changes, the machine policy must change and
a new cohort must be qualified. “Complete” means the database plus every
package it names at capture time; historical packages absent from that database
are outside the cohort.

## Typed qualification evidence

Each required evidence input is JSON, not arbitrary TAP or prose. The schema-2
policy currently requires records named and typed `hardware` and `upgrade`.
Each document must use this contract:

```json
{
  "schema_version": 1,
  "cohort": "2026-07-15.1",
  "cohort_content_identity": "<64-lowercase-hex>",
  "name": "hardware",
  "type": "hardware",
  "result": "pass",
  "thorch_artifact_sha256": "<64-lowercase-hex>"
}
```

The name, type, cohort, cohort content identity, and exact `result=pass` value
are enforced. All evidence documents in one qualification must bind the same
Thorch artifact SHA-256. Failed, mistyped, mismatched, malformed, or reused
evidence is rejected.

M2 evidence signing is not available yet. Until it is, qualification requires
the explicit `--assert-manual-trust` flag and persists
`signing_status=m2-signing-unavailable` with the manual trust assertion. The
flag means the operator has reviewed the typed evidence and accepts it for the
named cohort and Thorch digest; it does not make the evidence cryptographically
signed.

```text
scripts/base-snapshot.py qualify \
  output/base-snapshots/cohorts/2026-07-15.1 \
  --assert-manual-trust \
  --keyring /etc/pacman.d/gnupg/pubring.gpg \
  --evidence upgrade=output/evidence/upgrade.json \
  --evidence hardware=output/evidence/hardware.json
```

Qualification is append-only through the tool. The copied evidence bytes,
their digests, the cohort manifest digest, the cohort content identity, and the
Thorch artifact digest are recorded in `qualification.json` and rechecked on
every subsequent verification or promotion.

Evidence is staged outside the immutable cohort. Before publication, the tool
writes a durable qualification-intent journal containing the verified cohort
identity, manifest digest, Thorch artifact digest, staging name, and every
evidence digest. If the process is killed after that journal or evidence rename
but before the durable `qualification.json` rename, the next `qualify`
invocation first verifies the cohort signatures and every journal-bound byte,
then atomically moves that proven incomplete tree to a journaled discard path,
clears the intent, and retries. Repeated interruption during discard is
recoverable, and pre-intent staging is removed only after the immutable cohort
verifies. JSON write temporaries use the same reserved sibling namespace, and
source/destination parent directories are fsynced around each cross-directory
rename. A per-cohort lock prevents concurrent qualifiers from racing those
states. Evidence
without a valid intent is not cleaned automatically: deleting
`qualification.json` from a completed cohort remains detectable tampering, not
an inferred crash window. Once `qualification.json` exists, missing or changed
evidence is likewise never repaired automatically.

## Retention, rollback, and promotion

A cohort's directory basename must equal `cohort.json`'s `cohort` value. Its
`content_identity` is a canonical SHA-256 over the architecture and immutable
repository file records. Retention requires at least the policy minimum of
distinct content identities, so renaming or copying one cohort cannot satisfy
the rollback count.

The stable candidate must itself have valid passing qualification. It must also
have another retained cohort with a different content identity that either:

1. has valid passing qualification, or
2. exactly matches the currently published stable channel's cohort name,
   content identity, and cohort-manifest digest.

The second case allows the current stable bytes to serve as the rollback when
they become `.stable.previous`. Re-promoting the already-current content
identity is rejected. Channel metadata records the cohort manifest digest,
content identity, and, for stable, the qualified Thorch artifact digest.

Replacing an existing channel uses Linux `renameat2(RENAME_EXCHANGE)`, so the
public channel directory is never absent between two renames. Before the
exchange, a durable journal records the verified old and new identities and
the private swap-directory name. On the next promotion invocation, recovery
compares the published identity with those journaled values: an interruption
before the exchange discards only the unpublished candidate, while an
interruption after it moves the verified old channel to `.stable.previous`.
Unknown or inconsistent state fails closed. The initial publication is one
atomic rename. A publisher filesystem/kernel without `RENAME_EXCHANGE` support
cannot replace an existing channel with this tool. A persistent per-channel
file lock serializes publishers before recovery or journal creation, and both
post-exchange identities are reverified before the old tree becomes
`.stable.previous`.

```text
scripts/base-snapshot.py retention-check \
  --output-root output/base-snapshots \
  --keyring /etc/pacman.d/gnupg/pubring.gpg

scripts/base-snapshot.py promote \
  output/base-snapshots/cohorts/2026-07-15.1 \
  --channels-root output/base-snapshots/channels \
  --channel stable \
  --keyring /etc/pacman.d/gnupg/pubring.gpg
```

The tool never prunes cohorts. Deletion remains a separate operator decision
after the supported-device and recovery windows prove that the cohort is no
longer needed.

## Residual trust boundary

The exact remaining non-cryptographic boundary is two trusted-operator claims:

1. the SHA-256-bound unsigned ALARM database inventory is the intended mirror
   state; and
2. the unsigned M2 hardware and upgrade evidence genuinely represents passing
   tests for the recorded cohort identity and Thorch artifact digest.

An attacker controlling an ALARM mirror could still present a coherent chosen
inventory of otherwise validly signed packages, including an older inventory,
and the tool cannot distinguish that from the operator-selected inventory
without authenticated upstream database metadata. Likewise, a compromised or
mistaken qualification operator could assert false evidence until M2 evidence
signing is introduced. The policy file, trusted keyring provenance, publishing
host, and channel filesystem also remain part of the administrative trust base.
Package byte integrity, signer authorization, evidence/cohort binding, copied
byte integrity, and rollback identity are mechanically verified within that
boundary.
