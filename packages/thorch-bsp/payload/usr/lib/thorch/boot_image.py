#!/usr/bin/env python3
"""Canonical Android boot-image parser and validator for Thorch.

The Thor ABL Linux path consumes a legacy Android boot image whose kernel
field contains a gzip-compressed arm64 Image followed by one or more DTBs.
All build-time and installed-system callers use this module so header, DTB,
and command-line invariants cannot drift between shell scripts.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
from pathlib import Path
import struct
import sys
from typing import Iterable, Sequence
import zlib


ANDROID_MAGIC = b"ANDROID!"
FDT_MAGIC = b"\xd0\r\xfe\xed"
ARM64_IMAGE_MAGIC = b"ARM\x64"
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


class BootImageError(ValueError):
    """Raised when an input violates the Thorch boot-image contract."""


def align(value: int, page_size: int) -> int:
    return ((value + page_size - 1) // page_size) * page_size


class BootImage:
    """Parsed Android boot image header v0 and its payload sections."""

    def __init__(self, path: Path, data: bytes):
        self.path = path
        self.data = data
        if len(data) < 48 or data[:8] != ANDROID_MAGIC:
            raise BootImageError(f"{path} is not an Android boot image")

        (
            self.kernel_size,
            self.kernel_addr,
            self.ramdisk_size,
            self.ramdisk_addr,
            self.second_size,
            self.second_addr,
            self.tags_addr,
            self.page_size,
            self.header_version,
            self.os_version,
        ) = struct.unpack_from("<10I", data, 8)

        if self.header_version != 0:
            raise BootImageError(
                f"{path} has unsupported Android boot header version "
                f"{self.header_version}"
            )
        if (
            self.page_size < 2048
            or self.page_size > 65536
            or self.page_size & (self.page_size - 1)
        ):
            raise BootImageError(f"{path} has invalid page size {self.page_size}")
        if self.kernel_size == 0:
            raise BootImageError(f"{path} has an empty kernel payload")
        if self.ramdisk_size == 0:
            raise BootImageError(f"{path} has an empty ramdisk")
        if len(data) < self.page_size:
            raise BootImageError(f"{path} is smaller than its header page")

        self.kernel_offset = self.page_size
        self.ramdisk_offset = self.kernel_offset + align(
            self.kernel_size, self.page_size
        )
        self.second_offset = self.ramdisk_offset + align(
            self.ramdisk_size, self.page_size
        )
        self.tail_offset = self.second_offset + align(
            self.second_size, self.page_size
        )
        if len(data) < self.tail_offset:
            raise BootImageError(f"{path} is truncated")

        self.header = data[: self.page_size]
        self.kernel_payload = data[
            self.kernel_offset : self.kernel_offset + self.kernel_size
        ]
        self.ramdisk = data[
            self.ramdisk_offset : self.ramdisk_offset + self.ramdisk_size
        ]
        self.second = data[
            self.second_offset : self.second_offset + self.second_size
        ]
        self.tail = data[self.tail_offset :]

        # Android boot header v0 stores the primary command line at 64..575
        # and the continuation at 608..1631. Do not search names, IDs, or page
        # padding, because arbitrary bytes there are not kernel arguments.
        primary = self.header[64:576].split(b"\0", 1)[0]
        extra = self.header[608:1632].split(b"\0", 1)[0]
        try:
            self.command_line = b" ".join(part for part in (primary, extra) if part).decode(
                "ascii"
            )
        except UnicodeDecodeError as exc:
            raise BootImageError(f"{path} command line is not ASCII") from exc
        self.command_line_tokens = self.command_line.split()

    @classmethod
    def read(cls, path: Path | str) -> "BootImage":
        source = Path(path)
        try:
            data = source.read_bytes()
        except OSError as exc:
            raise BootImageError(f"unable to read {source}: {exc}") from exc
        return cls(source, data)

    def command_line_has(self, marker: str) -> bool:
        try:
            encoded = marker.encode("ascii")
        except UnicodeEncodeError as exc:
            raise BootImageError(f"command-line marker is not ASCII: {marker!r}") from exc
        text = encoded.decode("ascii")
        if text.endswith("="):
            return any(token.startswith(text) and len(token) > len(text) for token in self.command_line_tokens)
        return text in self.command_line_tokens

    def require_root_uuid(self, expected_uuid: str) -> None:
        """Require one unambiguous root argument for the expected filesystem."""

        if not expected_uuid or any(character.isspace() for character in expected_uuid):
            raise BootImageError("expected root UUID is empty or contains whitespace")
        expected = f"root=UUID={expected_uuid}"
        root_tokens = [
            token for token in self.command_line_tokens if token.startswith("root=")
        ]
        if root_tokens != [expected]:
            rendered = ", ".join(root_tokens) if root_tokens else "none"
            raise BootImageError(
                f"boot command line root is {rendered}; expected exactly {expected}"
            )


def decompress_kernel_payload(
    payload: bytes, *, allow_raw_fallback: bool = False
) -> tuple[bytes, bytes]:
    """Return the raw arm64 Image and its appended DTB byte stream."""

    try:
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        image = decompressor.decompress(payload) + decompressor.flush()
    except zlib.error as exc:
        if not allow_raw_fallback:
            raise BootImageError(f"kernel payload is not valid gzip: {exc}") from exc
        dtb_at = payload.find(FDT_MAGIC)
        if dtb_at < 0:
            raise BootImageError(
                "kernel payload is neither gzip nor a raw Image with appended DTBs"
            ) from exc
        return payload[:dtb_at], payload[dtb_at:]

    if not decompressor.eof:
        raise BootImageError("kernel gzip payload is truncated")
    return image, decompressor.unused_data


def validate_arm64_image(image: bytes) -> None:
    """Require the fixed 64-byte arm64 Linux Image header and magic."""

    if len(image) < 64:
        raise BootImageError("decompressed kernel is smaller than an arm64 Image header")
    if image[56:60] != ARM64_IMAGE_MAGIC:
        raise BootImageError("decompressed kernel does not have the arm64 Image magic")


def aligned4(value: int) -> int:
    return (value + 3) & ~3


def fdt_facts(dtb: bytes) -> tuple[dict[bytes, bytes], bool]:
    """Structurally parse one FDT and return root properties and symbol-node state."""

    if len(dtb) < 40:
        raise BootImageError("appended DTB is smaller than its header")
    (
        magic,
        total_size,
        struct_offset,
        strings_offset,
        reserve_offset,
        version,
        last_compatible_version,
        _boot_cpu,
        strings_size,
        struct_size,
    ) = struct.unpack_from(">10I", dtb)
    if magic != int.from_bytes(FDT_MAGIC, "big") or total_size != len(dtb):
        raise BootImageError("appended DTB has inconsistent header size or magic")
    if version < 16 or last_compatible_version > version:
        raise BootImageError("appended DTB has an unsupported FDT version")
    if reserve_offset < 40 or reserve_offset % 8:
        raise BootImageError("appended DTB has an invalid reserve-map offset")
    if struct_offset < 40 or struct_offset % 4:
        raise BootImageError("appended DTB has an invalid structure-block offset")
    if strings_offset < 40:
        raise BootImageError("appended DTB has an invalid strings-block offset")
    struct_end = struct_offset + struct_size
    strings_end = strings_offset + strings_size
    if struct_end > total_size or strings_end > total_size:
        raise BootImageError("appended DTB block extends past total size")
    if max(struct_offset, strings_offset) < min(struct_end, strings_end):
        raise BootImageError("appended DTB structure and strings blocks overlap")

    reserve_position = reserve_offset
    while True:
        if reserve_position + 16 > total_size:
            raise BootImageError("appended DTB reserve map is unterminated")
        address, size = struct.unpack_from(">QQ", dtb, reserve_position)
        reserve_position += 16
        if address == 0 and size == 0:
            break
    if (
        max(reserve_offset, struct_offset) < min(reserve_position, struct_end)
        or max(reserve_offset, strings_offset) < min(reserve_position, strings_end)
    ):
        raise BootImageError("appended DTB reserve map overlaps another block")

    strings = dtb[strings_offset:strings_end]
    structure = dtb[struct_offset:struct_end]
    position = 0
    nodes: list[bytes] = []
    root_properties: dict[bytes, bytes] = {}
    has_symbols = False
    saw_end = False
    while position + 4 <= len(structure):
        token = struct.unpack_from(">I", structure, position)[0]
        position += 4
        if token == FDT_BEGIN_NODE:
            end = structure.find(b"\0", position)
            if end < 0:
                raise BootImageError("appended DTB has an unterminated node name")
            name = structure[position:end]
            if not nodes and name:
                raise BootImageError("appended DTB root node name is not empty")
            nodes.append(name)
            has_symbols = has_symbols or name == b"__symbols__"
            position = aligned4(end + 1)
        elif token == FDT_END_NODE:
            if not nodes:
                raise BootImageError("appended DTB closes a node that was not opened")
            nodes.pop()
        elif token == FDT_PROP:
            if not nodes or position + 8 > len(structure):
                raise BootImageError("appended DTB has a malformed property")
            value_size, name_offset = struct.unpack_from(">II", structure, position)
            position += 8
            if name_offset >= len(strings):
                raise BootImageError("appended DTB property name is outside strings block")
            name_end = strings.find(b"\0", name_offset)
            if name_end < 0:
                raise BootImageError("appended DTB property name is unterminated")
            value_end = position + value_size
            if value_end > len(structure):
                raise BootImageError("appended DTB property value is truncated")
            if len(nodes) == 1:
                root_properties[strings[name_offset:name_end]] = structure[position:value_end]
            position = aligned4(value_end)
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            if nodes:
                raise BootImageError("appended DTB ended with unclosed nodes")
            saw_end = True
            if any(structure[position:]):
                raise BootImageError("appended DTB has data after its end token")
            break
        else:
            raise BootImageError(f"appended DTB has unknown structure token {token}")
        if position > len(structure):
            raise BootImageError("appended DTB structure alignment exceeds its block")
    if not saw_end:
        raise BootImageError("appended DTB structure block has no end token")
    return root_properties, has_symbols


def parse_dtbs(blob: bytes, *, allow_prefix_junk: bool = False) -> list[bytes]:
    """Parse a consecutive flattened-device-tree stream."""

    if allow_prefix_junk and blob and not blob.startswith(FDT_MAGIC):
        start = blob.find(FDT_MAGIC)
        if start < 0:
            raise BootImageError("kernel payload does not contain an appended DTB")
        blob = blob[start:]

    dtbs: list[bytes] = []
    pos = 0
    while pos < len(blob):
        if len(blob) < pos + 8 or blob[pos : pos + 4] != FDT_MAGIC:
            raise BootImageError("kernel payload has a malformed appended DTB table")
        size = struct.unpack_from(">I", blob, pos + 4)[0]
        if size < 40 or len(blob) < pos + size:
            raise BootImageError("kernel payload has a truncated appended DTB")
        dtb = blob[pos : pos + size]
        fdt_facts(dtb)
        dtbs.append(dtb)
        pos += size
    if not dtbs:
        raise BootImageError("kernel payload does not contain an appended DTB")
    return dtbs


def validate_dtb_contract(
    dtbs: Sequence[bytes],
    *,
    require_symbols: bool,
    require_thor: bool,
    forbid_aim300: bool,
) -> None:
    facts = [fdt_facts(dtb) for dtb in dtbs]
    if require_symbols and any(not has_symbols for _properties, has_symbols in facts):
        raise BootImageError("kernel payload contains a DTB without ROCKNIX overlay symbols")

    thor_dtbs = [
        properties
        for properties, _has_symbols in facts
        if properties.get(b"model", b"").rstrip(b"\0") == b"AYN Thor"
        and b"ayn,thor" in properties.get(b"compatible", b"").split(b"\0")
    ]
    if require_thor and len(thor_dtbs) != 1:
        raise BootImageError(
            f"kernel payload contains {len(thor_dtbs)} ROCKNIX Thor DTBs, expected 1"
        )
    if forbid_aim300 and any(
        b"qcom,qcs8550-aim300-aiot"
        in properties.get(b"compatible", b"").split(b"\0")
        for properties, _has_symbols in facts
    ):
        raise BootImageError("kernel payload contains the generic AIM300 DTB")


def analyze_kernel(
    boot: BootImage,
    *,
    allow_raw_fallback: bool,
    require_symbols: bool,
    require_thor: bool,
    forbid_aim300: bool,
) -> tuple[bytes, list[bytes]]:
    image, trailer = decompress_kernel_payload(
        boot.kernel_payload, allow_raw_fallback=allow_raw_fallback
    )
    validate_arm64_image(image)
    dtbs = parse_dtbs(trailer, allow_prefix_junk=allow_raw_fallback)
    validate_dtb_contract(
        dtbs,
        require_symbols=require_symbols,
        require_thor=require_thor,
        forbid_aim300=forbid_aim300,
    )
    return image, dtbs


def validate_boot(
    boot: BootImage,
    *,
    command_line_markers: Iterable[str],
    allow_raw_fallback: bool,
    require_symbols: bool,
    require_thor: bool,
    forbid_aim300: bool,
) -> tuple[bytes, list[bytes]]:
    missing = [marker for marker in command_line_markers if not boot.command_line_has(marker)]
    if missing:
        raise BootImageError("boot command line is missing: " + ", ".join(missing))
    return analyze_kernel(
        boot,
        allow_raw_fallback=allow_raw_fallback,
        require_symbols=require_symbols,
        require_thor=require_thor,
        forbid_aim300=forbid_aim300,
    )


def padded(blob: bytes, page_size: int) -> bytes:
    return blob + (b"\0" * ((page_size - len(blob) % page_size) % page_size))


def build_replaced_kernel(
    template: BootImage, image: bytes, dtb_paths: Sequence[Path]
) -> bytes:
    validate_arm64_image(image)
    if not dtb_paths:
        raise BootImageError("no ROCKNIX SM8550 DTBs were supplied")

    dtbs: list[bytes] = []
    for path in dtb_paths:
        data = path.read_bytes()
        parsed = parse_dtbs(data)
        if len(parsed) != 1 or len(parsed[0]) != len(data):
            raise BootImageError(f"{path} is not exactly one flattened device tree")
        dtbs.append(parsed[0])
    validate_dtb_contract(
        dtbs, require_symbols=True, require_thor=False, forbid_aim300=False
    )

    payload = gzip.compress(image, compresslevel=9, mtime=0) + b"".join(dtbs)
    header = bytearray(template.header)
    struct.pack_into("<I", header, 8, len(payload))
    return (
        bytes(header)
        + padded(payload, template.page_size)
        + padded(template.ramdisk, template.page_size)
        + padded(template.second, template.page_size)
        + template.tail
    )


def embedded_config(image: bytes) -> dict[str, str]:
    start = image.find(b"IKCFG_ST")
    end = image.find(b"IKCFG_ED", start)
    if start < 0 or end < 0:
        raise BootImageError("kernel does not embed a config")
    blob = image[start + len(b"IKCFG_ST") : end].lstrip(b"\x00\n")
    try:
        config_text = gzip.decompress(blob).decode("utf-8", "replace")
    except OSError as exc:
        raise BootImageError(f"could not decompress embedded kernel config: {exc}") from exc

    config: dict[str, str] = {}
    for line in config_text.splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            config[line.split()[1]] = "n"
    return config


def required_config(path: Path) -> dict[str, str]:
    required: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise BootImageError(f"invalid config requirement in {path}: {raw}")
        key, value = line.split("=", 1)
        required[key] = value
    return required


def write_durable(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def command_validate(args: argparse.Namespace) -> None:
    boot = BootImage.read(args.boot_image)
    if args.expect_root_uuid is not None:
        boot.require_root_uuid(args.expect_root_uuid)
    image, dtbs = validate_boot(
        boot,
        command_line_markers=args.require_cmdline,
        allow_raw_fallback=args.allow_raw_kernel,
        require_symbols=args.require_symbols,
        require_thor=args.require_thor,
        forbid_aim300=args.forbid_aim300,
    )
    if args.expect_ramdisk:
        expected_ramdisk = Path(args.expect_ramdisk).read_bytes()
        if not expected_ramdisk:
            raise BootImageError(f"expected ramdisk is empty: {args.expect_ramdisk}")
        if boot.ramdisk != expected_ramdisk:
            raise BootImageError("embedded ramdisk differs from the expected initramfs")
    if args.json:
        print(
            json.dumps(
                {
                    "boot_image": str(boot.path),
                    "header_version": boot.header_version,
                    "page_size": boot.page_size,
                    "kernel_size": boot.kernel_size,
                    "ramdisk_size": boot.ramdisk_size,
                    "second_size": boot.second_size,
                    "decompressed_kernel_size": len(image),
                    "dtb_count": len(dtbs),
                },
                sort_keys=True,
            )
        )


def command_prepare_repack(args: argparse.Namespace) -> None:
    boot = BootImage.read(args.boot_image)
    validate_boot(
        boot,
        command_line_markers=(),
        allow_raw_fallback=False,
        require_symbols=True,
        require_thor=True,
        forbid_aim300=True,
    )
    outdir = Path(args.output_directory)
    outdir.mkdir(parents=True, exist_ok=True)
    write_durable(outdir / "kernel", boot.kernel_payload)
    if boot.second:
        write_durable(outdir / "second", boot.second)
    (outdir / "bootimg.env").write_text(
        "\n".join(
            [
                f"KERNEL_ADDR=0x{boot.kernel_addr:x}",
                f"RAMDISK_ADDR=0x{boot.ramdisk_addr:x}",
                f"SECOND_ADDR=0x{boot.second_addr:x}",
                f"TAGS_ADDR=0x{boot.tags_addr:x}",
                f"PAGE_SIZE={boot.page_size}",
                f"HAS_SECOND={1 if boot.second else 0}",
                "",
            ]
        ),
        encoding="ascii",
    )


def command_extract_kernel(args: argparse.Namespace) -> None:
    boot = BootImage.read(args.boot_image)
    image, _dtbs = analyze_kernel(
        boot,
        allow_raw_fallback=True,
        require_symbols=args.require_symbols,
        require_thor=args.require_thor,
        forbid_aim300=args.forbid_aim300,
    )
    write_durable(Path(args.output), image)


def command_replace_kernel(args: argparse.Namespace) -> None:
    template = BootImage.read(args.template)
    image = Path(args.image).read_bytes()
    data = build_replaced_kernel(template, image, [Path(item) for item in args.dtb])
    write_durable(Path(args.output), data)


def command_check_config(args: argparse.Namespace) -> None:
    if args.boot_image:
        boot = BootImage.read(args.source)
        image, _dtbs = analyze_kernel(
            boot,
            allow_raw_fallback=True,
            require_symbols=False,
            require_thor=False,
            forbid_aim300=False,
        )
    else:
        image = Path(args.source).read_bytes()
        validate_arm64_image(image)
    actual = embedded_config(image)
    expected = required_config(Path(args.required))
    missing = [f"{key}={value}" for key, value in expected.items() if actual.get(key) != value]
    if missing:
        raise BootImageError("kernel config is missing:\n  " + "\n  ".join(missing))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate", help="validate a Thorch boot image")
    validate.add_argument("boot_image")
    validate.add_argument("--require-cmdline", action="append", default=[])
    validate.add_argument("--allow-raw-kernel", action="store_true")
    validate.add_argument("--require-symbols", action="store_true")
    validate.add_argument("--require-thor", action="store_true")
    validate.add_argument("--forbid-aim300", action="store_true")
    validate.add_argument("--expect-ramdisk")
    validate.add_argument(
        "--expect-root-uuid",
        help="require exactly one root=UUID= argument matching this filesystem UUID",
    )
    validate.add_argument("--json", action="store_true")
    validate.set_defaults(function=command_validate)

    prepare = subcommands.add_parser(
        "prepare-repack", help="extract source sections needed by mkbootimg"
    )
    prepare.add_argument("boot_image")
    prepare.add_argument("output_directory")
    prepare.set_defaults(function=command_prepare_repack)

    extract = subcommands.add_parser(
        "extract-kernel", help="extract the raw arm64 Image from a boot image"
    )
    extract.add_argument("boot_image")
    extract.add_argument("output")
    extract.add_argument("--require-symbols", action="store_true")
    extract.add_argument("--require-thor", action="store_true")
    extract.add_argument("--forbid-aim300", action="store_true")
    extract.set_defaults(function=command_extract_kernel)

    replace = subcommands.add_parser(
        "replace-kernel", help="replace a template's kernel/DTB payload"
    )
    replace.add_argument("template")
    replace.add_argument("image")
    replace.add_argument("output")
    replace.add_argument("dtb", nargs="+")
    replace.set_defaults(function=command_replace_kernel)

    config = subcommands.add_parser(
        "check-config", help="check embedded kernel config requirements"
    )
    config.add_argument("source")
    config.add_argument("required")
    config.add_argument("--boot-image", action="store_true")
    config.set_defaults(function=command_check_config)

    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        args.function(args)
    except (BootImageError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
