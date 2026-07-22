#!/usr/bin/env python3
"""Contract checks for the image-gateway transport benchmark."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from typing import Any


SCRIPT = Path(__file__).with_name("image-gateway-transport.py")
SPEC = importlib.util.spec_from_file_location("image_gateway_transport", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
transport = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = transport
SPEC.loader.exec_module(transport)


def write_fixture(root: Path, contents: list[bytes], arch: str = "arm64") -> None:
    manifest_digest = "sha256:" + "1" * 64
    base = root / "v1" / "repositories" / "benchmark"
    manifest_base = base / "manifests" / manifest_digest
    objects = []
    for logical_chunk, data in enumerate(contents):
        digest = "blake3:" + hashlib.sha256(data).hexdigest()
        path = manifest_base / "objects" / digest
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        objects.append({"digest": digest, "logical_chunk": logical_chunk})
    rootfs_index = {
        "kind": "spore-disk-index-v1",
        "logical_size": sum(len(data) for data in contents),
        "chunk_size": len(contents[0]),
        "hash_algorithm": "blake3",
        "object_namespace": "rootfs/blake3",
        "chunks": objects,
    }
    controls: dict[Path, Any] = {
        manifest_base / "manifest": {
            "kind": "spore-image-gateway-manifest-v1",
            "image": {
                "digest": "blake3:" + "2" * 64,
                "platform": {"os": "linux", "arch": arch},
                "rootfs_storage": {"logical_size": rootfs_index["logical_size"]},
            },
            "rootfs_index": {
                "digest": "blake3:" + "3" * 64,
                "object_count": len(objects),
                "object_bytes": rootfs_index["logical_size"],
            },
        },
        manifest_base / "config": {"os": "linux", "architecture": arch},
        manifest_base / "rootfs-index": rootfs_index,
        base / "sources" / ("sha256:" + "4" * 64) / "index": {
            "kind": "spore-image-gateway-index-v1",
            "manifests": [],
        },
    }
    for path, value in controls.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(transport.canonical_json(value))


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="image-gateway-transport-test.") as temporary:
        root = Path(temporary)
        fixture = root / "fixture"
        overlap = root / "overlap"
        write_fixture(fixture, [b"a" * 64, b"b" * 64, b"c" * 17])
        write_fixture(overlap, [b"a" * 64, b"z" * 64, b"y" * 17])
        transport.run_benchmark(
            argparse.Namespace(
                archive_compression="gzip",
                batch_size=2,
                fixture=fixture,
                iterations=3,
                output=root / "output",
                overlap_fixture=overlap,
            )
        )
        no_overlap = root / "no-overlap"
        write_fixture(no_overlap, [b"q" * 64, b"r" * 64, b"s" * 17])
        try:
            transport.run_benchmark(
                argparse.Namespace(
                    archive_compression="gzip",
                    batch_size=2,
                    fixture=fixture,
                    iterations=1,
                    output=root / "no-overlap-output",
                    overlap_fixture=no_overlap,
                )
            )
        except transport.BenchmarkError:
            pass
        else:
            raise RuntimeError("benchmark accepted an overlap fixture with no shared objects")
        summary_path = root / "output" / "summary.json"
        summary = transport.parse_object(transport.read_bounded(summary_path), summary_path)
        if summary.get("kind") != "transport-summary":
            raise RuntimeError("summary omitted its evidence kind")
        if summary.get("transport", {}).get("backend") != "local":
            raise RuntimeError("summary omitted its backend placement")
        cases = {(case["mode"], case["cache_state"]): case for case in summary["cases"]}
        if cases[("archive", "cold")]["median_request_count"] != cases[
            ("archive", "partial")
        ]["median_request_count"]:
            raise RuntimeError("archive request count changed with local reuse")
        if cases[("batch", "partial")]["median_response_bytes"] >= cases[
            ("batch", "cold")
        ]["median_response_bytes"]:
            raise RuntimeError("batch did not save bytes for an overlapping cache")
        if cases[("objects", "cold")]["median_data_request_count"] != 3:
            raise RuntimeError("objects mode request accounting is wrong")
        if cases[("batch", "cold")]["median_request_bytes"] <= 0:
            raise RuntimeError("batch request body bytes were not counted")
        if cases[("objects", "cold")]["median_request_bytes"] != 0:
            raise RuntimeError("objects mode recorded a request body")
        rows = [json.loads(line) for line in (root / "output" / "results.jsonl").read_text().splitlines()]
        if any(row.get("kind") != "transport-trial" for row in rows):
            raise RuntimeError("trial omitted its evidence kind")
        first_modes = [row["mode"] for row in rows if row["cache_state"] == "cold"]
        if first_modes != ["objects", "archive", "batch", "archive", "batch", "objects", "batch", "objects", "archive"]:
            raise RuntimeError("trial modes did not rotate by iteration")
        for row in rows:
            phases = row["control_ms"] + row["transfer_ms"] + row["verification_ms"] + row["cache_write_ms"]
            if row["elapsed_ms"] < phases or row["elapsed_ms"] - phases > 20:
                raise RuntimeError("headline elapsed time disagrees with its phases")
        closure = transport.Closure.load(fixture)
        digests = sorted(closure.objects)
        encoded = transport.encode_batch(closure, digests)
        try:
            transport.decode_batch(encoded + b"trailing", digests)
        except transport.BenchmarkError:
            pass
        else:
            raise RuntimeError("batch decoder accepted trailing bytes")
        truncated = encoded[:-1]
        try:
            transport.decode_batch(truncated, digests)
        except transport.BenchmarkError:
            pass
        else:
            raise RuntimeError("batch decoder accepted a truncated object")

        profile_log = root / "profile.log"
        profile_log.write_text(
            "spore rootfs profile: phase=tree_merge_layer layer=0 ms=3 input_bytes=5\n"
            "spore rootfs profile: phase=tree_merge_layer layer=1 ms=7 input_bytes=11\n"
        )
        profile = transport.parse_profile(profile_log)
        if profile.get("tree_merge_layer_count") != 2 or profile.get("tree_merge_layer_ms") != 10:
            raise RuntimeError("repeated layer profile lines were not aggregated")
        if transport.METADATA_RE.search("metadata: /tmp/rootfs.json\n") is None:
            raise RuntimeError("OCI layout import metadata output was not recognized")

        amd64_fixture = root / "amd64-fixture"
        write_fixture(amd64_fixture, [b"a" * 64, b"b" * 17], arch="amd64")
        if transport.Closure.load(amd64_fixture).platform != "linux/amd64":
            raise RuntimeError("benchmark fixture rejected linux/amd64")

        transport.run_benchmark(
            argparse.Namespace(
                archive_compression="none",
                batch_size=2,
                fixture=fixture,
                iterations=1,
                output=root / "uncompressed-output",
                overlap_fixture=overlap,
            )
        )
    print("image-gateway transport benchmark test ok")


if __name__ == "__main__":
    main()
