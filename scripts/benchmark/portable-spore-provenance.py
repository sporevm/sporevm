#!/usr/bin/env python3
"""Validate and fingerprint a portable/local-CAS saved spore benchmark input."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import tempfile


PIN_REFERENCE = "sporevm-disk-pin.json"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    entries = sorted(root.rglob("*"))
    for path in entries:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ValueError(f"portable migration input contains symlink: {path.relative_to(root)}")
        if stat.S_ISDIR(metadata.st_mode):
            entry_type = b"D"
        elif stat.S_ISREG(metadata.st_mode):
            entry_type = b"F"
        else:
            raise ValueError(f"portable migration input contains special entry: {path.relative_to(root)}")
        relative = path.relative_to(root).as_posix().encode()
        digest.update(entry_type)
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if entry_type == b"F":
            digest.update(metadata.st_size.to_bytes(8, "big"))
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
    return digest.hexdigest()


def inspect(spore_dir: Path, spore_bin: Path) -> dict[str, object]:
    spore_dir = spore_dir.resolve(strict=True)
    spore_bin = spore_bin.resolve(strict=True)
    if not spore_dir.is_dir() or not spore_bin.is_file():
        raise ValueError("spore input must be a directory and binary must be a file")
    if (spore_dir / PIN_REFERENCE).exists():
        raise ValueError("portable migration input must not carry a host-private disk pin")
    manifest_path = spore_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    disk = manifest.get("disk")
    if not isinstance(disk, dict) or disk.get("kind") != "chunk-index-disk-v0":
        raise ValueError("portable migration input must contain a chunk-index disk")
    index_digest = disk.get("base")
    if not isinstance(index_digest, str) or not index_digest.startswith("blake3:"):
        raise ValueError("portable migration input has an invalid disk index digest")
    index_hex = index_digest.removeprefix("blake3:")
    index_path = spore_dir / "cas/rootfs/blake3/indexes" / f"{index_hex}.json"
    index = json.loads(index_path.read_text(encoding="utf-8"))
    chunks = index.get("chunks")
    if not isinstance(chunks, list):
        raise ValueError("portable migration input has an invalid disk index")
    objects: dict[str, int] = {}
    for entry in chunks:
        digest = entry.get("digest") if isinstance(entry, dict) else None
        if not isinstance(digest, str) or not digest.startswith("blake3:"):
            raise ValueError("portable migration input has an invalid object digest")
        object_path = spore_dir / "cas/rootfs/blake3/objects" / f"{digest.removeprefix('blake3:')}.chunk"
        if object_path.is_symlink() or not object_path.is_file():
            raise ValueError(f"portable migration input is missing object {digest}")
        objects[digest] = object_path.stat().st_size
    stat = spore_bin.stat()
    return {
        "schema": 1,
        "spore_dir": str(spore_dir),
        "spore_tree_sha256": tree_sha256(spore_dir),
        "manifest_sha256": file_sha256(manifest_path),
        "disk_index_digest": index_digest,
        "local_object_count": len(objects),
        "local_object_bytes": sum(objects.values()),
        "spore_bin": str(spore_bin),
        "spore_bin_sha256": file_sha256(spore_bin),
        "spore_bin_bytes": stat.st_size,
    }


def self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        spore_dir = root / "parent.spore"
        object_dir = spore_dir / "cas/rootfs/blake3/objects"
        index_dir = spore_dir / "cas/rootfs/blake3/indexes"
        object_dir.mkdir(parents=True)
        index_dir.mkdir(parents=True)
        object_digest = "b" * 64
        index_digest = "a" * 64
        (object_dir / f"{object_digest}.chunk").write_bytes(b"payload")
        (index_dir / f"{index_digest}.json").write_text(
            json.dumps({"chunks": [{"logical_chunk": 0, "digest": f"blake3:{object_digest}"}]}),
            encoding="utf-8",
        )
        (spore_dir / "manifest.json").write_text(
            json.dumps({"disk": {"kind": "chunk-index-disk-v0", "base": f"blake3:{index_digest}"}}),
            encoding="utf-8",
        )
        binary = root / "spore"
        binary.write_bytes(b"binary")
        result = inspect(spore_dir, binary)
        assert result["local_object_count"] == 1
        assert result["local_object_bytes"] == 7
        assert len(result["spore_tree_sha256"]) == 64
        (spore_dir / PIN_REFERENCE).write_text("{}", encoding="utf-8")
        try:
            inspect(spore_dir, binary)
        except ValueError as error:
            assert "must not carry" in str(error)
        else:
            raise AssertionError("accepted pinned migration input")
        (spore_dir / PIN_REFERENCE).unlink()
        (spore_dir / "bad-link").symlink_to("manifest.json")
        try:
            inspect(spore_dir, binary)
        except ValueError as error:
            assert "contains symlink" in str(error)
        else:
            raise AssertionError("accepted symlink in migration input")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spore-dir", type=Path)
    parser.add_argument("--spore-bin", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("portable spore provenance self-test ok")
        return 0
    if args.spore_dir is None or args.spore_bin is None:
        parser.error("--spore-dir and --spore-bin are required")
    try:
        result = inspect(args.spore_dir, args.spore_bin)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
