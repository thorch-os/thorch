#!/usr/bin/env python3
"""Capture, verify, qualify, and promote immutable pacman repository cohorts."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import Any, Sequence


COHORT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
REPO_RE = re.compile(r"^[a-z0-9][a-z0-9@._+-]*$")
ARCH_RE = re.compile(r"^[a-z0-9][a-z0-9_+-]{0,31}$")
FINGERPRINT_RE = re.compile(r"^(?:[0-9A-F]{40}|[0-9A-F]{64})$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MANUAL_INVENTORY_TRUST = "manual-trusted-operator-assertion"
MANUAL_QUALIFICATION_TRUST = "manual-trusted-operator-assertion"
AT_FDCWD = -100
RENAME_EXCHANGE = 2
PROMOTION_JOURNAL_SCHEMA = 1
QUALIFICATION_INTENT_SCHEMA = 1


class SnapshotError(ValueError):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fsync_file(path: Path) -> None:
    with path.open("rb") as source:
        os.fsync(source.fileno())


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def contained_path(root: Path, *parts: str) -> Path:
    candidate = root.joinpath(*parts)
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise SnapshotError(f"destination escapes snapshot staging: {candidate}") from exc
    return candidate


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"unable to read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SnapshotError(f"{path} must contain a JSON object")
    return value


def load_policy(path: Path) -> dict[str, Any]:
    policy = load_json(path)
    if policy.get("schema_version") != 2:
        raise SnapshotError("base snapshot policy schema_version must be 2")
    if policy.get("allow_live_upstream_for_stable") is not False:
        raise SnapshotError("stable policy must reject live moving upstream repositories")
    if policy.get("architecture") != "aarch64":
        raise SnapshotError("base snapshot policy architecture must be aarch64")
    if policy.get("repository_scope") != "complete-default-enabled-repositories":
        raise SnapshotError(
            "base snapshot policy must retain every package in the default enabled repositories"
        )
    repositories = policy.get("required_repositories")
    if (
        not isinstance(repositories, list)
        or not repositories
        or any(not isinstance(name, str) or not REPO_RE.fullmatch(name) for name in repositories)
        or len(repositories) != len(set(repositories))
    ):
        raise SnapshotError("policy must list unique required repository names")
    if not isinstance(policy.get("minimum_retained_cohorts"), int) or policy[
        "minimum_retained_cohorts"
    ] < 2:
        raise SnapshotError("minimum_retained_cohorts must be at least 2")
    if policy.get("require_package_signatures") is not True:
        raise SnapshotError("base snapshot policy must require package signatures")
    allowed_signers = policy.get("allowed_package_signer_fingerprints")
    if (
        not isinstance(allowed_signers, list)
        or not allowed_signers
        or any(
            not isinstance(fingerprint, str)
            or not FINGERPRINT_RE.fullmatch(fingerprint)
            for fingerprint in allowed_signers
        )
        or len(allowed_signers) != len(set(allowed_signers))
    ):
        raise SnapshotError(
            "policy must list unique uppercase package signer fingerprints"
        )
    if policy.get("upstream_database_signatures") != "unsigned":
        raise SnapshotError(
            "base snapshot policy must state that upstream ALARM databases are unsigned"
        )
    if policy.get("mirror_inventory_trust") != MANUAL_INVENTORY_TRUST:
        raise SnapshotError(
            "base snapshot policy must require a manual trusted mirror inventory assertion"
        )
    if policy.get("promotion") != "exact-bytes":
        raise SnapshotError("base snapshot policy must require exact-byte promotion")
    if policy.get("qualification_required_for_stable") is not True:
        raise SnapshotError("base snapshot policy must require stable qualification")
    if policy.get("qualification_trust") != MANUAL_QUALIFICATION_TRUST:
        raise SnapshotError(
            "base snapshot policy must require a manual trusted qualification assertion"
        )
    evidence = policy.get("required_qualification_evidence")
    if not isinstance(evidence, list) or not evidence:
        raise SnapshotError("policy must list required typed qualification evidence")
    evidence_names: set[str] = set()
    for record in evidence:
        if not isinstance(record, dict) or set(record) != {"name", "type"}:
            raise SnapshotError(
                "each required qualification evidence record needs only name and type"
            )
        name = record.get("name")
        evidence_type = record.get("type")
        if (
            not isinstance(name, str)
            or not COHORT_RE.fullmatch(name)
            or not isinstance(evidence_type, str)
            or not COHORT_RE.fullmatch(evidence_type)
            or name in evidence_names
        ):
            raise SnapshotError(
                "policy must list unique valid qualification evidence names and types"
            )
        evidence_names.add(name)
    return policy


def required_evidence(policy: dict[str, Any]) -> dict[str, str]:
    return {
        record["name"]: record["type"]
        for record in policy["required_qualification_evidence"]
    }


def validate_architecture(value: str, policy: dict[str, Any]) -> str:
    if not ARCH_RE.fullmatch(value):
        raise SnapshotError(f"invalid architecture: {value}")
    if value != policy["architecture"]:
        raise SnapshotError(
            f"snapshot architecture {value} does not match policy {policy['architecture']}"
        )
    return value


def validate_package_filename(value: str) -> str:
    path = Path(value)
    if not value or path.is_absolute() or path.name != value or value in {".", ".."}:
        raise SnapshotError(f"repository database contains unsafe package filename: {value!r}")
    return value


def resolve_keyrings(values: Sequence[Path]) -> list[Path]:
    keyrings = [path.resolve() for path in values]
    if not keyrings:
        raise SnapshotError("at least one trusted --keyring is required")
    for path in keyrings:
        if not path.is_file():
            raise SnapshotError(f"trusted keyring does not exist: {path}")
    if shutil.which("gpgv") is None:
        raise SnapshotError("gpgv is required to verify snapshot signatures")
    return keyrings


def verify_signature(
    data: Path,
    signature: Path,
    keyrings: Sequence[Path],
    allowed_fingerprints: set[str],
) -> tuple[str, str]:
    command = ["gpgv", "--status-fd=1"]
    for keyring in keyrings:
        command.extend(("--keyring", str(keyring)))
    command.extend((str(signature), str(data)))
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        reason = detail[-1] if detail else f"gpgv exited {result.returncode}"
        raise SnapshotError(f"invalid signature for {data.name}: {reason}")
    rejected_statuses = {
        "BADSIG",
        "ERRSIG",
        "EXPKEYSIG",
        "EXPSIG",
        "NO_PUBKEY",
        "REVKEYSIG",
    }
    valid_signatures: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "[GNUPG:]" and fields[1] in rejected_statuses:
            raise SnapshotError(
                f"gpgv reported {fields[1]} while checking {data.name}"
            )
        if len(fields) < 3 or fields[:2] != ["[GNUPG:]", "VALIDSIG"]:
            continue
        signing_fingerprint = fields[2].upper()
        if not FINGERPRINT_RE.fullmatch(signing_fingerprint):
            raise SnapshotError(
                f"gpgv reported a malformed signing fingerprint for {data.name}"
            )
        primary_fingerprint = signing_fingerprint
        if FINGERPRINT_RE.fullmatch(fields[-1].upper()):
            primary_fingerprint = fields[-1].upper()
        valid_signatures.append((signing_fingerprint, primary_fingerprint))
    if len(valid_signatures) != 1:
        raise SnapshotError(
            f"gpgv accepted {data.name} but reported {len(valid_signatures)} "
            "VALIDSIG records instead of exactly one"
        )
    signing_fingerprint, primary_fingerprint = valid_signatures[0]
    if not {signing_fingerprint, primary_fingerprint} & allowed_fingerprints:
        raise SnapshotError(
            f"valid signature for {data.name} uses unallowed signing/primary keys: "
            f"{signing_fingerprint}, {primary_fingerprint}"
        )
    return signing_fingerprint, primary_fingerprint


def parse_repo(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise SnapshotError(f"repository must use NAME=PATH: {value}")
    name, raw_path = value.split("=", 1)
    if not REPO_RE.fullmatch(name):
        raise SnapshotError(f"invalid repository name: {name}")
    path = Path(raw_path).resolve()
    if not path.is_dir():
        raise SnapshotError(f"repository directory does not exist: {path}")
    return name, path


def find_database(name: str, directory: Path) -> Path:
    candidates = [
        directory / f"{name}.db.tar.gz",
        directory / f"{name}.db.tar.xz",
        directory / f"{name}.db.tar.zst",
        directory / f"{name}.db",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    globbed = sorted(path.resolve() for path in directory.glob("*.db.tar.*") if path.is_file())
    if len(globbed) == 1:
        return globbed[0]
    raise SnapshotError(f"unable to identify one pacman database in {directory}")


def field_from_desc(data: bytes, field: str) -> str | None:
    lines = data.decode("utf-8", "strict").splitlines()
    marker = f"%{field}%"
    positions = [index for index, line in enumerate(lines) if line == marker]
    if len(positions) > 1:
        raise SnapshotError(f"repository database entry repeats %{field}%")
    if not positions:
        return None

    values: list[str] = []
    for line in lines[positions[0] + 1 :]:
        if not line or (line.startswith("%") and line.endswith("%")):
            break
        values.append(line)
    if len(values) != 1:
        raise SnapshotError(
            f"repository database entry %{field}% must contain exactly one value"
        )
    return values[0]


def database_packages(database: Path) -> dict[str, dict[str, Any]]:
    packages: dict[str, dict[str, Any]] = {}
    try:
        with tarfile.open(database, mode="r:*") as archive:
            for member in archive.getmembers():
                if not member.isfile() or not member.name.endswith("/desc"):
                    continue
                source = archive.extractfile(member)
                if source is None:
                    continue
                description = source.read()
                filename = field_from_desc(description, "FILENAME")
                csize = field_from_desc(description, "CSIZE")
                checksum = field_from_desc(description, "SHA256SUM")
                if filename is None:
                    raise SnapshotError(
                        f"repository database entry {member.name} lacks %FILENAME%"
                    )
                filename = validate_package_filename(filename)
                if csize is None or not csize.isdigit():
                    raise SnapshotError(
                        f"repository database entry for {filename} lacks a valid %CSIZE%"
                    )
                if checksum is None or not SHA256_RE.fullmatch(checksum.lower()):
                    raise SnapshotError(
                        f"repository database entry for {filename} lacks a valid %SHA256SUM%"
                    )
                if filename in packages:
                    raise SnapshotError(
                        f"repository database repeats package filename {filename}: {database}"
                    )
                packages[filename] = {
                    "filename": filename,
                    "csize": int(csize),
                    "sha256": checksum.lower(),
                }
    except (tarfile.TarError, UnicodeError, OSError) as exc:
        raise SnapshotError(f"unable to parse repository database {database}: {exc}") from exc
    if not packages:
        raise SnapshotError(f"repository database contains no package filenames: {database}")
    return {filename: packages[filename] for filename in sorted(packages)}


def verify_database_package(package: Path, record: dict[str, Any]) -> None:
    if package.stat().st_size != record["csize"]:
        raise SnapshotError(
            f"package {package.name} size does not match the copied repository database"
        )
    if sha256(package) != record["sha256"]:
        raise SnapshotError(
            f"package {package.name} digest does not match the copied repository database"
        )


def copy_file(source: Path, destination: Path) -> dict[str, Any]:
    if source.is_symlink() or not source.is_file():
        raise SnapshotError(f"snapshot source must be a regular file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    fsync_file(destination)
    return {
        "path": destination.as_posix(),
        "size": destination.stat().st_size,
        "sha256": sha256(destination),
    }


def relative_record(path: Path, root: Path) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "size": path.stat().st_size,
        "sha256": sha256(path),
    }


def canonical_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def cohort_content_identity(architecture: str, files: Sequence[dict[str, Any]]) -> str:
    content = {
        "architecture": architecture,
        "files": sorted(
            (
                {
                    "path": record["path"],
                    "size": record["size"],
                    "sha256": record["sha256"],
                }
                for record in files
            ),
            key=lambda record: record["path"],
        ),
    }
    return hashlib.sha256(canonical_json(content).encode("utf-8")).hexdigest()


def mirror_inventory_assertion(
    policy: dict[str, Any], repositories: Sequence[dict[str, Any]]
) -> dict[str, Any]:
    return {
        "asserted": True,
        "method": policy["mirror_inventory_trust"],
        "repositories": sorted(
            (
                {
                    "name": repository["name"],
                    "database_sha256": repository["database_sha256"],
                }
                for repository in repositories
            ),
            key=lambda repository: repository["name"],
        ),
    }


def write_json_durable(
    path: Path,
    value: Any,
    temporary_directory: Path | None = None,
    temporary_prefix: str | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_parent = temporary_directory or path.parent
    temporary_parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=temporary_prefix or f".{path.name}.",
        suffix=".tmp",
        dir=temporary_parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(canonical_json(value))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
        if temporary_parent != path.parent:
            fsync_directory(temporary_parent)
    except Exception:
        remove_path(temporary)
        raise


def write_qualification_state(
    cohort: Path,
    path: Path,
    value: Any,
    label: str,
) -> None:
    write_json_durable(
        path,
        value,
        temporary_directory=cohort.parent,
        temporary_prefix=f".{cohort.name}.qualification-{label}-write.",
    )


def unlink_durable(path: Path) -> None:
    path.unlink()
    fsync_directory(path.parent)


def rename_exchange(left: Path, right: Path) -> None:
    """Atomically exchange two existing paths without making either absent."""
    libc = ctypes.CDLL(None, use_errno=True)
    operation = getattr(libc, "renameat2", None)
    if operation is None:
        raise SnapshotError(
            "atomic channel replacement requires Linux renameat2(RENAME_EXCHANGE)"
        )
    operation.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    operation.restype = ctypes.c_int
    result = operation(
        AT_FDCWD,
        os.fsencode(left),
        AT_FDCWD,
        os.fsencode(right),
        RENAME_EXCHANGE,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise SnapshotError(
            f"atomic channel exchange failed for {right}: {os.strerror(error)}"
        )


def regular_tree_files(root: Path) -> set[str]:
    files: set[str] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise SnapshotError(f"snapshot tree contains a symbolic link: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise SnapshotError(f"snapshot tree contains a special file: {relative}")
        files.add(relative)
    return files


def verify_manifest(
    cohort: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
    expected_cohort: str,
    permitted_extra_files: set[str] | None = None,
) -> dict[str, Any]:
    manifest_path = cohort / "cohort.json"
    manifest = load_json(manifest_path)
    if manifest.get("schema_version") != 2:
        raise SnapshotError(f"unsupported cohort schema in {manifest_path}")
    manifest_cohort = manifest.get("cohort")
    if (
        not isinstance(manifest_cohort, str)
        or not COHORT_RE.fullmatch(manifest_cohort)
        or manifest_cohort != expected_cohort
    ):
        raise SnapshotError(
            f"cohort manifest name {manifest_cohort!r} does not match directory identity "
            f"{expected_cohort!r}"
        )
    if manifest.get("architecture") != policy["architecture"]:
        raise SnapshotError("cohort architecture does not match the active policy")
    if manifest.get("policy_sha256") != sha256(policy_path):
        raise SnapshotError("cohort was not captured under the active policy bytes")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise SnapshotError(f"cohort has no file records: {cohort}")
    expected_files = {"cohort.json"}
    recorded_files: set[str] = set()
    for record in files:
        if not isinstance(record, dict) or set(record) != {"path", "size", "sha256"}:
            raise SnapshotError("invalid cohort file record")
        relative = record.get("path")
        if (
            not isinstance(relative, str)
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
        ):
            raise SnapshotError(f"invalid cohort path: {relative!r}")
        if (
            not isinstance(record.get("size"), int)
            or record["size"] < 0
            or not isinstance(record.get("sha256"), str)
            or not SHA256_RE.fullmatch(record["sha256"])
        ):
            raise SnapshotError(f"invalid cohort size or digest record: {relative}")
        if relative in recorded_files:
            raise SnapshotError(f"cohort repeats a file record: {relative}")
        recorded_files.add(relative)
        path = cohort / relative
        if not path.is_file():
            raise SnapshotError(f"cohort file is missing: {relative}")
        if path.stat().st_size != record.get("size"):
            raise SnapshotError(f"cohort file size changed: {relative}")
        if sha256(path) != record.get("sha256"):
            raise SnapshotError(f"cohort file hash changed: {relative}")
        expected_files.add(relative)

    actual_files = regular_tree_files(cohort)
    core_files = {
        relative
        for relative in actual_files
        if relative != "qualification.json"
        and not relative.startswith("qualification-evidence/")
    }
    complete_expected_files = expected_files | (permitted_extra_files or set())
    if core_files != complete_expected_files:
        extra = sorted(core_files - complete_expected_files)
        missing = sorted(complete_expected_files - core_files)
        raise SnapshotError(f"cohort file inventory changed; extra={extra}, missing={missing}")

    content_identity = cohort_content_identity(manifest["architecture"], files)
    if manifest.get("content_identity") != content_identity:
        raise SnapshotError("cohort content identity does not match its immutable file records")

    repositories = manifest.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise SnapshotError("cohort manifest contains no repositories")
    repository_names = [
        repository.get("name") if isinstance(repository, dict) else None
        for repository in repositories
    ]
    if len(repository_names) != len(set(repository_names)):
        raise SnapshotError("cohort manifest repeats a repository")
    if set(repository_names) != set(policy["required_repositories"]):
        raise SnapshotError(
            "cohort repository set differs from policy; "
            f"expected={sorted(policy['required_repositories'])}, "
            f"actual={sorted(name for name in repository_names if isinstance(name, str))}"
        )
    architecture = manifest["architecture"]
    allowed_fingerprints = set(policy["allowed_package_signer_fingerprints"])
    for repository in repositories:
        if not isinstance(repository, dict):
            raise SnapshotError("invalid cohort repository record")
        name = repository.get("name")
        archive_name = repository.get("database_archive")
        packages = repository.get("packages")
        if not isinstance(name, str) or not REPO_RE.fullmatch(name):
            raise SnapshotError(f"invalid cohort repository name: {name!r}")
        if not isinstance(archive_name, str):
            raise SnapshotError(f"repository {name} has no database archive name")
        validate_package_filename(archive_name)
        if not isinstance(packages, list) or any(
            not isinstance(item, str) for item in packages
        ):
            raise SnapshotError(f"repository {name} has an invalid package inventory")
        packages = [validate_package_filename(item) for item in packages]
        if packages != sorted(set(packages)):
            raise SnapshotError(f"repository {name} package inventory is not unique and sorted")
        repo_root = cohort / "repos" / name / architecture
        database_archive = repo_root / archive_name
        database_alias = repo_root / f"{name}.db"
        if not database_archive.is_file() or not database_alias.is_file():
            raise SnapshotError(f"repository {name} lacks a consumable database alias")
        if sha256(database_archive) != sha256(database_alias):
            raise SnapshotError(f"repository {name} database alias differs from its archive")
        if repository.get("database_sha256") != sha256(database_alias):
            raise SnapshotError(f"repository {name} database digest is inconsistent")
        parsed_packages = database_packages(database_alias)
        if packages != list(parsed_packages):
            raise SnapshotError(f"repository {name} manifest does not match its copied database")
        if repository.get("package_count") != len(packages):
            raise SnapshotError(f"repository {name} package count is inconsistent")

        archive_signature = database_archive.with_name(database_archive.name + ".sig")
        alias_signature = database_alias.with_name(database_alias.name + ".sig")
        if archive_signature.exists() or alias_signature.exists():
            raise SnapshotError(
                f"repository {name} contains a database signature even though the "
                "ALARM database is explicitly unsigned"
            )

        observed_signers: set[tuple[str, str]] = set()
        for filename in packages:
            package = repo_root / filename
            signature = package.with_name(package.name + ".sig")
            if not package.is_file() or not signature.is_file():
                raise SnapshotError(f"repository {name} lacks signed package {filename}")
            verify_database_package(package, parsed_packages[filename])
            observed_signers.add(
                verify_signature(
                    package,
                    signature,
                    keyrings,
                    allowed_fingerprints,
                )
            )
        recorded_signers = repository.get("package_signers")
        expected_signers = [
            {
                "signing_fingerprint": signing_fingerprint,
                "primary_fingerprint": primary_fingerprint,
            }
            for signing_fingerprint, primary_fingerprint in sorted(observed_signers)
        ]
        if recorded_signers != expected_signers:
            raise SnapshotError(f"repository {name} package signer inventory is inconsistent")

    if manifest.get("mirror_inventory_assertion") != mirror_inventory_assertion(
        policy, repositories
    ):
        raise SnapshotError(
            "cohort lacks the trusted operator mirror-inventory assertion bound to its databases"
        )
    return manifest


def verify_cohort(
    cohort: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
    expected_cohort: str | None = None,
) -> dict[str, Any]:
    manifest = verify_manifest(
        cohort,
        policy,
        policy_path,
        keyrings,
        expected_cohort or cohort.name,
    )
    qualification_path = cohort / "qualification.json"
    evidence_path = cohort / "qualification-evidence"
    if (
        qualification_path.exists()
        or qualification_path.is_symlink()
        or evidence_path.exists()
        or evidence_path.is_symlink()
    ):
        if (
            qualification_path.is_symlink()
            or not qualification_path.is_file()
            or evidence_path.is_symlink()
            or not evidence_path.is_dir()
        ):
            raise SnapshotError("cohort has an incomplete qualification record")
        verify_qualification(cohort, policy)
    return manifest


def create_cohort(args: argparse.Namespace, policy: dict[str, Any]) -> Path:
    if not COHORT_RE.fullmatch(args.cohort):
        raise SnapshotError(f"invalid cohort identifier: {args.cohort}")
    if not args.assert_trusted_mirror_inventory:
        raise SnapshotError(
            "capture requires --assert-trusted-mirror-inventory because ALARM "
            "repository databases are unsigned"
        )
    architecture = validate_architecture(args.architecture, policy)
    keyrings = resolve_keyrings(args.keyring)
    allowed_fingerprints = set(policy["allowed_package_signer_fingerprints"])
    repositories = [parse_repo(value) for value in args.repo]
    if len({name for name, _path in repositories}) != len(repositories):
        raise SnapshotError("repository names must be unique")
    supplied_names = {name for name, _path in repositories}
    required_names = set(policy["required_repositories"])
    if supplied_names != required_names:
        raise SnapshotError(
            "capture must supply exactly the policy repositories; "
            f"missing={sorted(required_names - supplied_names)}, "
            f"unexpected={sorted(supplied_names - required_names)}"
        )

    cohorts_root = args.output_root.resolve() / "cohorts"
    destination = cohorts_root / args.cohort
    if destination.exists() or destination.is_symlink():
        verify_cohort(destination, policy, args.policy, keyrings, args.cohort)
        raise SnapshotError(f"immutable cohort already exists: {destination}")
    cohorts_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{args.cohort}.", dir=cohorts_root))
    records: list[dict[str, Any]] = []
    repository_records: list[dict[str, Any]] = []
    try:
        for name, source_directory in repositories:
            database = find_database(name, source_directory)
            repo_destination = contained_path(staging, "repos", name, architecture)
            copied: list[str] = []

            # Copy the database first, then parse and verify those immutable
            # staged bytes. A moving mirror cannot make the manifest describe
            # a different database than the one retained in the cohort.
            database_copy = contained_path(repo_destination, database.name)
            copy_file(database, database_copy)
            records.append(relative_record(database_copy, staging))
            database_signature = database.with_name(database.name + ".sig")
            if database_signature.exists():
                raise SnapshotError(
                    f"repository {name} supplied an unexpected database signature; "
                    "ALARM repository databases are unsigned"
                )

            database_alias = contained_path(repo_destination, f"{name}.db")
            if database_alias != database_copy:
                copy_file(database_copy, database_alias)
                records.append(relative_record(database_alias, staging))

            package_records = database_packages(database_copy)
            filenames = list(package_records)
            package_signers: set[tuple[str, str]] = set()

            for filename in filenames:
                source = source_directory / filename
                if source.is_symlink() or not source.is_file():
                    raise SnapshotError(f"{database} references missing package {filename}")
                signature = source.with_name(source.name + ".sig")
                if signature.is_symlink() or not signature.is_file():
                    raise SnapshotError(f"package signature is missing: {signature}")
                for item in (source, signature):
                    destination_file = contained_path(repo_destination, item.name)
                    copy_file(item, destination_file)
                    records.append(relative_record(destination_file, staging))
                package_copy = repo_destination / filename
                verify_database_package(package_copy, package_records[filename])
                package_signers.add(
                    verify_signature(
                        package_copy,
                        repo_destination / f"{filename}.sig",
                        keyrings,
                        allowed_fingerprints,
                    )
                )
                copied.append(filename)

            repository_records.append(
                {
                    "name": name,
                    "database_archive": database.name,
                    "database_sha256": sha256(database_copy),
                    "package_count": len(copied),
                    "packages": copied,
                    "package_signers": [
                        {
                            "signing_fingerprint": signing_fingerprint,
                            "primary_fingerprint": primary_fingerprint,
                        }
                        for signing_fingerprint, primary_fingerprint in sorted(
                            package_signers
                        )
                    ],
                }
            )

        sorted_records = sorted(records, key=lambda item: item["path"])
        sorted_repositories = sorted(repository_records, key=lambda item: item["name"])
        manifest = {
            "schema_version": 2,
            "cohort": args.cohort,
            "architecture": architecture,
            "captured_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "policy_sha256": sha256(args.policy),
            "content_identity": cohort_content_identity(architecture, sorted_records),
            "mirror_inventory_assertion": mirror_inventory_assertion(
                policy, sorted_repositories
            ),
            "repositories": sorted_repositories,
            "files": sorted_records,
        }
        write_json_durable(staging / "cohort.json", manifest)
        verify_manifest(staging, policy, args.policy, keyrings, args.cohort)
        for directory in sorted(
            (path for path in staging.rglob("*") if path.is_dir()),
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            fsync_directory(directory)
        fsync_directory(staging)
        os.replace(staging, destination)
        fsync_directory(cohorts_root)
        return destination
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def qualification_trust_assertion(policy: dict[str, Any]) -> dict[str, Any]:
    return {
        "asserted": True,
        "method": policy["qualification_trust"],
        "signing_status": "m2-signing-unavailable",
    }


def validate_evidence_document(
    path: Path,
    name: str,
    evidence_type: str,
    manifest: dict[str, Any],
    expected_artifact_sha256: str | None = None,
) -> str:
    document = load_json(path)
    if document.get("schema_version") != 1:
        raise SnapshotError(f"qualification evidence {name} must use schema_version 1")
    if document.get("cohort") != manifest["cohort"]:
        raise SnapshotError(f"qualification evidence {name} names a different cohort")
    if document.get("cohort_content_identity") != manifest["content_identity"]:
        raise SnapshotError(
            f"qualification evidence {name} does not bind the cohort content identity"
        )
    if document.get("name") != name or document.get("type") != evidence_type:
        raise SnapshotError(
            f"qualification evidence {name} has a mismatched name or type"
        )
    if document.get("result") != "pass":
        raise SnapshotError(f"qualification evidence {name} did not pass")
    artifact_sha256 = document.get("thorch_artifact_sha256")
    if not isinstance(artifact_sha256, str) or not SHA256_RE.fullmatch(
        artifact_sha256
    ):
        raise SnapshotError(
            f"qualification evidence {name} lacks a valid Thorch artifact digest"
        )
    if (
        expected_artifact_sha256 is not None
        and artifact_sha256 != expected_artifact_sha256
    ):
        raise SnapshotError(
            f"qualification evidence {name} binds a different Thorch artifact"
        )
    return artifact_sha256


def qualify_cohort(args: argparse.Namespace, policy: dict[str, Any]) -> Path:
    if not args.assert_manual_trust:
        raise SnapshotError(
            "qualification requires --assert-manual-trust while M2 evidence signing "
            "is unavailable"
        )
    cohort = args.cohort.resolve()
    if cohort.is_symlink() or not cohort.is_dir():
        raise SnapshotError(f"cohort is not a real directory: {cohort}")
    lock_path = cohort.parent / f".{cohort.name}.qualification.lock"
    descriptor = os.open(
        lock_path,
        os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise SnapshotError(f"qualification lock is not a regular file: {lock_path}")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return qualify_cohort_locked(args, policy, cohort)
    finally:
        os.close(descriptor)


def qualify_cohort_locked(
    args: argparse.Namespace,
    policy: dict[str, Any],
    cohort: Path,
) -> Path:
    keyrings = resolve_keyrings(args.keyring)
    recover_incomplete_qualification(cohort, policy, args.policy, keyrings)
    manifest = verify_cohort(cohort, policy, args.policy, keyrings)
    qualification_path = cohort / "qualification.json"
    evidence_root = cohort / "qualification-evidence"
    intent_path = cohort / ".qualification-intent.json"
    if (
        qualification_path.exists()
        or qualification_path.is_symlink()
        or evidence_root.exists()
        or evidence_root.is_symlink()
    ):
        raise SnapshotError(f"cohort qualification is append-only and already exists: {cohort}")
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{cohort.name}.qualification-stage.", dir=cohort.parent
        )
    )
    evidence: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    artifact_digests: set[str] = set()
    requirements = required_evidence(policy)
    try:
        for raw in args.evidence:
            if "=" not in raw:
                raise SnapshotError(f"evidence must use NAME=PATH: {raw}")
            name, raw_path = raw.split("=", 1)
            if not COHORT_RE.fullmatch(name) or name in seen_names:
                raise SnapshotError(f"invalid or duplicate evidence name: {name}")
            if name not in requirements:
                raise SnapshotError(f"unexpected qualification evidence name: {name}")
            seen_names.add(name)
            raw_source = Path(raw_path)
            if raw_source.is_symlink():
                raise SnapshotError(f"qualification evidence must not be a symbolic link: {raw_source}")
            source = raw_source.resolve()
            if not source.is_file() or source.stat().st_size == 0:
                raise SnapshotError(f"qualification evidence is missing or empty: {source}")
            destination = contained_path(staging, name, source.name)
            copy_file(source, destination)
            artifact_sha256 = validate_evidence_document(
                destination,
                name,
                requirements[name],
                manifest,
            )
            artifact_digests.add(artifact_sha256)
            final_relative = Path("qualification-evidence") / name / source.name
            evidence.append(
                {
                    "name": name,
                    "type": requirements[name],
                    "result": "pass",
                    "path": final_relative.as_posix(),
                    "size": destination.stat().st_size,
                    "sha256": sha256(destination),
                    "cohort_content_identity": manifest["content_identity"],
                    "thorch_artifact_sha256": artifact_sha256,
                }
            )
        missing = sorted(set(requirements) - seen_names)
        if missing:
            raise SnapshotError(
                "qualification evidence is missing required names: " + ", ".join(missing)
            )
        if len(artifact_digests) != 1:
            raise SnapshotError(
                "all qualification evidence must bind the same Thorch artifact digest"
            )

        for directory in sorted(
            (path for path in staging.rglob("*") if path.is_dir()),
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            fsync_directory(directory)
        fsync_directory(staging)
        fsync_directory(cohort.parent)
        sorted_evidence = sorted(evidence, key=lambda item: item["name"])
        write_qualification_state(
            cohort,
            intent_path,
            {
                "schema_version": QUALIFICATION_INTENT_SCHEMA,
                "cohort": manifest["cohort"],
                "cohort_manifest_sha256": sha256(cohort / "cohort.json"),
                "cohort_content_identity": manifest["content_identity"],
                "thorch_artifact_sha256": next(iter(artifact_digests)),
                "staging_directory": staging.name,
                "state": "prepared",
                "discard_directory": None,
                "evidence": sorted_evidence,
            },
            "intent",
        )
        if (
            os.environ.get("THORCH_BASE_SNAPSHOT_TEST_FAILPOINT")
            == "raise-after-qualification-intent"
        ):
            raise SnapshotError("qualification intent test failpoint")
        os.replace(staging, evidence_root)
        fsync_directory(cohort)
        fsync_directory(cohort.parent)
        if (
            os.environ.get("THORCH_BASE_SNAPSHOT_TEST_FAILPOINT")
            == "after-qualification-evidence"
        ):
            os._exit(87)
        qualification = {
            "schema_version": 2,
            "cohort": manifest["cohort"],
            "cohort_manifest_sha256": sha256(cohort / "cohort.json"),
            "cohort_content_identity": manifest["content_identity"],
            "thorch_artifact_sha256": next(iter(artifact_digests)),
            "manual_trust_assertion": qualification_trust_assertion(policy),
            "qualified_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "evidence": sorted_evidence,
        }
        write_qualification_state(
            cohort,
            qualification_path,
            qualification,
            "record",
        )
        verify_qualification(cohort, policy)
        unlink_durable(intent_path)
        return qualification_path
    except Exception:
        # Before the intent rename, staging is untrusted scratch and can be
        # discarded directly. Once the intent is durable, leave all bytes for
        # the same journaled recovery state machine used after power loss.
        if not intent_path.exists() and not intent_path.is_symlink():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def verify_qualification(cohort: Path, policy: dict[str, Any]) -> dict[str, Any]:
    qualification = load_json(cohort / "qualification.json")
    if qualification.get("schema_version") != 2:
        raise SnapshotError("unsupported qualification schema")
    manifest = load_json(cohort / "cohort.json")
    if qualification.get("cohort") != manifest.get("cohort"):
        raise SnapshotError("qualification names a different cohort")
    if qualification.get("cohort_manifest_sha256") != sha256(cohort / "cohort.json"):
        raise SnapshotError("qualification does not match the current cohort manifest")
    if qualification.get("cohort_content_identity") != manifest.get("content_identity"):
        raise SnapshotError("qualification does not match the cohort content identity")
    artifact_sha256 = qualification.get("thorch_artifact_sha256")
    if not isinstance(artifact_sha256, str) or not SHA256_RE.fullmatch(
        artifact_sha256
    ):
        raise SnapshotError("qualification lacks a valid Thorch artifact digest")
    if qualification.get("manual_trust_assertion") != qualification_trust_assertion(
        policy
    ):
        raise SnapshotError(
            "qualification lacks the required manual trust assertion for unsigned M2 evidence"
        )
    evidence = qualification.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise SnapshotError("qualification contains no evidence")
    expected_paths: set[str] = set()
    names: set[str] = set()
    requirements = required_evidence(policy)
    for record in evidence:
        if not isinstance(record, dict):
            raise SnapshotError("qualification has an invalid evidence record")
        name = record.get("name")
        relative = record.get("path")
        if not isinstance(name, str) or not COHORT_RE.fullmatch(name) or name in names:
            raise SnapshotError(f"qualification has an invalid evidence name: {name!r}")
        if name not in requirements:
            raise SnapshotError(f"qualification has an unexpected evidence name: {name}")
        if record.get("type") != requirements[name] or record.get("result") != "pass":
            raise SnapshotError(
                f"qualification evidence {name} has a mismatched type or failed result"
            )
        if record.get("cohort_content_identity") != manifest.get("content_identity"):
            raise SnapshotError(
                f"qualification evidence {name} record binds a different cohort"
            )
        if record.get("thorch_artifact_sha256") != artifact_sha256:
            raise SnapshotError(
                f"qualification evidence {name} record binds a different Thorch artifact"
            )
        if not isinstance(relative, str):
            raise SnapshotError("qualification evidence path is not a string")
        relative_path = Path(relative)
        if (
            relative_path.is_absolute()
            or ".." in relative_path.parts
            or len(relative_path.parts) < 3
            or relative_path.parts[:2] != ("qualification-evidence", name)
        ):
            raise SnapshotError(f"qualification has an unsafe evidence path: {relative!r}")
        path = cohort / relative_path
        if path.is_symlink() or not path.is_file():
            raise SnapshotError(f"qualification evidence is missing: {relative}")
        if path.stat().st_size != record.get("size") or sha256(path) != record.get("sha256"):
            raise SnapshotError(f"qualification evidence changed: {relative}")
        validate_evidence_document(
            path,
            name,
            requirements[name],
            manifest,
            artifact_sha256,
        )
        names.add(name)
        expected_paths.add(relative)
    if names != set(requirements):
        missing = sorted(set(requirements) - names)
        raise SnapshotError(
            "qualification lacks required evidence: " + ", ".join(missing)
        )
    actual_paths = {
        f"qualification-evidence/{relative}"
        for relative in regular_tree_files(cohort / "qualification-evidence")
    }
    if actual_paths != expected_paths:
        raise SnapshotError("qualification evidence inventory does not match its record")
    return qualification


def copy_tree_exact(source: Path, destination: Path) -> None:
    source_paths = regular_tree_files(source)
    shutil.copytree(source, destination, symlinks=False)
    destination_paths = regular_tree_files(destination)
    source_files = {relative: sha256(source / relative) for relative in source_paths}
    destination_files = {relative: sha256(destination / relative) for relative in destination_paths}
    if source_files != destination_files:
        raise SnapshotError("promoted channel bytes differ from the qualified cohort")
    for relative in destination_paths:
        fsync_file(destination / relative)
    for directory in sorted(
        (path for path in destination.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        fsync_directory(directory)
    fsync_directory(destination)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def recover_incomplete_qualification(
    cohort: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> None:
    """Recover only state authenticated by a durable qualification intent."""
    if cohort.is_symlink() or not cohort.is_dir():
        raise SnapshotError(f"cohort is not a real directory: {cohort}")
    intent_path = cohort / ".qualification-intent.json"
    write_orphans = [
        *cohort.parent.glob(f".{cohort.name}.qualification-intent-write.*"),
        *cohort.parent.glob(f".{cohort.name}.qualification-record-write.*"),
    ]
    if not intent_path.exists() and not intent_path.is_symlink():
        # Only a verified cohort authorizes cleanup in its sibling namespace.
        # Evidence inside the cohort without an intent remains tamper evidence
        # and makes verify_cohort fail before anything is removed.
        verify_cohort(cohort, policy, policy_path, keyrings)
        orphans = [
            *cohort.parent.glob(f".{cohort.name}.qualification-stage.*"),
            *cohort.parent.glob(f".{cohort.name}.qualification-discard.*"),
            *write_orphans,
        ]
        for orphan in orphans:
            remove_path(orphan)
        if orphans:
            fsync_directory(cohort.parent)
        return
    if intent_path.is_symlink() or not intent_path.is_file():
        raise SnapshotError(f"qualification intent is not a regular file: {intent_path}")

    intent = load_json(intent_path)
    if set(intent) != {
        "schema_version",
        "cohort",
        "cohort_manifest_sha256",
        "cohort_content_identity",
        "thorch_artifact_sha256",
        "staging_directory",
        "state",
        "discard_directory",
        "evidence",
    } or intent.get("schema_version") != QUALIFICATION_INTENT_SCHEMA:
        raise SnapshotError("invalid qualification intent journal")
    manifest = verify_manifest(
        cohort,
        policy,
        policy_path,
        keyrings,
        cohort.name,
        {intent_path.name},
    )
    for orphan in write_orphans:
        remove_path(orphan)
    if write_orphans:
        fsync_directory(cohort.parent)
    if (
        intent.get("cohort") != manifest["cohort"]
        or intent.get("cohort_manifest_sha256") != sha256(cohort / "cohort.json")
        or intent.get("cohort_content_identity") != manifest["content_identity"]
    ):
        raise SnapshotError("qualification intent is bound to a different cohort")
    artifact_sha256 = intent.get("thorch_artifact_sha256")
    if not isinstance(artifact_sha256, str) or not SHA256_RE.fullmatch(
        artifact_sha256
    ):
        raise SnapshotError("qualification intent has an invalid Thorch artifact digest")
    staging_name = intent.get("staging_directory")
    staging_prefix = f".{cohort.name}.qualification-stage."
    if (
        not isinstance(staging_name, str)
        or not staging_name.startswith(staging_prefix)
        or Path(staging_name).name != staging_name
    ):
        raise SnapshotError("qualification intent has an unsafe staging directory")
    staging = cohort.parent / staging_name
    state = intent.get("state")
    discard_name = intent.get("discard_directory")
    discard_prefix = f".{cohort.name}.qualification-discard."
    if state == "prepared":
        if discard_name is not None:
            raise SnapshotError("prepared qualification intent names discard state")
        discard = None
    elif state == "discarding":
        if (
            not isinstance(discard_name, str)
            or not discard_name.startswith(discard_prefix)
            or Path(discard_name).name != discard_name
        ):
            raise SnapshotError("qualification intent has an unsafe discard directory")
        discard = cohort.parent / discard_name
    else:
        raise SnapshotError("qualification intent has an invalid recovery state")
    evidence_root = cohort / "qualification-evidence"
    qualification_path = cohort / "qualification.json"
    evidence_records = intent.get("evidence")
    if not isinstance(evidence_records, list) or not evidence_records:
        raise SnapshotError("qualification intent contains no evidence records")

    requirements = required_evidence(policy)
    names: set[str] = set()
    expected_paths: set[str] = set()
    for record in evidence_records:
        if not isinstance(record, dict) or set(record) != {
            "name",
            "type",
            "result",
            "path",
            "size",
            "sha256",
            "cohort_content_identity",
            "thorch_artifact_sha256",
        }:
            raise SnapshotError("qualification intent has an invalid evidence record")
        name = record.get("name")
        relative = record.get("path")
        if (
            not isinstance(name, str)
            or name not in requirements
            or name in names
            or record.get("type") != requirements[name]
            or record.get("result") != "pass"
            or record.get("cohort_content_identity") != manifest["content_identity"]
            or record.get("thorch_artifact_sha256") != artifact_sha256
        ):
            raise SnapshotError("qualification intent evidence binding is inconsistent")
        if (
            not isinstance(relative, str)
            or not isinstance(record.get("size"), int)
            or record["size"] <= 0
            or not isinstance(record.get("sha256"), str)
            or not SHA256_RE.fullmatch(record["sha256"])
        ):
            raise SnapshotError("qualification intent evidence metadata is invalid")
        relative_path = Path(relative)
        if (
            relative_path.is_absolute()
            or ".." in relative_path.parts
            or len(relative_path.parts) < 3
            or relative_path.parts[:2] != ("qualification-evidence", name)
        ):
            raise SnapshotError("qualification intent has an unsafe evidence path")
        names.add(name)
        expected_paths.add(relative)
    if names != set(requirements):
        raise SnapshotError("qualification intent lacks required evidence")

    evidence_exists = evidence_root.exists() or evidence_root.is_symlink()
    staging_exists = staging.exists() or staging.is_symlink()
    if evidence_exists and staging_exists:
        raise SnapshotError("qualification recovery found both staged and published evidence")
    source_base = evidence_root if evidence_exists else staging if staging_exists else None
    discard_exists = discard is not None and (discard.exists() or discard.is_symlink())
    if state == "prepared":
        if discard_exists:
            raise SnapshotError("prepared qualification intent has unexpected discard bytes")
        evidence_base = source_base
    else:
        if qualification_path.exists() or qualification_path.is_symlink():
            raise SnapshotError("completed qualification is marked for discard")
        if source_base is not None and discard_exists:
            raise SnapshotError(
                "qualification discard recovery found source and discard bytes"
            )
        evidence_base = source_base if source_base is not None else discard
    if evidence_base is None:
        raise SnapshotError("qualification intent evidence bytes are missing")
    if evidence_base.is_symlink() or not evidence_base.is_dir():
        raise SnapshotError("qualification intent evidence bytes are missing")
    for record in evidence_records:
        relative_path = Path(record["path"])
        path = evidence_base.joinpath(*relative_path.parts[1:])
        if path.is_symlink() or not path.is_file():
            raise SnapshotError(f"qualification intent evidence is missing: {record['path']}")
        if path.stat().st_size != record["size"] or sha256(path) != record["sha256"]:
            raise SnapshotError(f"qualification intent evidence changed: {record['path']}")
        validate_evidence_document(
            path,
            record["name"],
            requirements[record["name"]],
            manifest,
            artifact_sha256,
        )
    actual_paths = {
        f"qualification-evidence/{relative}"
        for relative in regular_tree_files(evidence_base)
    }
    if actual_paths != expected_paths:
        raise SnapshotError("qualification intent evidence inventory changed")

    if qualification_path.exists() or qualification_path.is_symlink():
        if state != "prepared" or staging_exists:
            raise SnapshotError("completed qualification has inconsistent recovery state")
        qualification = verify_qualification(cohort, policy)
        if (
            qualification.get("evidence") != evidence_records
            or qualification.get("thorch_artifact_sha256") != artifact_sha256
        ):
            raise SnapshotError("completed qualification differs from its intent")
        unlink_durable(intent_path)
        return

    if state == "prepared":
        placeholder = Path(
            tempfile.mkdtemp(prefix=discard_prefix, dir=cohort.parent)
        )
        remove_path(placeholder)
        discard = placeholder
        intent["state"] = "discarding"
        intent["discard_directory"] = discard.name
        write_qualification_state(
            cohort,
            intent_path,
            intent,
            "intent",
        )
    assert discard is not None
    if evidence_base != discard:
        os.replace(evidence_base, discard)
        fsync_directory(evidence_base.parent)
        fsync_directory(discard.parent)
    if (
        os.environ.get("THORCH_BASE_SNAPSHOT_TEST_FAILPOINT")
        == "after-qualification-discard"
    ):
        os._exit(88)
    unlink_durable(intent_path)
    remove_path(discard)
    fsync_directory(cohort)
    fsync_directory(cohort.parent)


def verified_retained_cohorts(
    cohorts_root: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> list[Path]:
    if not cohorts_root.is_dir():
        raise SnapshotError(f"cohort root does not exist: {cohorts_root}")
    cohorts: list[Path] = []
    for path in sorted(cohorts_root.iterdir()):
        # Atomic capture staging directories begin with a dot and cannot be a
        # retained cohort until their final rename has completed.
        if path.name.startswith("."):
            continue
        if not COHORT_RE.fullmatch(path.name):
            raise SnapshotError(f"invalid entry in cohort root: {path.name}")
        if path.is_symlink() or not path.is_dir():
            raise SnapshotError(f"retained cohort must be a real directory: {path}")
        cohorts.append(path)
    minimum = policy["minimum_retained_cohorts"]
    if len(cohorts) < minimum:
        raise SnapshotError(f"retention requires {minimum} cohorts; found {len(cohorts)}")
    identities: dict[str, Path] = {}
    for retained in cohorts:
        manifest = verify_cohort(retained, policy, policy_path, keyrings)
        identity = manifest["content_identity"]
        if identity in identities:
            raise SnapshotError(
                "retention cohorts must have distinct content identities; "
                f"{identities[identity].name} and {retained.name} are duplicates"
            )
        identities[identity] = retained
    return cohorts


def channel_identity(manifest: dict[str, Any], channel: dict[str, Any]) -> dict[str, str]:
    return {
        "cohort": manifest["cohort"],
        "content_identity": manifest["content_identity"],
        "cohort_manifest_sha256": channel["cohort_manifest_sha256"],
    }


def verified_channel_identity(
    directory: Path,
    expected_channel: str,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> dict[str, str]:
    if directory.is_symlink() or not directory.is_dir():
        raise SnapshotError(f"channel is not a real directory: {directory}")
    channel = load_json(directory / "channel.json")
    manifest = load_json(directory / "cohort.json")
    if (
        channel.get("schema_version") != 2
        or channel.get("channel") != expected_channel
    ):
        raise SnapshotError(f"{expected_channel} channel metadata is invalid")
    if channel.get("cohort") != manifest.get("cohort"):
        raise SnapshotError(f"{expected_channel} channel names a different cohort")
    verify_manifest(
        directory,
        policy,
        policy_path,
        keyrings,
        channel["cohort"],
        {"channel.json"},
    )
    qualification_path = directory / "qualification.json"
    qualification = None
    if expected_channel == "stable" or qualification_path.exists():
        qualification = verify_qualification(directory, policy)
    if channel.get("content_identity") != manifest.get("content_identity"):
        raise SnapshotError(f"{expected_channel} channel content identity is inconsistent")
    if channel.get("cohort_manifest_sha256") != sha256(directory / "cohort.json"):
        raise SnapshotError(f"{expected_channel} channel manifest digest is inconsistent")
    if expected_channel == "stable" and (
        qualification is None
        or channel.get("thorch_artifact_sha256")
        != qualification.get("thorch_artifact_sha256")
    ):
        raise SnapshotError("stable channel Thorch artifact digest is inconsistent")
    return channel_identity(manifest, channel)


def current_stable_identity(
    channels: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> dict[str, str] | None:
    stable = channels / "stable"
    if not stable.exists() and not stable.is_symlink():
        return None
    return verified_channel_identity(stable, "stable", policy, policy_path, keyrings)


def validate_promotion_identity(value: Any, label: str) -> dict[str, str]:
    fields = {"cohort", "content_identity", "cohort_manifest_sha256"}
    if not isinstance(value, dict) or set(value) != fields:
        raise SnapshotError(f"promotion journal has an invalid {label} identity")
    if not isinstance(value.get("cohort"), str) or not COHORT_RE.fullmatch(
        value["cohort"]
    ):
        raise SnapshotError(f"promotion journal has an invalid {label} cohort")
    for field in ("content_identity", "cohort_manifest_sha256"):
        if not isinstance(value.get(field), str) or not SHA256_RE.fullmatch(
            value[field]
        ):
            raise SnapshotError(
                f"promotion journal has an invalid {label} {field}"
            )
    return value


def recover_interrupted_promotion(
    channels: Path,
    channel_name: str,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> None:
    prefix = f".{channel_name}.promotion."
    journal_path = channels / f".{channel_name}.promotion.json"
    orphans = sorted(path for path in channels.glob(f"{prefix}*") if path != journal_path)
    if not journal_path.exists() and not journal_path.is_symlink():
        for orphan in orphans:
            remove_path(orphan)
        if orphans:
            fsync_directory(channels)
        return

    if journal_path.is_symlink() or not journal_path.is_file():
        raise SnapshotError(f"promotion journal is not a regular file: {journal_path}")
    journal = load_json(journal_path)
    if set(journal) != {
        "schema_version",
        "channel",
        "swap_directory",
        "old_identity",
        "new_identity",
    } or journal.get("schema_version") != PROMOTION_JOURNAL_SCHEMA:
        raise SnapshotError(f"invalid promotion journal: {journal_path}")
    if journal.get("channel") != channel_name:
        raise SnapshotError("promotion journal names a different channel")
    swap_name = journal.get("swap_directory")
    if (
        not isinstance(swap_name, str)
        or not swap_name.startswith(prefix)
        or Path(swap_name).name != swap_name
    ):
        raise SnapshotError("promotion journal has an unsafe swap directory")
    swap = channels / swap_name
    old_identity = validate_promotion_identity(journal.get("old_identity"), "old")
    new_identity = validate_promotion_identity(journal.get("new_identity"), "new")
    destination = channels / channel_name
    current_identity = verified_channel_identity(
        destination, channel_name, policy, policy_path, keyrings
    )
    previous = channels / f".{channel_name}.previous"

    if current_identity == new_identity:
        if swap.exists() or swap.is_symlink():
            if verified_channel_identity(
                swap, channel_name, policy, policy_path, keyrings
            ) != old_identity:
                raise SnapshotError("post-exchange swap does not contain the old channel")
            remove_path(previous)
            os.replace(swap, previous)
            fsync_directory(channels)
        elif (
            not previous.exists()
            or verified_channel_identity(
                previous, channel_name, policy, policy_path, keyrings
            )
            != old_identity
        ):
            raise SnapshotError(
                "promotion journal says exchange completed but the old channel is missing"
            )
    elif current_identity == old_identity:
        if swap.exists() or swap.is_symlink():
            if verified_channel_identity(
                swap, channel_name, policy, policy_path, keyrings
            ) != new_identity:
                raise SnapshotError("pre-exchange swap does not contain the new channel")
            remove_path(swap)
            fsync_directory(channels)
    else:
        raise SnapshotError(
            "published channel matches neither identity in its promotion journal"
        )

    unlink_durable(journal_path)
    for orphan in orphans:
        if orphan != swap and (orphan.exists() or orphan.is_symlink()):
            remove_path(orphan)
    if orphans:
        fsync_directory(channels)


def require_rollback_cohort(
    candidate: Path,
    retained: Sequence[Path],
    channels: Path,
    policy: dict[str, Any],
    policy_path: Path,
    keyrings: Sequence[Path],
) -> None:
    candidate_manifest = load_json(candidate / "cohort.json")
    stable_identity = current_stable_identity(
        channels,
        policy,
        policy_path,
        keyrings,
    )
    if (
        stable_identity is not None
        and stable_identity["content_identity"] == candidate_manifest["content_identity"]
    ):
        raise SnapshotError("stable already contains this cohort content identity")
    for rollback in retained:
        if rollback == candidate:
            continue
        rollback_manifest = load_json(rollback / "cohort.json")
        if (rollback / "qualification.json").is_file():
            verify_qualification(rollback, policy)
            return
        if (
            stable_identity is not None
            and rollback_manifest["cohort"] == stable_identity["cohort"]
            and rollback_manifest["content_identity"]
            == stable_identity["content_identity"]
            and sha256(rollback / "cohort.json")
            == stable_identity["cohort_manifest_sha256"]
        ):
            return
    raise SnapshotError(
        "stable promotion requires another distinct retained cohort that is qualified "
        "or matches the current previous-stable identity"
    )


def promote_cohort(args: argparse.Namespace, policy: dict[str, Any]) -> Path:
    channels = args.channels_root.resolve()
    channels.mkdir(parents=True, exist_ok=True)
    lock_path = channels / f".{args.channel}.lock"
    descriptor = os.open(
        lock_path,
        os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise SnapshotError(f"channel lock is not a regular file: {lock_path}")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return promote_cohort_locked(args, policy, channels)
    finally:
        os.close(descriptor)


def promote_cohort_locked(
    args: argparse.Namespace,
    policy: dict[str, Any],
    channels: Path,
) -> Path:
    cohort = args.cohort.resolve()
    keyrings = resolve_keyrings(args.keyring)
    manifest = verify_cohort(cohort, policy, args.policy, keyrings)
    recover_interrupted_promotion(
        channels,
        args.channel,
        policy,
        args.policy,
        keyrings,
    )
    if args.channel == "stable":
        qualification = verify_qualification(cohort, policy)
        cohorts_root = cohort.parent
        if cohorts_root.name != "cohorts":
            raise SnapshotError("stable promotion requires a cohort from an output-root/cohorts tree")
        retained = verified_retained_cohorts(cohorts_root, policy, args.policy, keyrings)
        if cohort not in retained:
            raise SnapshotError("stable candidate is not one of the retained cohorts")
        require_rollback_cohort(
            cohort,
            retained,
            channels,
            policy,
            args.policy,
            keyrings,
        )
    else:
        qualification = None

    destination = channels / args.channel
    staging = Path(
        tempfile.mkdtemp(prefix=f".{args.channel}.promotion.", dir=channels)
    )
    remove_path(staging)
    previous = channels / f".{args.channel}.previous"
    journal_path = channels / f".{args.channel}.promotion.json"
    exchanged = False
    try:
        copy_tree_exact(cohort, staging)
        # Re-verify the staged copy against the manifest and signatures. A
        # source mutation between initial verification and copy cannot pass.
        verify_cohort(
            staging,
            policy,
            args.policy,
            keyrings,
            manifest["cohort"],
        )
        channel_record = {
            "schema_version": 2,
            "channel": args.channel,
            "cohort": manifest["cohort"],
            "cohort_manifest_sha256": sha256(staging / "cohort.json"),
            "content_identity": manifest["content_identity"],
            "promoted_at": dt.datetime.now(dt.timezone.utc)
            .replace(microsecond=0)
            .isoformat(),
        }
        if qualification is not None:
            channel_record["thorch_artifact_sha256"] = qualification[
                "thorch_artifact_sha256"
            ]
        write_json_durable(
            staging / "channel.json",
            channel_record,
        )
        new_identity = channel_identity(manifest, channel_record)
        if verified_channel_identity(
            staging,
            args.channel,
            policy,
            args.policy,
            keyrings,
        ) != new_identity:
            raise SnapshotError("staged channel identity changed before publication")
        if destination.exists() or destination.is_symlink():
            old_identity = verified_channel_identity(
                destination,
                args.channel,
                policy,
                args.policy,
                keyrings,
            )
            write_json_durable(
                journal_path,
                {
                    "schema_version": PROMOTION_JOURNAL_SCHEMA,
                    "channel": args.channel,
                    "swap_directory": staging.name,
                    "old_identity": old_identity,
                    "new_identity": new_identity,
                },
            )
            if (
                os.environ.get("THORCH_BASE_SNAPSHOT_TEST_FAILPOINT")
                == "before-channel-exchange"
            ):
                os._exit(85)
            rename_exchange(staging, destination)
            exchanged = True
            fsync_directory(channels)
            if verified_channel_identity(
                destination,
                args.channel,
                policy,
                args.policy,
                keyrings,
            ) != new_identity or verified_channel_identity(
                staging,
                args.channel,
                policy,
                args.policy,
                keyrings,
            ) != old_identity:
                raise SnapshotError("channel identities changed during atomic exchange")
            if (
                os.environ.get("THORCH_BASE_SNAPSHOT_TEST_FAILPOINT")
                == "after-channel-exchange"
            ):
                os._exit(86)
            remove_path(previous)
            os.replace(staging, previous)
            fsync_directory(channels)
            unlink_durable(journal_path)
        else:
            os.replace(staging, destination)
            fsync_directory(channels)
            remove_path(previous)
            fsync_directory(channels)
        return destination
    finally:
        # After an exchange, the swap directory contains the old published
        # channel. Leave it and the journal intact for deterministic recovery
        # if any subsequent step fails or the process is interrupted.
        if not exchanged or not journal_path.exists():
            remove_path(staging)


def retention_status(args: argparse.Namespace, policy: dict[str, Any]) -> int:
    keyrings = resolve_keyrings(args.keyring)
    cohorts = verified_retained_cohorts(
        args.output_root.resolve() / "cohorts",
        policy,
        args.policy,
        keyrings,
    )
    print(f"base snapshot retention valid: {len(cohorts)} cohorts")
    return 0


def arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy", type=Path, default=repo_root() / "manifests/base-snapshot-policy.json"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create")
    create.add_argument("--cohort", required=True)
    create.add_argument("--output-root", type=Path, required=True)
    create.add_argument("--architecture", default="aarch64")
    create.add_argument("--repo", action="append", required=True)
    create.add_argument("--keyring", action="append", type=Path, required=True)
    create.add_argument(
        "--assert-trusted-mirror-inventory",
        action="store_true",
        help=(
            "manually assert that each copied unsigned ALARM database is the "
            "trusted mirror inventory intended for this cohort"
        ),
    )

    verify = sub.add_parser("verify")
    verify.add_argument("cohort", type=Path)
    verify.add_argument("--keyring", action="append", type=Path, required=True)

    qualify = sub.add_parser("qualify")
    qualify.add_argument("cohort", type=Path)
    qualify.add_argument("--evidence", action="append", default=[])
    qualify.add_argument("--keyring", action="append", type=Path, required=True)
    qualify.add_argument(
        "--assert-manual-trust",
        action="store_true",
        help="manually trust the typed pass evidence while M2 signing is unavailable",
    )

    promote = sub.add_parser("promote")
    promote.add_argument("cohort", type=Path)
    promote.add_argument("--channels-root", type=Path, required=True)
    promote.add_argument("--channel", choices=("nightly", "testing", "stable"), required=True)
    promote.add_argument("--keyring", action="append", type=Path, required=True)

    retention = sub.add_parser("retention-check")
    retention.add_argument("--output-root", type=Path, required=True)
    retention.add_argument("--keyring", action="append", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = arguments(argv)
    try:
        args.policy = args.policy.resolve()
        policy = load_policy(args.policy)
        if args.command == "create":
            print(create_cohort(args, policy))
        elif args.command == "verify":
            keyrings = resolve_keyrings(args.keyring)
            manifest = verify_cohort(args.cohort.resolve(), policy, args.policy, keyrings)
            print(f"base snapshot valid: {manifest['cohort']}")
        elif args.command == "qualify":
            print(qualify_cohort(args, policy))
        elif args.command == "promote":
            print(promote_cohort(args, policy))
        elif args.command == "retention-check":
            return retention_status(args, policy)
        else:
            raise AssertionError(args.command)
    except (SnapshotError, OSError) as exc:
        print(f"base-snapshot: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
