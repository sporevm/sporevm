#!/usr/bin/env python3
"""Analyze chunked-rootfs economics from a product-path trace.

The trace is emitted by setting SPOREVM_ROOTFS_TRACE for a representative
`spore run --from` command. This script combines that sparse read trace with a
whole-image chunk scan so we can decide whether chunked rootfs is worth turning
into a runtime feature.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import time
import tempfile
from pathlib import Path
from typing import Any


DEFAULT_CHUNK_SIZES = (4096, 16 * 1024, 64 * 1024, 256 * 1024)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", required=True, type=Path, help="rootfs ext4 artifact path")
    parser.add_argument("--trace", required=True, type=Path, help="SPOREVM_ROOTFS_TRACE JSONL path")
    parser.add_argument(
        "--replay-store",
        action="store_true",
        help="materialize local chunk objects and replay traced reads with cached and uncached verification",
    )
    parser.add_argument(
        "--replay-dir",
        type=Path,
        help="directory for replay chunk objects; implies --replay-store and preserves the store",
    )
    parser.add_argument(
        "--chunk-size",
        dest="chunk_sizes",
        action="append",
        type=parse_size,
        help="candidate chunk size; may be repeated",
    )
    parser.add_argument("--output", type=Path, help="write JSON summary to this path")
    return parser.parse_args()


def parse_size(raw: str) -> int:
    text = raw.strip().lower()
    multiplier = 1
    if text.endswith("kib"):
        multiplier = 1024
        text = text[:-3]
    elif text.endswith("ki"):
        multiplier = 1024
        text = text[:-2]
    elif text.endswith("k"):
        multiplier = 1024
        text = text[:-1]
    elif text.endswith("mib"):
        multiplier = 1024 * 1024
        text = text[:-3]
    elif text.endswith("m"):
        multiplier = 1024 * 1024
        text = text[:-1]
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("chunk size must be positive")
    return value * multiplier


def load_events(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            events.append(json.loads(line))
    return events


def traced_reads(events: list[dict[str, Any]], rootfs_size: int) -> list[tuple[int, int]]:
    reads: list[tuple[int, int]] = []
    for event in events:
        if event.get("event") != "block_source_read":
            continue
        offset = int(event["offset"])
        length = int(event["len"])
        if length < 0 or offset < 0:
            raise ValueError(f"negative read in trace: offset={offset} len={length}")
        if length == 0:
            continue
        end = offset + length
        if end > rootfs_size:
            raise ValueError(f"trace read exceeds rootfs size: offset={offset} len={length} size={rootfs_size}")
        reads.append((offset, length))
    return reads


def chunk_len(rootfs_size: int, chunk_size: int, chunk_index: int) -> int:
    start = chunk_index * chunk_size
    return max(0, min(chunk_size, rootfs_size - start))


def traced_working_set(events: list[dict[str, Any]], rootfs_size: int, chunk_size: int) -> dict[str, Any]:
    read_events = traced_reads(events, rootfs_size)
    chunks: set[int] = set()
    read_bytes = 0
    max_end = 0
    for offset, length in read_events:
        read_bytes += length
        end = offset + length
        max_end = max(max_end, end)
        first = offset // chunk_size
        last = (end - 1) // chunk_size
        chunks.update(range(first, last + 1))

    verify_bytes = sum(chunk_len(rootfs_size, chunk_size, chunk) for chunk in chunks)
    return {
        "read_events": len(read_events),
        "read_bytes": read_bytes,
        "max_read_end": max_end,
        "unique_chunks_touched": len(chunks),
        "verify_bytes_if_chunked": verify_bytes,
        "verify_fraction_of_rootfs": verify_bytes / rootfs_size if rootfs_size else 0,
        "overfetch_ratio": verify_bytes / read_bytes if read_bytes else 0,
    }


def scan_rootfs(path: Path, rootfs_size: int, chunk_size: int) -> dict[str, Any]:
    zero_chunks = 0
    nonzero_chunks = 0
    unique_nonzero_hashes: set[bytes] = set()
    chunk_count = math.ceil(rootfs_size / chunk_size)
    zero_cache: dict[int, bytes] = {}
    start = time.perf_counter()

    with path.open("rb") as f:
        for chunk_index in range(chunk_count):
            expected_len = chunk_len(rootfs_size, chunk_size, chunk_index)
            data = f.read(expected_len)
            if len(data) != expected_len:
                raise ValueError(f"short rootfs read at chunk {chunk_index}: got {len(data)} expected {expected_len}")
            zero = zero_cache.get(len(data))
            if zero is None:
                zero = b"\0" * len(data)
                zero_cache[len(data)] = zero
            if data == zero:
                zero_chunks += 1
                continue
            nonzero_chunks += 1
            unique_nonzero_hashes.add(hashlib.sha256(data).digest())

    scan_ms = int((time.perf_counter() - start) * 1000)
    zero_bitmap_bytes = math.ceil(chunk_count / 8)
    binary_index_bytes = 256 + zero_bitmap_bytes + (nonzero_chunks * 32)
    json_index_estimate_bytes = 256 + zero_bitmap_bytes + (nonzero_chunks * 92)
    return {
        "chunk_count": chunk_count,
        "zero_chunks": zero_chunks,
        "nonzero_chunks": nonzero_chunks,
        "unique_nonzero_chunks": len(unique_nonzero_hashes),
        "duplicate_nonzero_chunks": nonzero_chunks - len(unique_nonzero_hashes),
        "zero_fraction": zero_chunks / chunk_count if chunk_count else 0,
        "binary_index_estimate_bytes": binary_index_bytes,
        "json_index_estimate_bytes": json_index_estimate_bytes,
        "scan_ms": scan_ms,
        "hash_note": "sha256 used as a stable uniqueness proxy; runtime rootfs verification is still BLAKE3 today",
    }


def proof_sidecar_control(path: Path, rootfs_size: int) -> dict[str, Any]:
    sidecar = json.dumps(
        {
            "kind": "rootfs-proof-sidecar-control-v0",
            "path": str(path),
            "size": rootfs_size,
        },
        sort_keys=True,
    ).encode("utf-8")
    start = time.perf_counter_ns()
    parsed = json.loads(sidecar)
    stat = path.stat()
    ok = parsed["size"] == stat.st_size == rootfs_size
    elapsed_us = (time.perf_counter_ns() - start) // 1000
    return {
        "ok": ok,
        "elapsed_us": elapsed_us,
        "sidecar_bytes": len(sidecar),
        "note": "control only: models stat plus small proof parse, not a complete restore-authority design",
    }


def materialize_chunk_store(path: Path, rootfs_size: int, chunk_size: int, store_dir: Path) -> dict[str, Any]:
    object_dir = store_dir / "objects" / "sha256"
    object_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[dict[str, Any] | None] = []
    object_bytes = 0
    objects_written = 0
    zero_chunks = 0
    start = time.perf_counter_ns()
    chunk_count = math.ceil(rootfs_size / chunk_size)

    with path.open("rb") as f:
        for chunk_index in range(chunk_count):
            expected_len = chunk_len(rootfs_size, chunk_size, chunk_index)
            data = f.read(expected_len)
            if len(data) != expected_len:
                raise ValueError(f"short rootfs read at chunk {chunk_index}: got {len(data)} expected {expected_len}")
            if data == b"\0" * len(data):
                chunks.append(None)
                zero_chunks += 1
                continue

            digest = hashlib.sha256(data).hexdigest()
            object_path = object_dir / f"{digest}.chunk"
            if not object_path.exists():
                tmp_path = object_path.with_suffix(f".{os.getpid()}.tmp")
                tmp_path.write_bytes(data)
                tmp_path.replace(object_path)
                objects_written += 1
                object_bytes += len(data)
            chunks.append({"digest": digest, "len": len(data)})

    index = {
        "kind": "rootfs-chunk-replay-index-v0",
        "logical_size": rootfs_size,
        "chunk_size": chunk_size,
        "hash_algorithm": "sha256",
        "chunks": chunks,
    }
    index_bytes = json.dumps(index, sort_keys=True, separators=(",", ":")).encode("utf-8")
    (store_dir / "index.json").write_bytes(index_bytes)
    elapsed_us = (time.perf_counter_ns() - start) // 1000
    return {
        "index": index,
        "store_dir": store_dir,
        "object_dir": object_dir,
        "stats": {
            "elapsed_us": elapsed_us,
            "chunk_count": chunk_count,
            "zero_chunks": zero_chunks,
            "nonzero_chunks": chunk_count - zero_chunks,
            "objects_written": objects_written,
            "object_bytes_written": object_bytes,
            "json_index_bytes": len(index_bytes),
            "hash_note": "sha256 used for replay mechanics; runtime rootfs verification is still BLAKE3 today",
        },
    }


def replay_chunk_store(
    index: dict[str, Any],
    object_dir: Path,
    reads: list[tuple[int, int]],
    cached: bool,
) -> dict[str, Any]:
    chunk_size = int(index["chunk_size"])
    chunks = index["chunks"]
    verified_cache: dict[str, bytes] = {}
    read_events = 0
    logical_read_bytes = 0
    chunk_accesses = 0
    unique_chunks_seen: set[int] = set()
    cache_hits = 0
    chunk_misses = 0
    object_opens = 0
    object_bytes_read = 0
    bytes_hashed = 0
    zero_fills = 0
    checksum = 0
    start = time.perf_counter_ns()

    for offset, length in reads:
        read_events += 1
        logical_read_bytes += length
        cursor = 0
        while cursor < length:
            absolute = offset + cursor
            chunk_index = absolute // chunk_size
            chunk_offset = absolute % chunk_size
            entry = chunks[chunk_index]
            chunk_accesses += 1
            unique_chunks_seen.add(chunk_index)

            if entry is None:
                span = min(length - cursor, chunk_size - chunk_offset)
                zero_fills += 1
                checksum ^= span & 0xFF
                cursor += span
                continue

            digest = str(entry["digest"])
            expected_len = int(entry["len"])
            if cached and digest in verified_cache:
                data = verified_cache[digest]
                cache_hits += 1
            else:
                object_path = object_dir / f"{digest}.chunk"
                object_opens += 1
                data = object_path.read_bytes()
                object_bytes_read += len(data)
                if len(data) != expected_len:
                    raise ValueError(f"bad object size for {digest}: got {len(data)} expected {expected_len}")
                actual = hashlib.sha256(data).hexdigest()
                bytes_hashed += len(data)
                if actual != digest:
                    raise ValueError(f"bad object digest for {digest}")
                chunk_misses += 1
                if cached:
                    verified_cache[digest] = data

            span = min(length - cursor, expected_len - chunk_offset)
            if span <= 0:
                raise ValueError(f"invalid trace span at offset={offset} len={length} chunk={chunk_index}")
            checksum ^= data[chunk_offset] if span else 0
            cursor += span

    elapsed_us = (time.perf_counter_ns() - start) // 1000
    return {
        "cached": cached,
        "elapsed_us": elapsed_us,
        "read_events": read_events,
        "logical_read_bytes": logical_read_bytes,
        "chunk_accesses": chunk_accesses,
        "unique_chunks_seen": len(unique_chunks_seen),
        "cache_hits": cache_hits,
        "chunk_misses": chunk_misses,
        "object_opens": object_opens,
        "object_bytes_read": object_bytes_read,
        "bytes_hashed": bytes_hashed,
        "zero_fills": zero_fills,
        "checksum": checksum,
    }


def replay_store_summary(path: Path, rootfs_size: int, events: list[dict[str, Any]], chunk_size: int, replay_dir: Path) -> dict[str, Any]:
    reads = traced_reads(events, rootfs_size)
    materialized = materialize_chunk_store(path, rootfs_size, chunk_size, replay_dir)
    index = materialized["index"]
    object_dir = materialized["object_dir"]
    return {
        "store": materialized["stats"],
        "cached_replay": replay_chunk_store(index, object_dir, reads, True),
        "uncached_replay": replay_chunk_store(index, object_dir, reads, False),
        "note": "uncached replay is the failure mode where a runtime verifies the same chunk again for repeated guest reads",
    }


def summarize_open_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    opens = [event for event in events if event.get("event") == "rootfs_open_verified"]
    elapsed = sorted(int(event["elapsed_ms"]) for event in opens)
    if not elapsed:
        return {"count": 0}
    return {
        "count": len(elapsed),
        "min_ms": elapsed[0],
        "p50_ms": elapsed[len(elapsed) // 2],
        "max_ms": elapsed[-1],
        "all_ms": elapsed,
    }


def main() -> None:
    args = parse_args()
    chunk_sizes = args.chunk_sizes or list(DEFAULT_CHUNK_SIZES)
    rootfs_size = os.stat(args.rootfs).st_size
    events = load_events(args.trace)
    replay_enabled = args.replay_store or args.replay_dir is not None

    summary: dict[str, Any] = {
        "rootfs_path": str(args.rootfs),
        "trace_path": str(args.trace),
        "rootfs_size": rootfs_size,
        "rootfs_open_verified": summarize_open_events(events),
        "proof_sidecar_control": proof_sidecar_control(args.rootfs, rootfs_size),
        "chunk_sizes": [],
    }
    if args.replay_dir is not None:
        args.replay_dir.mkdir(parents=True, exist_ok=True)
        replay_root_context = None
        replay_root = args.replay_dir
    elif replay_enabled:
        replay_root_context = tempfile.TemporaryDirectory(prefix="sporevm-rootfs-chunk-replay-")
        replay_root = Path(replay_root_context.name)
    else:
        replay_root_context = None
        replay_root = None

    try:
        for chunk_size in chunk_sizes:
            chunk_summary: dict[str, Any] = {
                "chunk_size": chunk_size,
                "image": scan_rootfs(args.rootfs, rootfs_size, chunk_size),
                "trace_working_set": traced_working_set(events, rootfs_size, chunk_size),
            }
            if replay_root is not None:
                chunk_summary["cas_replay"] = replay_store_summary(
                    args.rootfs,
                    rootfs_size,
                    events,
                    chunk_size,
                    replay_root / f"{chunk_size}",
                )
            summary["chunk_sizes"].append(chunk_summary)
    finally:
        if replay_root_context is not None:
            replay_root_context.cleanup()

    encoded = json.dumps(summary, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
