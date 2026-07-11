#!/usr/bin/env python3
"""Parse the stable, bounded disk-snapshot metric emitted by `spore save`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PREFIX = "disk snapshot metrics: "
GOLDEN_PATH = Path(__file__).parents[2] / "src/testdata/disk-snapshot-metrics-v1.txt"
MAX_LINE_BYTES = 4096
MAX_SNAPSHOT_LINE_BYTES = 8192
SNAPSHOT_PREFIXES = {"kvm": "kvm snapshot metrics: ", "hvf": "hvf snapshot metrics: "}
SNAPSHOT_FIELDS = ("machine_ms", "devices_ms", "generation_ms", "memory_ms", "disk_ms", "manifest_ms", "snapshot_total_ms")
BOOL_FIELDS = {"full_scan"}
UINT_FIELDS = {
    "schema", "logical_bytes", "chunks", "dirty_chunks", "non_dirty_chunks",
    "sealed_candidate_chunks", "sealed_chunks", "parent_chunks_reused", "parent_referenced_bytes",
    "parent_objects_linked", "parent_objects_reused", "parent_objects_copied",
    "parent_object_bytes", "parent_link_bytes", "parent_reuse_bytes",
    "parent_copy_bytes", "parent_link_us", "parent_reuse_us", "parent_copy_us", "parent_sync_us",
    "zero_scan_us", "hash_us", "object_write_us", "index_bytes",
    "index_encode_us", "index_publish_us", "total_us",
}
FIELDS = BOOL_FIELDS | UINT_FIELDS


def parse_metric(line: str) -> dict[str, int | bool]:
    encoded = line.encode("utf-8")
    if len(encoded) > MAX_LINE_BYTES:
        raise ValueError(f"metric line exceeds {MAX_LINE_BYTES} bytes")
    marker = line.find(PREFIX)
    if marker < 0:
        raise ValueError("missing disk snapshot metric prefix")
    tokens = line[marker + len(PREFIX):].strip().split()
    if len(tokens) != len(FIELDS):
        raise ValueError("metric field count does not match schema 1")
    result: dict[str, int | bool] = {}
    for token in tokens:
        if token.count("=") != 1:
            raise ValueError(f"malformed metric token: {token!r}")
        key, value = token.split("=", 1)
        if key not in FIELDS:
            raise ValueError(f"unknown metric field: {key}")
        if key in result:
            raise ValueError(f"duplicate metric field: {key}")
        if key in BOOL_FIELDS:
            if value not in ("true", "false"):
                raise ValueError(f"invalid boolean for {key}")
            result[key] = value == "true"
        else:
            if not value.isascii() or not value.isdecimal():
                raise ValueError(f"invalid unsigned integer for {key}")
            parsed = int(value)
            if parsed > 2**64 - 1:
                raise ValueError(f"unsigned integer overflow for {key}")
            result[key] = parsed
    if result["schema"] != 1:
        raise ValueError("unsupported disk snapshot metric schema")
    if result["dirty_chunks"] + result["non_dirty_chunks"] != result["chunks"]:
        raise ValueError("dirty and non-dirty chunk counts do not cover the disk")
    if result["sealed_candidate_chunks"] + result["parent_chunks_reused"] != result["chunks"]:
        raise ValueError("sealed and parent-reused chunks do not cover the disk")
    if result["full_scan"]:
        if result["sealed_candidate_chunks"] != result["chunks"]:
            raise ValueError("full scan does not seal every chunk")
    elif result["sealed_candidate_chunks"] != result["dirty_chunks"]:
        raise ValueError("incremental sealed chunks do not match dirty chunks")
    classes = (("link", "linked"), ("reuse", "reused"), ("copy", "copied"))
    if sum(result[f"parent_{name}_bytes"] for name, _ in classes) != result["parent_object_bytes"]:
        raise ValueError("parent object byte classes do not cover published bytes")
    for name, outcome in classes:
        objects = result[f"parent_objects_{outcome}"]
        bytes_count = result[f"parent_{name}_bytes"]
        if (objects == 0) != (bytes_count == 0):
            raise ValueError(f"parent {name} object and byte counts disagree")
    if sum(result[key] for key in ("parent_objects_linked", "parent_objects_reused", "parent_objects_copied")) > result["parent_chunks_reused"]:
        raise ValueError("published parent objects exceed reused parent chunks")
    if result["parent_object_bytes"] > result["parent_referenced_bytes"]:
        raise ValueError("published parent bytes exceed logical parent references")
    if result["sealed_candidate_chunks"] != result["sealed_chunks"]:
        raise ValueError("candidate and sealed chunk counts differ")
    return result


def parse_snapshot_metric(line: str) -> dict[str, int | str]:
    if len(line.encode("utf-8")) > MAX_SNAPSHOT_LINE_BYTES:
        raise ValueError(f"snapshot metric line exceeds {MAX_SNAPSHOT_LINE_BYTES} bytes")
    backend = ""
    payload = ""
    for candidate, prefix in SNAPSHOT_PREFIXES.items():
        marker = line.find(prefix)
        if marker >= 0:
            backend = candidate
            payload = line[marker + len(prefix):].strip()
            break
    if not backend:
        raise ValueError("missing backend snapshot metric prefix")
    values: dict[str, str] = {}
    for token in payload.split():
        if token.count("=") != 1:
            raise ValueError(f"malformed snapshot metric token: {token!r}")
        key, value = token.split("=", 1)
        if key in values:
            raise ValueError(f"duplicate snapshot metric field: {key}")
        values[key] = value
    result: dict[str, int | str] = {"schema": 1, "backend": backend}
    for key in SNAPSHOT_FIELDS:
        value = values.get(key)
        if value is None or not value.isascii() or not value.isdecimal():
            raise ValueError(f"missing or invalid snapshot metric field: {key}")
        result[key] = int(value)
    return result


def self_test() -> None:
    golden = GOLDEN_PATH.read_text(encoding="utf-8").strip()
    parsed = parse_metric("info: " + golden)
    assert parsed["parent_sync_us"] == 13
    snapshot = parse_snapshot_metric(
        "info: kvm snapshot metrics: mode=dirty-log "
        "machine_ms=1 devices_ms=2 generation_ms=3 memory_ms=4 disk_ms=5 "
        "manifest_ms=6 snapshot_total_ms=21 extra=7"
    )
    assert snapshot == {"schema": 1, "backend": "kvm", "machine_ms": 1,
                        "devices_ms": 2, "generation_ms": 3, "memory_ms": 4,
                        "disk_ms": 5, "manifest_ms": 6, "snapshot_total_ms": 21}
    for bad in (
        golden.rsplit(" ", 1)[0],
        golden + " extra=1",
        golden.replace("schema=1", "schema=2"),
        golden.replace("dirty_chunks=1", "dirty_chunks=-1"),
        golden.replace("parent_chunks_reused=2", "parent_chunks_reused=99"),
        golden.replace("parent_link_bytes=65536", "parent_link_bytes=0"),
        golden.replace("sealed_candidate_chunks=1", "sealed_candidate_chunks=2"),
    ):
        try:
            parse_metric(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted invalid metric: {bad}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("line", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--snapshot", action="store_true", help="parse the backend snapshot timing record")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("save metric parser self-test ok")
        return 0
    line = args.line if args.line is not None else sys.stdin.read()
    try:
        result = parse_snapshot_metric(line) if args.snapshot else parse_metric(line)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
