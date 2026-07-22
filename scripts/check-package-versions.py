#!/usr/bin/env python3
"""Require a monotonic Arch package version when declared inputs change."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple


VERSION_ASSIGNMENT = re.compile(
    r"(?m)^(epoch|pkgver|pkgrel)=([^\s#]+)\s*(?:#.*)?$"
)
STATIC_VALUE = re.compile(r"^[A-Za-z0-9._+~-]+$")
VERSION_FUNCTION = re.compile(
    r"(?m)^[ \t]*(?:(?:function[ \t]+)?(epoch|pkgver|pkgrel)[ \t]*"
    r"(?:\([ \t]*\))?)[ \t]*\{"
)


class CheckError(RuntimeError):
    pass


def run_git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise CheckError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout


def load_json_bytes(raw: bytes, label: str) -> Dict[str, Any]:
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CheckError(f"invalid package manifest at {label}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("packages"), list):
        raise CheckError(f"invalid package manifest structure at {label}")
    return data


def manifest_records(data: Dict[str, Any], label: str) -> Dict[str, Dict[str, Any]]:
    records: Dict[str, Dict[str, Any]] = {}
    for record in data["packages"]:
        if not isinstance(record, dict):
            raise CheckError(f"{label}: every package record must be an object")
        name = record.get("name")
        path = record.get("path")
        build_inputs = record.get("build_inputs")
        if not isinstance(name, str) or not isinstance(path, str) or not isinstance(build_inputs, list):
            raise CheckError(f"{label}: package records need name, path, and build_inputs")
        if name in records:
            raise CheckError(f"{label}: duplicate package: {name}")
        records[name] = record
    return records


def git_file(repo: Path, revision: str, path: str) -> Optional[bytes]:
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{revision}:{path}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def parse_pkgver(raw: bytes, label: str) -> str:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CheckError(f"{label}: PKGBUILD is not UTF-8") from exc
    dynamic = sorted(set(VERSION_FUNCTION.findall(text)))
    if dynamic:
        raise CheckError(
            f"{label}: dynamic version functions are unsupported: {', '.join(dynamic)}"
        )
    values: Dict[str, str] = {}
    for key, value in VERSION_ASSIGNMENT.findall(text):
        if key in values:
            raise CheckError(f"{label}: {key} must be assigned exactly once")
        value = value.strip("'\"")
        if not STATIC_VALUE.fullmatch(value):
            raise CheckError(
                f"{label}: {key} must be a static value so CI can compare package versions"
            )
        values[key] = value
    missing = {"pkgver", "pkgrel"} - set(values)
    if missing:
        raise CheckError(f"{label}: missing static {', '.join(sorted(missing))}")
    epoch = values.get("epoch", "0")
    if not epoch.isdigit():
        raise CheckError(f"{label}: epoch must be a non-negative integer")
    return f"{epoch}:{values['pkgver']}-{values['pkgrel']}"


def changed_paths(repo: Path, base: str) -> Set[str]:
    changed = {
        line
        for line in run_git(repo, "diff", "--name-only", "--no-renames", base, "--").splitlines()
        if line
    }
    changed.update(
        line
        for line in run_git(
            repo, "ls-files", "--others", "--exclude-standard"
        ).splitlines()
        if line
    )
    return changed


def path_matches(changed: str, declared: str) -> bool:
    declared = declared.rstrip("/")
    return changed == declared or changed.startswith(declared + "/")


def record_inputs(record: Dict[str, Any]) -> List[str]:
    inputs = [record["path"]]
    extra = record.get("version_inputs", [])
    if not isinstance(extra, list) or any(not isinstance(item, str) for item in extra):
        raise CheckError(f"{record['name']}: version_inputs must be a string array")
    inputs.extend(extra)
    return inputs


def compare_versions(vercmp: str, current: str, previous: str) -> int:
    result = subprocess.run(
        [vercmp, current, previous],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise CheckError(f"vercmp failed for {current} and {previous}: {detail}")
    try:
        return int(result.stdout.strip())
    except ValueError as exc:
        raise CheckError(f"vercmp returned invalid output: {result.stdout!r}") from exc


def resolve_base(repo: Path, base_ref: str) -> str:
    run_git(repo, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    merge_base = run_git(repo, "merge-base", "HEAD", base_ref).strip()
    if not merge_base:
        raise CheckError(f"no merge base between HEAD and {base_ref}")
    return merge_base


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo", type=Path, default=Path(__file__).resolve().parent.parent
    )
    parser.add_argument(
        "--base-ref",
        default=os.environ.get("THORCH_VERSION_BASE", "origin/main"),
        help="branch or commit whose merge base is the comparison point",
    )
    parser.add_argument(
        "--vercmp",
        default=os.environ.get("VERCMP") or shutil.which("vercmp"),
        help="path to pacman's vercmp command",
    )
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    manifest_path = repo / "manifests" / "packages.json"
    try:
        current_manifest = load_json_bytes(
            manifest_path.read_bytes(), str(manifest_path)
        )
        current_records = manifest_records(current_manifest, str(manifest_path))
        base = resolve_base(repo, args.base_ref)
        base_manifest_raw = git_file(repo, base, "manifests/packages.json")
        if base_manifest_raw is None:
            # The manifest's introductory change should not require every existing
            # package to bump. Package-directory changes are still checked below.
            base_records = current_records
        else:
            base_records = manifest_records(
                load_json_bytes(base_manifest_raw, f"{base}:manifests/packages.json"),
                f"{base}:manifests/packages.json",
            )

        paths = changed_paths(repo, base)
        changed_packages: List[Tuple[str, str, str]] = []
        new_packages: List[str] = []
        for name, current_record in current_records.items():
            previous_record = base_records.get(name, current_record)
            declared_inputs = set(record_inputs(current_record)) | set(
                record_inputs(previous_record)
            )
            inputs_changed = any(
                path_matches(path, declared)
                for path in paths
                for declared in declared_inputs
            )
            manifest_inputs_changed = any(
                current_record.get(field) != previous_record.get(field)
                for field in ("path", "build_inputs", "version_inputs")
            )
            if not inputs_changed and not manifest_inputs_changed:
                continue

            current_pkgbuild_path = current_record["path"] + "/PKGBUILD"
            current_pkgbuild = (repo / current_pkgbuild_path).read_bytes()
            current_version = parse_pkgver(current_pkgbuild, current_pkgbuild_path)
            previous_pkgbuild_path = previous_record["path"] + "/PKGBUILD"
            previous_pkgbuild = git_file(repo, base, previous_pkgbuild_path)
            if previous_pkgbuild is None:
                new_packages.append(name)
                continue
            previous_version = parse_pkgver(
                previous_pkgbuild, f"{base}:{previous_pkgbuild_path}"
            )
            changed_packages.append((name, current_version, previous_version))

        if changed_packages and not args.vercmp:
            raise CheckError(
                "vercmp is required when package inputs changed; install pacman-contrib "
                "or run this check in the supported builder"
            )

        failures = []
        for name, current, previous in changed_packages:
            if compare_versions(args.vercmp, current, previous) <= 0:
                failures.append(
                    f"{name}: inputs changed but version did not increase "
                    f"({previous} -> {current})"
                )

        if failures:
            for failure in failures:
                print(f"package-version: {failure}", file=sys.stderr)
            return 1

        checked = len(changed_packages)
        suffix = f"; {len(new_packages)} new package(s) accepted" if new_packages else ""
        print(f"package versions valid: {checked} changed package(s) checked{suffix}")
        return 0
    except (CheckError, FileNotFoundError) as exc:
        print(f"package-version: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
