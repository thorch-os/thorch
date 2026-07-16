#!/usr/bin/env python3
"""Validate identities, cache bindings, metadata, and ownership in a package repo."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Set


class RepoError(RuntimeError):
    pass


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BINDING_FIELDS = {
    "schema_version",
    "artifact",
    "artifact_sha256",
    "inputs_sha256",
}


def bsdtar(archive: Path, *args: str) -> str:
    result = subprocess.run(
        ["bsdtar", *args, str(archive)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RepoError(f"cannot inspect {archive.name}: {detail}")
    return result.stdout


def package_files(archive: Path) -> Iterable[str]:
    for raw in bsdtar(archive, "-tf").splitlines():
        path = raw.removeprefix("./")
        if not path or path.endswith("/") or path.startswith("."):
            continue
        yield path


def package_info(archive: Path) -> Dict[str, List[str]]:
    result = subprocess.run(
        ["bsdtar", "-xOqf", str(archive), ".PKGINFO"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["bsdtar", "-xOqf", str(archive), "./.PKGINFO"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RepoError(f"{archive.name} has no readable .PKGINFO: {detail}")

    fields: Dict[str, List[str]] = {}
    for line in result.stdout.splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    for required in ("pkgname", "pkgver", "arch"):
        values = fields.get(required, [])
        if len(values) != 1 or not values[0]:
            raise RepoError(
                f"{archive.name}: .PKGINFO must contain exactly one {required}"
            )
    for dependency in fields.get("depend", []):
        if not dependency.strip():
            raise RepoError(f"{archive.name}: empty dependency in .PKGINFO")
    return fields


def package_archives(repo: Path) -> List[Path]:
    archives = sorted(
        path for path in repo.glob("*.pkg.tar.*") if not path.name.endswith(".sig")
    )
    for archive in archives:
        validate_regular_file(archive, "package archive")
    return archives


def validate_regular_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise RepoError(f"{label} is not a regular file: {path}")


def retained_package_archives(root: Path) -> List[Path]:
    if not root.exists():
        return []
    if root.is_symlink() or not root.is_dir():
        raise RepoError(f"retained repository root is not a directory: {root}")
    archives = sorted(
        path for path in root.rglob("*.pkg.tar.*") if not path.name.endswith(".sig")
    )
    for archive in archives:
        validate_regular_file(archive, "retained package archive")
    return archives


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_artifact_binding(
    archive: Path, binding: Path, expected_inputs_sha256: str | None = None
) -> Dict[str, Any]:
    validate_regular_file(archive, "package archive")
    validate_regular_file(binding, "package artifact binding")
    try:
        data = json.loads(binding.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RepoError(f"cannot read package artifact binding {binding}: {exc}") from exc
    if not isinstance(data, dict) or set(data) != BINDING_FIELDS:
        raise RepoError(
            f"{binding}: binding must contain exactly "
            + ", ".join(sorted(BINDING_FIELDS))
        )
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise RepoError(f"{binding}: unsupported binding schema_version")
    if data["artifact"] != archive.name:
        raise RepoError(
            f"{binding}: artifact name does not match {archive.name}"
        )
    for field in ("artifact_sha256", "inputs_sha256"):
        value = data[field]
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            raise RepoError(f"{binding}: {field} must be a lowercase SHA-256 digest")
    actual_artifact_sha256 = file_sha256(archive)
    if data["artifact_sha256"] != actual_artifact_sha256:
        raise RepoError(
            f"{binding}: artifact digest does not match {archive.name}; "
            "the cached package may have been modified"
        )
    if (
        expected_inputs_sha256 is not None
        and data["inputs_sha256"] != expected_inputs_sha256
    ):
        raise RepoError(
            f"{binding}: declared inputs changed for {archive.name}"
        )
    return data


def validate_artifact_bindings(archives: List[Path], bindings_root: Path) -> None:
    if bindings_root.is_symlink() or not bindings_root.is_dir():
        raise RepoError(f"artifact bindings root is not a directory: {bindings_root}")
    for archive in archives:
        load_artifact_binding(
            archive, bindings_root / f"{archive.name}.json"
        )


def artifact_identity(info: Dict[str, List[str]]) -> tuple[str, str, str]:
    return (info["pkgname"][0], info["pkgver"][0], info["arch"][0])


def validate_replacements(existing: List[Path], candidates: List[Path]) -> None:
    by_identity: Dict[tuple[str, str, str], Path] = {}
    for archive in existing:
        validate_regular_file(archive, "package archive")
        identity = artifact_identity(package_info(archive))
        previous = by_identity.get(identity)
        if previous is not None:
            if file_sha256(previous) != file_sha256(archive):
                raise RepoError(
                    "retained repositories contain different bytes for package identity "
                    f"{identity[0]} {identity[1]} {identity[2]}: "
                    f"{previous}, {archive}"
                )
            continue
        by_identity[identity] = archive

    for candidate in candidates:
        validate_regular_file(candidate, "candidate package")
        identity = artifact_identity(package_info(candidate))
        previous = by_identity.get(identity)
        if previous is not None and file_sha256(previous) != file_sha256(candidate):
            name, version, architecture = identity
            raise RepoError(
                "refusing different bytes for existing package identity "
                f"{name} {version} {architecture}; bump epoch/pkgver/pkgrel "
                f"before replacing {previous.name}"
            )
        by_identity[identity] = candidate


def dependency_name(value: str) -> str:
    return re.split(r"[<>=]", value, maxsplit=1)[0]


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument(
        "--require",
        nargs="*",
        default=[],
        metavar="PACKAGE",
        help="package names that must be represented in the repository",
    )
    parser.add_argument(
        "--candidate",
        action="append",
        type=Path,
        default=[],
        help=(
            "fail if a candidate would replace an existing package with the "
            "same name/version/architecture but different bytes"
        ),
    )
    parser.add_argument(
        "--retained-root",
        type=Path,
        help="also compare candidates with every package in retained repositories",
    )
    parser.add_argument(
        "--bindings-root",
        type=Path,
        help="require a valid input/artifact binding for every current package",
    )
    parser.add_argument(
        "--binding",
        type=Path,
        help="validate this binding for the single --candidate package",
    )
    parser.add_argument(
        "--expected-input-sha256",
        help="with --binding, require this exact declared-input fingerprint",
    )
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    try:
        if args.binding is not None and len(args.candidate) != 1:
            raise RepoError("--binding requires exactly one --candidate")
        if args.expected_input_sha256 is not None:
            if args.binding is None:
                raise RepoError("--expected-input-sha256 requires --binding")
            if not SHA256_RE.fullmatch(args.expected_input_sha256):
                raise RepoError("--expected-input-sha256 must be a lowercase SHA-256 digest")
        if args.bindings_root is not None and args.candidate:
            raise RepoError("--bindings-root cannot be combined with --candidate")

        archives = package_archives(repo)
        retained = (
            retained_package_archives(args.retained_root.absolute())
            if args.retained_root is not None
            else []
        )
        candidates = [path.absolute() for path in args.candidate]
        if args.retained_root is not None or candidates:
            validate_replacements(archives + retained, candidates)
        if candidates:
            if args.binding is not None:
                load_artifact_binding(
                    candidates[0],
                    args.binding.absolute(),
                    args.expected_input_sha256,
                )
            print(f"package replacement valid: {len(args.candidate)} candidate(s)")
            return 0
        if not archives:
            raise RepoError(f"no package archives in {repo}")
        for archive in archives:
            validate_regular_file(archive, "package archive")
        if args.bindings_root is not None:
            validate_artifact_bindings(archives, args.bindings_root.absolute())

        package_names: Set[str] = set()
        metadata: Dict[str, Dict[str, List[str]]] = {}
        owners: Dict[str, str] = {}
        collisions: List[str] = []
        for archive in archives:
            info = package_info(archive)
            name = info["pkgname"][0]
            if name in package_names:
                raise RepoError(f"more than one archive remains for package {name}")
            package_names.add(name)
            metadata[name] = info
            for path in package_files(archive):
                previous = owners.get(path)
                if previous and previous != name:
                    collisions.append(f"{path}: {previous}, {name}")
                else:
                    owners[path] = name

        missing = set(args.require) - package_names
        if missing:
            raise RepoError(
                "required packages are missing: " + ", ".join(sorted(missing))
            )
        if collisions:
            raise RepoError(
                "file ownership collisions detected:\n  " + "\n  ".join(collisions)
            )

        provided_names = set(package_names)
        for info in metadata.values():
            provided_names.update(
                dependency_name(value) for value in info.get("provides", [])
            )
        missing_internal = []
        for name, info in metadata.items():
            for dependency in info.get("depend", []):
                dependency = dependency_name(dependency)
                if (
                    dependency.startswith("thorch-") or dependency == "linux-thorch"
                ) and dependency not in provided_names:
                    missing_internal.append(f"{name}: {dependency}")
        if missing_internal:
            raise RepoError(
                "internal dependencies are absent from the repository:\n  "
                + "\n  ".join(sorted(missing_internal))
            )

        print(
            f"package repository valid: {len(package_names)} packages, "
            f"{len(owners)} uniquely owned files"
        )
        return 0
    except RepoError as exc:
        print(f"package-repo: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
