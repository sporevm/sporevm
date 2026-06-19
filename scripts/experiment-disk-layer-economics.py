#!/usr/bin/env python3
"""
Estimate writable disk layer economics before building the runtime backend.

This is intentionally an offline experiment. It generates deterministic disk
images with workload-shaped writes, then asks how many content-addressed block
objects a sealed layer would need to carry for different cluster sizes.

The hash algorithm is SHA-256 because it is in Python's standard library. The
choice does not affect byte-count economics; SporeVM can keep BLAKE3 for the
actual artifact contract.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path


KIB = 1024
MIB = 1024 * KIB

DEFAULT_CLUSTER_SIZES = (4 * KIB, 16 * KIB, 64 * KIB, 256 * KIB, 1024 * KIB)


@dataclasses.dataclass(frozen=True)
class Write:
    offset: int
    data: bytes
    content_key: str | None = None


@dataclasses.dataclass(frozen=True)
class Variant:
    name: str
    writes: tuple[Write, ...]


@dataclasses.dataclass(frozen=True)
class Workload:
    name: str
    description: str
    disk_size: int
    variants: tuple[Variant, ...]


@dataclasses.dataclass(frozen=True)
class Measurement:
    workload: str
    cluster_size: int
    variant_count: int
    logical_write_bytes: int
    total_changed_clusters: int
    total_cluster_bytes: int
    unique_cluster_count: int
    unique_cluster_bytes: int
    index_bytes_estimate: int
    file_content_unique_bytes: int

    def as_dict(self) -> dict[str, int | float | str]:
        return {
            "workload": self.workload,
            "cluster_size": self.cluster_size,
            "variant_count": self.variant_count,
            "logical_write_bytes": self.logical_write_bytes,
            "total_changed_clusters": self.total_changed_clusters,
            "total_cluster_bytes": self.total_cluster_bytes,
            "unique_cluster_count": self.unique_cluster_count,
            "unique_cluster_bytes": self.unique_cluster_bytes,
            "index_bytes_estimate": self.index_bytes_estimate,
            "file_content_unique_bytes": self.file_content_unique_bytes,
            "cluster_over_logical": ratio(self.total_cluster_bytes, self.logical_write_bytes),
            "unique_over_logical": ratio(self.unique_cluster_bytes, self.logical_write_bytes),
            "block_over_file_content": ratio_or_none(self.unique_cluster_bytes, self.file_content_unique_bytes),
        }


@dataclasses.dataclass(frozen=True)
class Ext4Workload:
    name: str
    description: str
    image_paths: tuple[Path, ...]
    logical_write_bytes: int
    file_content_unique_bytes: int


def deterministic_bytes(label: str, size: int) -> bytes:
    out = bytearray()
    counter = 0
    prefix = label.encode("utf-8")
    while len(out) < size:
        out.extend(hashlib.sha256(prefix + counter.to_bytes(8, "little")).digest())
        counter += 1
    return bytes(out[:size])


def align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def ratio(numerator: int, denominator: int) -> float:
    if denominator == 0:
        return 0.0
    return numerator / denominator


def ratio_or_none(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return numerator / denominator


def make_package_files(prefix: str, count: int) -> tuple[tuple[str, bytes], ...]:
    sizes = (
        4 * KIB,
        8 * KIB,
        16 * KIB,
        24 * KIB,
        64 * KIB,
        96 * KIB,
        256 * KIB,
        512 * KIB,
    )
    files: list[tuple[str, bytes]] = []
    for index in range(count):
        size = sizes[index % len(sizes)]
        key = f"{prefix}/file-{index:04d}-{size}"
        files.append((key, deterministic_bytes(key, size)))
    return tuple(files)


def content_unique_bytes(entries: Iterable[tuple[str, bytes]]) -> int:
    unique: dict[bytes, int] = {}
    for _, data in entries:
        unique[hashlib.sha256(data).digest()] = len(data)
    return sum(unique.values())


def pack_files(
    files: Iterable[tuple[str, bytes]],
    *,
    start_offset: int,
    jitter_seed: int | None = None,
    shuffle: bool = False,
) -> tuple[Write, ...]:
    rng = random.Random(jitter_seed)
    ordered = list(files)
    if shuffle:
        rng.shuffle(ordered)
    cursor = start_offset
    writes: list[Write] = []
    for key, data in ordered:
        if jitter_seed is None:
            cursor = align_up(cursor, 4 * KIB)
        else:
            cursor = align_up(cursor + rng.randrange(0, 12 * KIB), 4 * KIB)
            cursor += rng.randrange(0, 2 * KIB)
        writes.append(Write(cursor, data, key))
        cursor += len(data)
    return tuple(writes)


def add_metadata_jitter(writes: tuple[Write, ...], *, variant_index: int) -> tuple[Write, ...]:
    jittered = list(writes)
    touched_clusters: set[int] = set()
    for write in writes:
        first = write.offset // (64 * KIB)
        last = (write.offset + len(write.data) - 1) // (64 * KIB)
        touched_clusters.update(range(first, last + 1))
    for cluster in sorted(touched_clusters):
        offset = cluster * 64 * KIB + 256
        data = deterministic_bytes(f"metadata-jitter/{variant_index}/{cluster}", 192)
        jittered.append(Write(offset, data, None))
    return tuple(jittered)


def workload_aligned_package(variant_count: int, disk_size: int) -> Workload:
    common = make_package_files("common-pytorchish", 96)
    variants: list[Variant] = []
    for variant_index in range(variant_count):
        unique = make_package_files(f"variant-{variant_index}", 8)
        writes = pack_files((*common, *unique), start_offset=4 * MIB)
        variants.append(Variant(f"child-{variant_index:03d}", writes))
    return Workload(
        "aligned-package",
        "Same package payloads land at stable offsets; fixed block dedupe should work well.",
        disk_size,
        tuple(variants),
    )


def workload_shifted_package(variant_count: int, disk_size: int) -> Workload:
    common = make_package_files("common-pytorchish", 96)
    variants: list[Variant] = []
    for variant_index in range(variant_count):
        unique = make_package_files(f"variant-{variant_index}", 8)
        start = 4 * MIB + (variant_index * 777) % (64 * KIB)
        writes = pack_files(
            (*common, *unique),
            start_offset=start,
            jitter_seed=9000 + variant_index,
            shuffle=True,
        )
        variants.append(Variant(f"child-{variant_index:03d}", writes))
    return Workload(
        "shifted-package",
        "Same package payloads land at different offsets/order; file-content dedupe should beat fixed blocks.",
        disk_size,
        tuple(variants),
    )


def workload_metadata_jitter(variant_count: int, disk_size: int) -> Workload:
    common = make_package_files("common-pytorchish", 96)
    variants: list[Variant] = []
    for variant_index in range(variant_count):
        unique = make_package_files(f"variant-{variant_index}", 8)
        writes = pack_files((*common, *unique), start_offset=4 * MIB)
        writes = add_metadata_jitter(writes, variant_index=variant_index)
        variants.append(Variant(f"child-{variant_index:03d}", writes))
    return Workload(
        "metadata-jitter",
        "Stable file data with per-variant metadata noise in many clusters.",
        disk_size,
        tuple(variants),
    )


def workload_sqlite_like(variant_count: int, disk_size: int) -> Workload:
    variants: list[Variant] = []
    page_size = 4 * KIB
    db_start = 8 * MIB
    db_pages = 4096
    wal_start = 40 * MIB
    for variant_index in range(variant_count):
        rng = random.Random(12000 + variant_index)
        writes: list[Write] = []
        hot_pages = [rng.randrange(0, db_pages) for _ in range(1200)]
        for write_index, page in enumerate(hot_pages):
            offset = db_start + page * page_size
            data = deterministic_bytes(f"sqlite/{variant_index}/page/{write_index}/{page}", page_size)
            writes.append(Write(offset, data, None))
        wal_cursor = wal_start
        for frame in range(320):
            data = deterministic_bytes(f"sqlite/{variant_index}/wal/{frame}", page_size + 24)
            writes.append(Write(wal_cursor, data, None))
            wal_cursor += len(data)
        variants.append(Variant(f"child-{variant_index:03d}", tuple(writes)))
    return Workload(
        "sqlite-like",
        "Many unique 4KiB page rewrites and WAL appends; tests cluster-size write amplification.",
        disk_size,
        tuple(variants),
    )


def build_image(disk_size: int, writes: Iterable[Write]) -> bytes:
    image = bytearray(disk_size)
    for write in writes:
        end = write.offset + len(write.data)
        if end > disk_size:
            raise ValueError(f"write ends at {end}, beyond disk size {disk_size}")
        image[write.offset:end] = write.data
    return bytes(image)


def measure(workload: Workload, cluster_size: int) -> Measurement:
    zero_clusters: dict[int, bytes] = {}
    unique_clusters: set[bytes] = set()
    total_changed_clusters = 0
    total_cluster_bytes = 0
    logical_write_bytes = 0
    file_content: dict[str, int] = {}

    for variant in workload.variants:
        image = build_image(workload.disk_size, variant.writes)
        logical_write_bytes += sum(len(write.data) for write in variant.writes)
        for write in variant.writes:
            if write.content_key is not None:
                file_content[write.content_key] = len(write.data)
        for offset in range(0, workload.disk_size, cluster_size):
            chunk = image[offset : offset + cluster_size]
            zero = zero_clusters.get(len(chunk))
            if zero is None:
                zero = b"\0" * len(chunk)
                zero_clusters[len(chunk)] = zero
            if chunk == zero:
                continue
            unique_clusters.add(hashlib.sha256(chunk).digest())
            total_changed_clusters += 1
            total_cluster_bytes += len(chunk)

    unique_cluster_bytes = len(unique_clusters) * cluster_size
    index_bytes_estimate = total_changed_clusters * 40 + len(unique_clusters) * 64
    return Measurement(
        workload=workload.name,
        cluster_size=cluster_size,
        variant_count=len(workload.variants),
        logical_write_bytes=logical_write_bytes,
        total_changed_clusters=total_changed_clusters,
        total_cluster_bytes=total_cluster_bytes,
        unique_cluster_count=len(unique_clusters),
        unique_cluster_bytes=unique_cluster_bytes,
        index_bytes_estimate=index_bytes_estimate,
        file_content_unique_bytes=sum(file_content.values()),
    )


def measure_ext4(workload: Ext4Workload, cluster_size: int) -> Measurement:
    unique_clusters: set[bytes] = set()
    total_changed_clusters = 0
    total_cluster_bytes = 0
    zero = b"\0" * cluster_size

    for image_path in workload.image_paths:
        with image_path.open("rb") as image:
            while True:
                chunk = image.read(cluster_size)
                if not chunk:
                    break
                if len(chunk) < cluster_size:
                    chunk = chunk + b"\0" * (cluster_size - len(chunk))
                if chunk == zero:
                    continue
                unique_clusters.add(hashlib.sha256(chunk).digest())
                total_changed_clusters += 1
                total_cluster_bytes += len(chunk)

    unique_cluster_bytes = len(unique_clusters) * cluster_size
    index_bytes_estimate = total_changed_clusters * 40 + len(unique_clusters) * 64
    return Measurement(
        workload=workload.name,
        cluster_size=cluster_size,
        variant_count=len(workload.image_paths),
        logical_write_bytes=workload.logical_write_bytes,
        total_changed_clusters=total_changed_clusters,
        total_cluster_bytes=total_cluster_bytes,
        unique_cluster_count=len(unique_clusters),
        unique_cluster_bytes=unique_cluster_bytes,
        index_bytes_estimate=index_bytes_estimate,
        file_content_unique_bytes=workload.file_content_unique_bytes,
    )


def profile_workloads(profile: str) -> tuple[Workload, ...]:
    if profile == "quick":
        variant_count = 4
        disk_size = 64 * MIB
    else:
        variant_count = 8
        disk_size = 128 * MIB
    return (
        workload_aligned_package(variant_count, disk_size),
        workload_shifted_package(variant_count, disk_size),
        workload_metadata_jitter(variant_count, disk_size),
        workload_sqlite_like(variant_count, disk_size),
    )


def find_tool(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    homebrew = Path("/opt/homebrew/opt/e2fsprogs/sbin") / name
    if homebrew.exists():
        return str(homebrew)
    raise RuntimeError(
        f"{name} not found; install e2fsprogs and put its sbin directory on PATH"
    )


def write_entries(root: Path, entries: Iterable[tuple[str, bytes]]) -> None:
    for rel, data in entries:
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        os.utime(target, (0, 0))


def sqlite_db_bytes(tmp: Path, label: str, rows: int) -> bytes:
    db_path = tmp / f"{label}.sqlite"
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, key TEXT, value BLOB)")
        for index in range(rows):
            conn.execute(
                "INSERT INTO items (key, value) VALUES (?, ?)",
                (
                    f"{label}-{index:06d}",
                    deterministic_bytes(f"{label}/row/{index}", 256),
                ),
            )
        conn.commit()
    finally:
        conn.close()
    return db_path.read_bytes()


def make_ext4_image(mkfs_ext4: str, root: Path, image: Path, disk_size: int) -> None:
    with image.open("wb") as out:
        out.truncate(disk_size)
    command = [
        mkfs_ext4,
        "-q",
        "-F",
        "-O",
        "^has_journal,^metadata_csum,^metadata_csum_seed",
        "-d",
        str(root),
        str(image),
    ]
    env = os.environ.copy()
    env["SOURCE_DATE_EPOCH"] = "0"
    subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)


def ext4_package_entries(
    *,
    common_prefix: str,
    unique_prefix: str,
    variant_index: int,
    shifted: bool,
) -> tuple[tuple[str, bytes], ...]:
    common = make_package_files("common-pytorchish", 80)
    unique = make_package_files(f"variant-{variant_index}", 8)
    entries: list[tuple[str, bytes]] = []
    for index, (key, data) in enumerate(common):
        if shifted:
            rel = f"{common_prefix}/bucket-{(index + variant_index) % 7}/{key}.bin"
        else:
            rel = f"{common_prefix}/{key}.bin"
        entries.append((rel, data))
    for key, data in unique:
        entries.append((f"{unique_prefix}/{key}.bin", data))
    return tuple(entries)


def build_ext4_workload(
    tmp: Path,
    mkfs_ext4: str,
    name: str,
    variant_entries: tuple[tuple[tuple[str, bytes], ...], ...],
    disk_size: int,
) -> Ext4Workload:
    images: list[Path] = []
    logical = 0
    all_entries: list[tuple[str, bytes]] = []
    for variant_index, entries in enumerate(variant_entries):
        root = tmp / name / f"root-{variant_index:03d}"
        root.mkdir(parents=True)
        write_entries(root, entries)
        image = tmp / name / f"image-{variant_index:03d}.ext4"
        make_ext4_image(mkfs_ext4, root, image, disk_size)
        images.append(image)
        logical += sum(len(data) for _, data in entries)
        all_entries.extend(entries)
    return Ext4Workload(
        name=name,
        description="real ext4 image workload",
        image_paths=tuple(images),
        logical_write_bytes=logical,
        file_content_unique_bytes=content_unique_bytes(all_entries),
    )


def build_ext4_workloads(tmp: Path) -> tuple[Ext4Workload, ...]:
    mkfs_ext4 = find_tool("mkfs.ext4")
    variant_count = 4
    disk_size = 96 * MIB

    aligned_entries = tuple(
        ext4_package_entries(
            common_prefix="usr/local/lib/python3.12/site-packages",
            unique_prefix="workspace/variant",
            variant_index=variant_index,
            shifted=False,
        )
        for variant_index in range(variant_count)
    )

    shifted_entries = tuple(
        ext4_package_entries(
            common_prefix="usr/local/lib/python3.12/site-packages",
            unique_prefix=f"workspace/variant-{variant_index}",
            variant_index=variant_index,
            shifted=True,
        )
        for variant_index in range(variant_count)
    )

    jitter_entries: list[tuple[tuple[str, bytes], ...]] = []
    for variant_index in range(variant_count):
        entries = list(
            ext4_package_entries(
                common_prefix="usr/local/lib/python3.12/site-packages",
                unique_prefix="workspace/variant",
                variant_index=variant_index,
                shifted=False,
            )
        )
        for index in range(800):
            entries.append(
                (
                    f"var/lib/dpkg/info/pkg-{index:04d}.list",
                    deterministic_bytes(f"metadata/{variant_index}/{index}", 96),
                )
            )
        jitter_entries.append(tuple(entries))

    sqlite_entries: list[tuple[tuple[str, bytes], ...]] = []
    for variant_index in range(variant_count):
        db = sqlite_db_bytes(tmp, f"db-{variant_index}", 6000)
        sqlite_entries.append((("var/lib/app/app.sqlite", db),))

    return (
        build_ext4_workload(tmp, mkfs_ext4, "ext4-aligned-package", aligned_entries, disk_size),
        build_ext4_workload(tmp, mkfs_ext4, "ext4-shifted-package", shifted_entries, disk_size),
        build_ext4_workload(tmp, mkfs_ext4, "ext4-metadata-jitter", tuple(jitter_entries), disk_size),
        build_ext4_workload(tmp, mkfs_ext4, "ext4-sqlite-final", tuple(sqlite_entries), disk_size),
    )


def mib(value: int) -> float:
    return value / MIB


def format_ratio(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:5.2f}x"


def print_table(measurements: list[Measurement]) -> None:
    header = (
        "workload           cluster  unique-block  total-block   logical   "
        "block/log  block/file  objects"
    )
    print(header)
    print("-" * len(header))
    for item in measurements:
        block_file_ratio = ratio_or_none(item.unique_cluster_bytes, item.file_content_unique_bytes)
        print(
            f"{item.workload:18s}"
            f"{item.cluster_size // KIB:6d}K"
            f"{mib(item.unique_cluster_bytes):12.2f}M"
            f"{mib(item.total_cluster_bytes):12.2f}M"
            f"{mib(item.logical_write_bytes):10.2f}M"
            f"{format_ratio(ratio(item.total_cluster_bytes, item.logical_write_bytes)):>11s}"
            f"{format_ratio(block_file_ratio):>12s}"
            f"{item.unique_cluster_count:9d}"
        )


def summarize(measurements: list[Measurement]) -> None:
    print()
    print("Interpretation")
    print("--------------")
    by_workload: dict[str, list[Measurement]] = {}
    for item in measurements:
        by_workload.setdefault(item.workload, []).append(item)
    for workload, rows in by_workload.items():
        best = min(rows, key=lambda row: row.unique_cluster_bytes)
        smallest_reasonable = min(
            rows,
            key=lambda row: (abs(row.cluster_size - 64 * KIB), row.unique_cluster_bytes),
        )
        print(
            f"- {workload}: lowest unique block bytes at {best.cluster_size // KIB}K "
            f"({mib(best.unique_cluster_bytes):.2f} MiB); 64K-ish point is "
            f"{mib(smallest_reasonable.unique_cluster_bytes):.2f} MiB."
        )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("quick", "full", "ext4"), default="quick")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a text table")
    args = parser.parse_args(argv)

    measurements: list[Measurement] = []
    if args.profile == "ext4":
        with tempfile.TemporaryDirectory(prefix="sporevm-ext4-economics.") as tmp:
            for workload in build_ext4_workloads(Path(tmp)):
                for cluster_size in DEFAULT_CLUSTER_SIZES:
                    measurements.append(measure_ext4(workload, cluster_size))
    else:
        for workload in profile_workloads(args.profile):
            for cluster_size in DEFAULT_CLUSTER_SIZES:
                measurements.append(measure(workload, cluster_size))

    if args.json:
        print(json.dumps([item.as_dict() for item in measurements], indent=2, sort_keys=True))
    else:
        print_table(measurements)
        summarize(measurements)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
