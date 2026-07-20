#!/usr/bin/env python3
"""Validate a static x86-64 /init and package a deterministic newc archive."""

import argparse
import os
from pathlib import Path
import struct
import tempfile


UINT32_MAX = (1 << 32) - 1


def epoch(value: str) -> int:
    if not value.isascii() or not value.isdecimal():
        raise argparse.ArgumentTypeError("must be an unsigned 32-bit integer")
    parsed = int(value)
    if parsed > UINT32_MAX:
        raise argparse.ArgumentTypeError("must be an unsigned 32-bit integer")
    return parsed


def validate_init(path: Path, label: str) -> bytes:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise SystemExit(f"error: {label} /init is not an ELF binary")
    if data[4] != 2 or data[5] != 1:
        raise SystemExit(f"error: {label} /init must be little-endian ELF64")
    if struct.unpack_from("<H", data, 18)[0] != 62:
        raise SystemExit(f"error: {label} /init must target x86-64")

    program_offset = struct.unpack_from("<Q", data, 32)[0]
    program_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if program_size < 4 or program_offset + program_size * program_count > len(data):
        raise SystemExit(f"error: {label} /init has malformed program headers")
    for index in range(program_count):
        offset = program_offset + index * program_size
        if struct.unpack_from("<I", data, offset)[0] == 3:
            raise SystemExit(f"error: {label} /init is dynamically linked")
    return data


def pad(stream, size: int, alignment: int = 4) -> None:
    padding = (-size) % alignment
    if padding:
        stream.write(b"\0" * padding)


def write_entry(stream, inode: int, name: str, mode: int, payload: bytes, links: int, mtime: int) -> None:
    encoded_name = name.encode("ascii") + b"\0"
    # ino, mode, uid, gid, nlink, mtime, filesize, device fields, namesize, check
    fields = (
        inode, mode, 0, 0, links, mtime, len(payload),
        0, 0, 0, 0, len(encoded_name), 0,
    )
    header = b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields)
    stream.write(header)
    stream.write(encoded_name)
    pad(stream, len(header) + len(encoded_name))
    stream.write(payload)
    pad(stream, len(payload))


def build_archive(init: bytes, output: Path, mtime: int, directories: list[str]) -> None:
    entries = [(".", 0o040755, b"", 2)]
    entries.extend((name, 0o040755, b"", 2) for name in directories)
    entries.append(("init", 0o100755, init, 1))
    entries.sort(key=lambda entry: entry[0])

    output.parent.mkdir(parents=True, exist_ok=True)
    process_umask = os.umask(0)
    os.umask(process_umask)
    temporary_fd, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    try:
        with os.fdopen(temporary_fd, "wb") as stream:
            for inode, (name, mode, payload, links) in enumerate(entries, start=1):
                write_entry(stream, inode, name, mode, payload, links, mtime)
            write_entry(stream, len(entries) + 1, "TRAILER!!!", 0, b"", 1, mtime)
            pad(stream, stream.tell(), 512)
        os.chmod(temporary_name, 0o666 & ~process_umask)
        os.replace(temporary_name, output)
    except BaseException:
        Path(temporary_name).unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-epoch")
    validate.add_argument("value", type=epoch)
    build = commands.add_parser("build")
    build.add_argument("--label", required=True)
    build.add_argument("--mtime", type=epoch, default=0)
    build.add_argument("--directory", action="append", default=[])
    build.add_argument("init", type=Path)
    build.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "validate-epoch":
        print(args.value)
        return
    build_archive(validate_init(args.init, args.label), args.output, args.mtime, args.directory)


if __name__ == "__main__":
    main()
