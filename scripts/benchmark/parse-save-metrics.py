#!/usr/bin/env python3
"""Parse the backend snapshot and named publication timing records emitted by `spore vm save`."""

from __future__ import annotations

import argparse
import json
import sys

MAX_SNAPSHOT_LINE_BYTES = 8192
SNAPSHOT_PREFIXES = {"kvm": "kvm snapshot metrics: ", "hvf": "hvf snapshot metrics: "}
SNAPSHOT_FIELDS = ("machine_ms", "devices_ms", "generation_ms", "memory_ms", "disk_ms", "manifest_ms", "snapshot_total_ms")
NAMED_PREFIXES = {"kvm": "kvm named snapshot publication metrics: ", "hvf": "hvf named snapshot publication metrics: "}
NAMED_FIELDS = (
    "cache_lock_wait_ms", "manifest_write_ms", "active_lease_handoff_ms",
    "lifecycle_spec_ms", "final_publication_ms", "source_pause_ms",
)


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


def parse_named_publication_metric(line: str) -> dict[str, int | str]:
    if len(line.encode("utf-8")) > MAX_SNAPSHOT_LINE_BYTES:
        raise ValueError(f"named publication metric line exceeds {MAX_SNAPSHOT_LINE_BYTES} bytes")
    backend = ""
    payload = ""
    for candidate, prefix in NAMED_PREFIXES.items():
        marker = line.find(prefix)
        if marker >= 0:
            backend = candidate
            payload = line[marker + len(prefix):].strip()
            break
    if not backend:
        raise ValueError("missing named snapshot publication metric prefix")
    values: dict[str, str] = {}
    for token in payload.split():
        if token.count("=") != 1:
            raise ValueError(f"malformed named publication metric token: {token!r}")
        key, value = token.split("=", 1)
        if key in values:
            raise ValueError(f"duplicate named publication metric field: {key}")
        values[key] = value
    if set(values) != set(NAMED_FIELDS):
        missing = set(NAMED_FIELDS) - set(values)
        unknown = set(values) - set(NAMED_FIELDS)
        if missing:
            raise ValueError(f"missing named publication metric field: {min(missing)}")
        raise ValueError(f"unknown named publication metric field: {min(unknown)}")
    result: dict[str, int | str] = {"schema": 1, "backend": backend}
    for key in NAMED_FIELDS:
        value = values[key]
        if not value.isascii() or not value.isdecimal():
            raise ValueError(f"invalid named publication metric field: {key}")
        result[key] = int(value)
    publication_sum = sum(int(result[key]) for key in (
        "manifest_write_ms", "active_lease_handoff_ms",
        "lifecycle_spec_ms", "final_publication_ms",
    ))
    if result["source_pause_ms"] < publication_sum:
        raise ValueError("named source pause is shorter than its durable publication phases")
    return result


def self_test() -> None:
    snapshot = parse_snapshot_metric(
        "info: kvm snapshot metrics: mode=dirty-log "
        "machine_ms=1 devices_ms=2 generation_ms=3 memory_ms=4 disk_ms=5 "
        "manifest_ms=6 snapshot_total_ms=21 extra=7"
    )
    assert snapshot == {"schema": 1, "backend": "kvm", "machine_ms": 1,
                        "devices_ms": 2, "generation_ms": 3, "memory_ms": 4,
                        "disk_ms": 5, "manifest_ms": 6, "snapshot_total_ms": 21}
    named = parse_named_publication_metric(
        "info: hvf named snapshot publication metrics: cache_lock_wait_ms=1 "
        "manifest_write_ms=2 active_lease_handoff_ms=3 lifecycle_spec_ms=4 "
        "final_publication_ms=5 source_pause_ms=15"
    )
    assert named == {"schema": 1, "backend": "hvf", "cache_lock_wait_ms": 1,
                     "manifest_write_ms": 2, "active_lease_handoff_ms": 3,
                     "lifecycle_spec_ms": 4, "final_publication_ms": 5,
                     "source_pause_ms": 15}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("line", nargs="?")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--snapshot", action="store_true", help="parse the backend snapshot timing record")
    mode.add_argument("--named-publication", action="store_true", help="parse the named save publication record")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("save metric parser self-test ok")
        return 0
    line = args.line if args.line is not None else sys.stdin.read()
    try:
        result = parse_named_publication_metric(line) if args.named_publication else parse_snapshot_metric(line)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
