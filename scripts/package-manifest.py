#!/usr/bin/env python3
"""Read and validate Thorch's canonical package/profile manifest."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List


PACKAGE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9@._+-]*$")
INPUT_RE = re.compile(
    r"^(?:[A-Z][A-Z0-9_]*)(?:/[A-Za-z0-9@%_.,+:/=-]+)*$"
)
PROFILE_NAMES = {"build", "image", "release"}
BUILD_INPUT_VARIABLES = {
    "THORCH_FIRMWARE_DIR",
    "THORCH_ROCKNIX_DIR",
    "THORCH_ROCKNIX_KERNEL_DIR",
    "THORCH_ROCKNIX_RUNTIME_DIR",
}


class ManifestError(ValueError):
    pass


DEPENDENCY_FIELDS = ("depends", "makedepends", "checkdepends")


def dependency_name(value: str) -> str:
    return re.split(r"[<>=]", value, maxsplit=1)[0].strip()


def parse_srcinfo(path: Path) -> Dict[str, List[str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ManifestError(f"unable to read {path}: {exc}") from exc
    fields: Dict[str, List[str]] = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        fields.setdefault(key, []).append(value)
    names = fields.get("pkgname", [])
    if len(names) != 1:
        raise ManifestError(f"{path}: expected exactly one pkgname")
    return fields


def dependency_values(fields: Dict[str, List[str]]) -> List[str]:
    values: List[str] = []
    for key, entries in fields.items():
        if key in DEPENDENCY_FIELDS or any(
            key.startswith(field + "_") for field in DEPENDENCY_FIELDS
        ):
            values.extend(dependency_name(value) for value in entries)
    return values


def validate_dependency_order(
    records: List[Dict[str, Any]], aliases: Dict[str, str], srcinfo_dir: Path
) -> None:
    order = {record["name"]: index for index, record in enumerate(records)}
    metadata: Dict[str, Dict[str, List[str]]] = {}
    providers: Dict[str, str] = {name: name for name in order}
    for record in records:
        name = record["name"]
        path = srcinfo_dir / f"{name}.SRCINFO"
        fields = parse_srcinfo(path)
        if fields["pkgname"][0] != name:
            raise ManifestError(
                f"{path}: pkgname={fields['pkgname'][0]} does not match {name}"
            )
        metadata[name] = fields
        for key, entries in fields.items():
            if key != "provides" and not key.startswith("provides_"):
                continue
            for provided in entries:
                provided_name = dependency_name(provided)
                previous = providers.get(provided_name)
                if previous is not None and previous != name:
                    raise ManifestError(
                        f"internal provider {provided_name} is ambiguous: {previous}, {name}"
                    )
                providers[provided_name] = name
    for alias, target in aliases.items():
        providers.setdefault(alias, target)

    failures: List[str] = []
    for consumer, fields in metadata.items():
        for dependency in dependency_values(fields):
            if not (dependency.startswith("thorch-") or dependency == "linux-thorch"):
                continue
            provider = providers.get(dependency)
            if provider is None:
                failures.append(f"{consumer}: internal dependency has no provider: {dependency}")
            elif order[provider] >= order[consumer]:
                failures.append(
                    f"{consumer}: provider {provider} must precede consumer for {dependency}"
                )
    if failures:
        raise ManifestError("dependency order invalid:\n  " + "\n  ".join(sorted(set(failures))))


def default_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def load_manifest(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ManifestError(f"manifest does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ManifestError("manifest root must be an object")
    return data


def _expect_string(record: Dict[str, Any], field: str, package: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise ManifestError(f"{package}: {field} must be a non-empty string")
    return value


def _expect_string_list(record: Dict[str, Any], field: str, package: str) -> List[str]:
    value = record.get(field)
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ManifestError(f"{package}: {field} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise ManifestError(f"{package}: {field} contains duplicate values")
    return value


def pkgbuild_name(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ManifestError(f"missing PKGBUILD: {path}") from exc
    match = re.search(r"(?m)^pkgname=([a-z0-9@._+-]+)\s*(?:#.*)?$", text)
    if not match:
        raise ManifestError(f"{path}: pkgname must be one static package name")
    return match.group(1)


def validate_manifest(data: Dict[str, Any], repo: Path, check_tree: bool = True) -> List[Dict[str, Any]]:
    if data.get("schema_version") != 1:
        raise ManifestError("schema_version must be 1")

    records = data.get("packages")
    if not isinstance(records, list) or not records:
        raise ManifestError("packages must be a non-empty array")

    names: set[str] = set()
    paths: set[str] = set()
    normalized: List[Dict[str, Any]] = []
    for index, raw in enumerate(records):
        if not isinstance(raw, dict):
            raise ManifestError(f"packages[{index}] must be an object")
        unknown_fields = set(raw) - {
            "name",
            "path",
            "profiles",
            "build_inputs",
            "version_inputs",
        }
        if unknown_fields:
            raise ManifestError(
                f"packages[{index}]: unknown fields: "
                + ", ".join(sorted(unknown_fields))
            )
        name = _expect_string(raw, "name", f"packages[{index}]")
        if not PACKAGE_NAME_RE.fullmatch(name):
            raise ManifestError(f"invalid package name: {name}")
        if name in names:
            raise ManifestError(f"duplicate package name: {name}")
        names.add(name)

        path = _expect_string(raw, "path", name)
        if path.startswith("/") or ".." in Path(path).parts or not path.startswith("packages/"):
            raise ManifestError(f"{name}: path must be beneath packages/: {path}")
        if path in paths:
            raise ManifestError(f"duplicate package path: {path}")
        paths.add(path)

        profiles = _expect_string_list(raw, "profiles", name)
        unknown_profiles = set(profiles) - PROFILE_NAMES
        if unknown_profiles:
            raise ManifestError(f"{name}: unknown profiles: {', '.join(sorted(unknown_profiles))}")
        if "build" not in profiles:
            raise ManifestError(f"{name}: every package must be in the build profile")

        build_inputs = _expect_string_list(raw, "build_inputs", name)
        for build_input in build_inputs:
            if not INPUT_RE.fullmatch(build_input):
                raise ManifestError(f"{name}: invalid build input: {build_input}")
            if any(part in {".", ".."} for part in build_input.split("/")):
                raise ManifestError(
                    f"{name}: build input contains a traversal component: {build_input}"
                )
            variable = build_input.split("/", 1)[0]
            if variable not in BUILD_INPUT_VARIABLES:
                raise ManifestError(
                    f"{name}: unsupported build input variable: {variable}"
                )

        version_inputs = raw.get("version_inputs", [])
        if version_inputs:
            version_inputs = _expect_string_list(raw, "version_inputs", name)
        elif not isinstance(version_inputs, list):
            raise ManifestError(f"{name}: version_inputs must be a string array")
        for version_input in version_inputs:
            parts = Path(version_input).parts
            if version_input.startswith("/") or ".." in parts:
                raise ManifestError(
                    f"{name}: version input must be repository-relative: {version_input}"
                )

        if check_tree:
            package_dir = repo / path
            if not package_dir.is_dir():
                raise ManifestError(f"{name}: package directory does not exist: {path}")
            actual_name = pkgbuild_name(package_dir / "PKGBUILD")
            if actual_name != name:
                raise ManifestError(
                    f"{name}: {path}/PKGBUILD declares pkgname={actual_name}"
                )

        normalized.append(raw)

    aliases = data.get("aliases", {})
    if not isinstance(aliases, dict):
        raise ManifestError("aliases must be an object")
    for alias, target in aliases.items():
        if not isinstance(alias, str) or not PACKAGE_NAME_RE.fullmatch(alias):
            raise ManifestError(f"invalid package alias: {alias!r}")
        if not isinstance(target, str) or target not in names:
            raise ManifestError(f"alias {alias} refers to unknown package: {target!r}")
        if alias in names:
            raise ManifestError(f"alias shadows package name: {alias}")

    if check_tree:
        package_dirs = {
            str(path.relative_to(repo))
            for path in (repo / "packages").iterdir()
            if path.is_dir() and (path / "PKGBUILD").is_file()
        }
        missing = package_dirs - paths
        extra = paths - package_dirs
        if missing:
            raise ManifestError(
                "PKGBUILD directories missing from manifest: " + ", ".join(sorted(missing))
            )
        if extra:
            raise ManifestError(
                "manifest paths without PKGBUILDs: " + ", ".join(sorted(extra))
            )

    return normalized


def format_values(values: Iterable[str], output_format: str) -> str:
    values = list(values)
    if output_format == "lines":
        return "\n".join(values)
    if output_format == "space":
        return " ".join(values)
    if output_format == "csv":
        return ",".join(values)
    raise AssertionError(output_format)


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=default_repo_root())
    parser.add_argument("--manifest", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("validate", help="validate schema and package tree coverage")

    dependencies = subparsers.add_parser(
        "validate-dependencies",
        help="validate internal dependency providers and manifest build order",
    )
    dependencies.add_argument("--srcinfo-dir", type=Path, required=True)

    profile = subparsers.add_parser("profile", help="print a profile in build order")
    profile.add_argument("name", choices=sorted(PROFILE_NAMES))
    profile.add_argument("--format", choices=("lines", "space", "csv"), default="lines")

    select = subparsers.add_parser(
        "select", help="validate and order a comma-separated package selection"
    )
    select.add_argument("--profile", choices=sorted(PROFILE_NAMES), default="build")
    select.add_argument("--packages", required=True)
    select.add_argument("--format", choices=("lines", "space", "csv"), default="lines")

    inputs = subparsers.add_parser("inputs", help="print build inputs for one package")
    inputs.add_argument("package")

    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    manifest_path = args.manifest or repo / "manifests" / "packages.json"
    if not manifest_path.is_absolute():
        manifest_path = repo / manifest_path
    try:
        data = load_manifest(manifest_path)
        records = validate_manifest(data, repo)
        by_name = {record["name"]: record for record in records}
        aliases = data.get("aliases", {})

        if args.command == "validate":
            print(
                f"package manifest valid: {len(records)} packages, "
                f"{sum('image' in record['profiles'] for record in records)} image packages"
            )
            return 0

        if args.command == "validate-dependencies":
            validate_dependency_order(records, aliases, args.srcinfo_dir.resolve())
            print(f"package dependency order valid: {len(records)} packages")
            return 0

        if args.command == "profile":
            values = [record["name"] for record in records if args.name in record["profiles"]]
        elif args.command == "select":
            requested = [item.strip() for item in args.packages.split(",")]
            if any(not item for item in requested):
                raise ManifestError("package selection contains an empty name")
            requested = [aliases.get(item, item) for item in requested]
            if len(requested) != len(set(requested)):
                raise ManifestError("package selection contains duplicate names")
            unknown = set(requested) - set(by_name)
            if unknown:
                raise ManifestError("unknown packages: " + ", ".join(sorted(unknown)))
            outside = [name for name in requested if args.profile not in by_name[name]["profiles"]]
            if outside:
                raise ManifestError(
                    f"packages are not in the {args.profile} profile: " + ", ".join(outside)
                )
            selected = set(requested)
            values = [record["name"] for record in records if record["name"] in selected]
        elif args.command == "inputs":
            package = aliases.get(args.package, args.package)
            if package not in by_name:
                raise ManifestError(f"unknown package: {args.package}")
            record = by_name[package]
            values = [record["path"], *record["build_inputs"]]
        else:
            raise AssertionError(args.command)

        print(format_values(values, getattr(args, "format", "lines")))
        return 0
    except ManifestError as exc:
        print(f"package-manifest: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
