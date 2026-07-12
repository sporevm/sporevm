#!/usr/bin/env python3
"""Emit stable JSONL metadata for fixture-owned filesystem paths."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def file_digest(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return f"sha256:{digest.hexdigest()}"


def kind(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISBLK(mode):
        return "block"
    if stat.S_ISCHR(mode):
        return "character"
    return "unknown"


def extended_attributes(path: str) -> dict[str, str]:
    try:
        names = os.listxattr(path, follow_symlinks=False)
    except OSError:
        return {}
    values: dict[str, str] = {}
    for name in sorted(names, key=os.fsencode):
        try:
            values[name] = os.getxattr(path, name, follow_symlinks=False).hex()
        except OSError:
            values[name] = "<unreadable>"
    return values


def record(path: str, hardlink_roots: dict[tuple[int, int], str]) -> dict[str, object]:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return {
            "path": path,
            "type": "missing",
            "mode": None,
            "uid": None,
            "gid": None,
            "size": None,
            "content_digest": None,
            "link": None,
            "mtime_ns": None,
            "hardlink_to": None,
            "xattrs": {},
        }

    entry_kind = kind(metadata.st_mode)
    hardlink_to = None
    if entry_kind == "file" and metadata.st_nlink > 1:
        hardlink_to = hardlink_roots.setdefault((metadata.st_dev, metadata.st_ino), path)
    return {
        "path": path,
        "type": entry_kind,
        "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
        "uid": metadata.st_uid,
        "gid": metadata.st_gid,
        # Directory sizes depend on the backing filesystem and are not part of
        # Dockerfile result semantics. Regular files and symlinks are stable.
        "size": metadata.st_size if entry_kind in {"file", "symlink"} else None,
        "content_digest": file_digest(path) if entry_kind == "file" else None,
        "link": os.readlink(path) if entry_kind == "symlink" else None,
        "mtime_ns": metadata.st_mtime_ns,
        "hardlink_to": hardlink_to,
        "xattrs": extended_attributes(path),
    }


def descendants(prefix: str) -> list[str]:
    try:
        metadata = os.lstat(prefix)
    except FileNotFoundError:
        return [prefix]
    if not stat.S_ISDIR(metadata.st_mode):
        return [prefix]

    paths = [prefix]
    for root, directory_names, file_names in os.walk(prefix, followlinks=False):
        directory_names.sort()
        file_names.sort()
        paths.extend(os.path.join(root, name) for name in directory_names)
        paths.extend(os.path.join(root, name) for name in file_names)
    return paths


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: spore-build-conformance-scan PATH...", file=sys.stderr)
        return 2

    paths: set[str] = set()
    for raw_prefix in sys.argv[1:]:
        prefix = str(Path(raw_prefix))
        if not prefix.startswith("/"):
            print(f"scan prefix must be absolute: {raw_prefix}", file=sys.stderr)
            return 2
        paths.update(descendants(prefix))

    hardlink_roots: dict[tuple[int, int], str] = {}
    for path in sorted(paths, key=os.fsencode):
        print(json.dumps(record(path, hardlink_roots), sort_keys=True, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
