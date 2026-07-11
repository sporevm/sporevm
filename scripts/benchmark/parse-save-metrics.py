#!/usr/bin/env python3
"""Parse the stable, bounded disk-snapshot metric emitted by `spore save`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PREFIX = "disk snapshot metrics: "
TESTDATA_DIR = Path(__file__).parents[2] / "src/testdata"
GOLDEN_PATHS = {
    1: TESTDATA_DIR / "disk-snapshot-metrics-v1.txt",
    2: TESTDATA_DIR / "disk-snapshot-metrics-v2.txt",
}
MAX_LINE_BYTES = 4096
MAX_SNAPSHOT_LINE_BYTES = 8192
SNAPSHOT_PREFIXES = {"kvm": "kvm snapshot metrics: ", "hvf": "hvf snapshot metrics: "}
SNAPSHOT_FIELDS = ("machine_ms", "devices_ms", "generation_ms", "memory_ms", "disk_ms", "manifest_ms", "snapshot_total_ms")
BOOL_FIELDS = {"full_scan"}
COMMON_UINT_FIELDS = {
    "schema", "logical_bytes", "chunks", "dirty_chunks", "non_dirty_chunks",
    "sealed_candidate_chunks", "sealed_chunks", "parent_chunks_reused", "parent_referenced_bytes",
    "parent_objects_linked", "parent_objects_reused", "parent_objects_copied",
    "parent_object_bytes", "parent_link_bytes", "parent_reuse_bytes",
    "parent_copy_bytes", "parent_link_us", "parent_reuse_us", "parent_copy_us", "parent_sync_us",
    "zero_scan_us", "hash_us", "object_write_us", "index_bytes",
    "index_encode_us", "index_publish_us", "total_us",
}
SCHEMA_FIELDS = {
    1: BOOL_FIELDS | COMMON_UINT_FIELDS,
    2: BOOL_FIELDS | COMMON_UINT_FIELDS | {
        "clean_zero_chunks_reused", "dirty_zero_chunks_recorded",
    },
}


def parse_metric(line: str) -> dict[str, int | bool]:
    encoded = line.encode("utf-8")
    if len(encoded) > MAX_LINE_BYTES:
        raise ValueError(f"metric line exceeds {MAX_LINE_BYTES} bytes")
    marker = line.find(PREFIX)
    if marker < 0:
        raise ValueError("missing disk snapshot metric prefix")
    tokens = line[marker + len(PREFIX):].strip().split()
    raw: dict[str, str] = {}
    for token in tokens:
        if token.count("=") != 1:
            raise ValueError(f"malformed metric token: {token!r}")
        key, value = token.split("=", 1)
        if key in raw:
            raise ValueError(f"duplicate metric field: {key}")
        raw[key] = value

    schema_value = raw.get("schema")
    if schema_value is None or not schema_value.isascii() or not schema_value.isdecimal():
        raise ValueError("missing or invalid disk snapshot metric schema")
    schema = int(schema_value)
    fields = SCHEMA_FIELDS.get(schema)
    if fields is None:
        raise ValueError("unsupported disk snapshot metric schema")
    actual_fields = set(raw)
    if actual_fields != fields:
        missing = fields - actual_fields
        unknown = actual_fields - fields
        if missing:
            raise ValueError(f"missing metric field: {min(missing)}")
        raise ValueError(f"unknown metric field: {min(unknown)}")

    result: dict[str, int | bool] = {}
    for key, value in raw.items():
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

    if result["dirty_chunks"] + result["non_dirty_chunks"] != result["chunks"]:
        raise ValueError("dirty and non-dirty chunk counts do not cover the disk")
    if schema == 1:
        if result["sealed_candidate_chunks"] + result["parent_chunks_reused"] != result["chunks"]:
            raise ValueError("sealed and parent-reused chunks do not cover the disk")
        if result["full_scan"]:
            if result["sealed_candidate_chunks"] != result["chunks"]:
                raise ValueError("full scan does not seal every chunk")
        elif result["sealed_candidate_chunks"] != result["dirty_chunks"]:
            raise ValueError("incremental sealed chunks do not match dirty chunks")
    else:
        if sum(result[key] for key in (
            "sealed_chunks", "parent_chunks_reused",
            "clean_zero_chunks_reused", "dirty_zero_chunks_recorded",
        )) != result["chunks"]:
            raise ValueError("sealed, parent, clean-zero, and dirty-zero chunks do not cover the disk")
        if result["full_scan"]:
            if result["parent_chunks_reused"] != 0:
                raise ValueError("full scan reuses parent chunks")
        else:
            if result["sealed_chunks"] + result["dirty_zero_chunks_recorded"] != result["dirty_chunks"]:
                raise ValueError("incremental sealed and dirty-zero chunks do not cover dirty chunks")
            if result["parent_chunks_reused"] + result["clean_zero_chunks_reused"] != result["non_dirty_chunks"]:
                raise ValueError("incremental parent and clean-zero chunks do not cover non-dirty chunks")
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
    golden_v1 = GOLDEN_PATHS[1].read_text(encoding="utf-8").strip()
    parsed_v1 = parse_metric("info: " + golden_v1)
    assert parsed_v1["schema"] == 1
    assert parsed_v1["parent_sync_us"] == 13
    golden_v2 = GOLDEN_PATHS[2].read_text(encoding="utf-8").strip()
    parsed_v2 = parse_metric("info: " + golden_v2)
    assert parsed_v2["schema"] == 2
    assert parsed_v2["clean_zero_chunks_reused"] == 1
    assert parsed_v2["dirty_zero_chunks_recorded"] == 1
    full_scan_v2 = golden_v2
    for old, new in (
        ("dirty_chunks=2 non_dirty_chunks=2", "dirty_chunks=0 non_dirty_chunks=4"),
        ("full_scan=false", "full_scan=true"),
        ("sealed_candidate_chunks=1 sealed_chunks=1", "sealed_candidate_chunks=4 sealed_chunks=4"),
        ("clean_zero_chunks_reused=1", "clean_zero_chunks_reused=0"),
        ("dirty_zero_chunks_recorded=1", "dirty_zero_chunks_recorded=0"),
        ("parent_chunks_reused=1", "parent_chunks_reused=0"),
        ("parent_referenced_bytes=65536", "parent_referenced_bytes=0"),
        ("parent_objects_linked=1", "parent_objects_linked=0"),
        ("parent_object_bytes=65536", "parent_object_bytes=0"),
        ("parent_link_bytes=65536", "parent_link_bytes=0"),
        ("parent_link_us=11", "parent_link_us=0"),
        ("parent_sync_us=13", "parent_sync_us=0"),
    ):
        full_scan_v2 = full_scan_v2.replace(old, new)
    parsed_full_scan_v2 = parse_metric(full_scan_v2)
    assert parsed_full_scan_v2["full_scan"] is True
    assert parsed_full_scan_v2["sealed_chunks"] == 4
    snapshot = parse_snapshot_metric(
        "info: kvm snapshot metrics: mode=dirty-log "
        "machine_ms=1 devices_ms=2 generation_ms=3 memory_ms=4 disk_ms=5 "
        "manifest_ms=6 snapshot_total_ms=21 extra=7"
    )
    assert snapshot == {"schema": 1, "backend": "kvm", "machine_ms": 1,
                        "devices_ms": 2, "generation_ms": 3, "memory_ms": 4,
                        "disk_ms": 5, "manifest_ms": 6, "snapshot_total_ms": 21}
    for bad in (
        golden_v1.rsplit(" ", 1)[0],
        golden_v1 + " extra=1",
        golden_v1.replace("schema=1", "schema=2"),
        golden_v1.replace("dirty_chunks=1", "dirty_chunks=-1"),
        golden_v1.replace("parent_chunks_reused=2", "parent_chunks_reused=99"),
        golden_v1.replace("parent_link_bytes=65536", "parent_link_bytes=0"),
        golden_v1.replace("sealed_candidate_chunks=1", "sealed_candidate_chunks=2"),
        golden_v2.rsplit(" ", 1)[0],
        golden_v2 + " extra=1",
        golden_v2.replace("schema=2", "schema=3"),
        golden_v2.replace("chunks=4", "chunks=5"),
        golden_v2.replace(
            "dirty_chunks=2 non_dirty_chunks=2",
            "dirty_chunks=1 non_dirty_chunks=3",
        ),
        golden_v2.replace("parent_chunks_reused=1", "parent_chunks_reused=2"),
        golden_v2.replace("sealed_candidate_chunks=1", "sealed_candidate_chunks=2"),
        golden_v2.replace("full_scan=false", "full_scan=true"),
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
