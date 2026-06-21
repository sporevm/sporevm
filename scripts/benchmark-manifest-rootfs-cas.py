#!/usr/bin/env python3
"""Benchmark fd-backed rootfs restore against manifest-attached rootfs CAS."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time
import uuid


DEFAULT_IMAGE = "docker.io/library/node:22-alpine"
DEFAULT_COMMAND = "/usr/local/bin/node -v"
DEFAULT_PLATFORM = "linux/arm64"


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def monotonic_ms() -> int:
    return time.monotonic_ns() // 1_000_000


def infer_backend() -> str:
    if os.environ.get("SPORE_BACKEND"):
        return os.environ["SPORE_BACKEND"]
    uname = os.uname()
    if uname.sysname == "Darwin" and uname.machine == "arm64":
        return "hvf"
    if uname.sysname == "Linux" and uname.machine in ("aarch64", "arm64"):
        return "kvm"
    return "auto"


def parse_csv_ints(value: str) -> tuple[int, ...]:
    counts: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        count = int(part)
        if count <= 0:
            die("counts must be positive")
        counts.append(count)
    if not counts:
        die("at least one count is required")
    return tuple(counts)


def parse_shell_words(value: str) -> list[str]:
    words = [word for word in value.split(" ") if word]
    if not words:
        die("--command must contain at least one argv element")
    return words


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_command(
    argv: list[str],
    *,
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    timeout_s: int,
) -> tuple[int, int, str | None]:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    started = monotonic_ms()
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            completed = subprocess.run(
                argv,
                stdout=stdout,
                stderr=stderr,
                env=env,
                timeout=timeout_s,
                check=False,
            )
        return completed.returncode, monotonic_ms() - started, None
    except OSError as err:
        return 127, monotonic_ms() - started, str(err)
    except subprocess.TimeoutExpired:
        return 124, monotonic_ms() - started, f"timed out after {timeout_s}s"


def load_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    rows: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line_number, line in enumerate(fh, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                value = json.loads(stripped)
            except json.JSONDecodeError as err:
                die(f"invalid JSONL in {path}:{line_number}: {err}")
            if isinstance(value, dict):
                rows.append(value)
    return rows


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            values[key.strip()] = value.strip()
    return values


def parse_run_events(path: Path) -> dict[str, object]:
    exit_event: dict[str, object] | None = None
    stdout_bytes = 0
    stderr_bytes = 0
    for row in load_jsonl(path):
        event = row.get("event")
        if event == "exit":
            exit_event = row
        elif event == "stdout":
            stdout_bytes += int(row.get("byte_count") or 0)
        elif event == "stderr":
            stderr_bytes += int(row.get("byte_count") or 0)
    timings = exit_event.get("timings", {}) if exit_event else {}
    return {
        "guest_exit_code": exit_event.get("exit_code") if exit_event else None,
        "run_start_ms": timings.get("start_ms") if isinstance(timings, dict) else None,
        "vsock_connect_ms": timings.get("vsock_connect_ms") if isinstance(timings, dict) else None,
        "exec_response_ms": timings.get("exec_response_ms") if isinstance(timings, dict) else None,
        "probe_duration_ms": timings.get("probe_duration_ms") if isinstance(timings, dict) else None,
        "guest_stdout_bytes": stdout_bytes,
        "guest_stderr_bytes": stderr_bytes,
    }


def summarize_trace(path: Path) -> dict[str, object]:
    rootfs_open_ms = None
    rootfs_open_size = None
    index_open_ms = None
    index_bytes = None
    index_chunk_count = None
    read_count = 0
    read_bytes = 0
    read_elapsed_ms = 0
    cas_stats: dict[str, object] = {}

    for row in load_jsonl(path):
        event = row.get("event")
        if event == "rootfs_open_verified":
            rootfs_open_ms = row.get("elapsed_ms")
            rootfs_open_size = row.get("size")
        elif event == "rootfs_cas_index_open":
            index_open_ms = row.get("elapsed_ms")
            index_bytes = row.get("index_bytes")
            index_chunk_count = row.get("chunk_count")
        elif event == "block_source_read":
            read_count += 1
            read_bytes += int(row.get("len") or 0)
            read_elapsed_ms += int(row.get("elapsed_ms") or 0)
        elif event == "rootfs_cas_stats":
            cas_stats = row

    bytes_hashed = int(cas_stats.get("bytes_hashed") or 0)
    verification_elapsed_ms = 0
    if isinstance(rootfs_open_ms, int):
        verification_elapsed_ms += rootfs_open_ms
    if isinstance(index_open_ms, int):
        verification_elapsed_ms += index_open_ms
    verification_elapsed_ms += read_elapsed_ms

    return {
        "rootfs_open_verified_ms": rootfs_open_ms,
        "rootfs_index_open_ms": index_open_ms,
        "rootfs_index_bytes": index_bytes,
        "rootfs_index_chunk_count": index_chunk_count,
        "rootfs_read_count": read_count,
        "rootfs_read_bytes": read_bytes,
        "rootfs_read_elapsed_ms": read_elapsed_ms,
        "cas_chunk_accesses": cas_stats.get("chunk_accesses"),
        "cas_cache_hits": cas_stats.get("cache_hits"),
        "cas_cache_misses": cas_stats.get("cache_misses"),
        "cas_object_opens": cas_stats.get("object_opens"),
        "cas_bytes_hashed": cas_stats.get("bytes_hashed"),
        "cas_zero_fills": cas_stats.get("zero_fills"),
        "rootfs_bytes_verified": rootfs_open_size if rootfs_open_size is not None else bytes_hashed,
        "rootfs_verification_elapsed_ms": verification_elapsed_ms,
    }


def percentile(sorted_values: list[float], pct: float) -> float | None:
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (pct / 100) * (len(sorted_values) - 1)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[int(rank)]
    weight = rank - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight


def summarize_values(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"min": None, "max": None, "mean": None, "median": None, "p95": None, "p99": None}
    sorted_values = sorted(values)
    return {
        "min": sorted_values[0],
        "max": sorted_values[-1],
        "mean": statistics.fmean(sorted_values),
        "median": statistics.median(sorted_values),
        "p95": percentile(sorted_values, 95),
        "p99": percentile(sorted_values, 99),
    }


def summarize_field(rows: list[dict[str, object]], field: str) -> dict[str, float | int | None]:
    values = [float(row[field]) for row in rows if isinstance(row.get(field), (int, float))]
    return summarize_values(values)


class ManifestCasGate:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.root = repo_root()
        self.run_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
        self.output_dir = Path(args.output_dir).resolve()
        self.run_dir = self.output_dir / self.run_id
        self.work_dir = self.run_dir / "work"
        self.log_dir = self.run_dir / "logs"
        self.raw_path = self.run_dir / "results.jsonl"
        self.summary_path = self.run_dir / "summary.json"
        self.spore_bin = Path(args.spore_bin).resolve()
        self.rootfs_cache_dir = Path(args.rootfs_cache_dir).resolve() if args.rootfs_cache_dir else self.run_dir / "rootfs-cache"
        self.bundle_cache_dir = self.run_dir / "bundle-cache"
        self.command = parse_shell_words(args.command)
        self.env = os.environ.copy()
        self.env["SPOREVM_ROOTFS_CACHE_DIR"] = str(self.rootfs_cache_dir)
        self.env["SPOREVM_BUNDLE_CACHE_DIR"] = str(self.bundle_cache_dir)
        self.effective_image = args.image
        self.rows: list[dict[str, object]] = []

    def emit(self, row: dict[str, object]) -> dict[str, object]:
        enriched = {
            "version": 1,
            "run_id": self.run_id,
            "created_at": utc_now(),
            "backend": self.args.backend,
            "requested_image": self.args.image,
            "image": self.effective_image,
            "memory": self.args.memory,
            **row,
        }
        append_jsonl(self.raw_path, enriched)
        self.rows.append(enriched)
        return enriched

    def setup(self) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.rootfs_cache_dir.mkdir(parents=True, exist_ok=True)
        self.bundle_cache_dir.mkdir(parents=True, exist_ok=True)
        if self.args.build:
            self.build()
        if not self.spore_bin.is_file() or not os.access(self.spore_bin, os.X_OK):
            die(f"spore binary not executable: {self.spore_bin}")
        self.resolve_image()
        if self.args.prewarm_rootfs:
            self.prewarm_rootfs()

    def build(self) -> None:
        cmd = ["mise", "run", "build"] if shutil.which("mise") else ["zig", "build"]
        stdout = self.log_dir / "build.stdout"
        stderr = self.log_dir / "build.stderr"
        status, elapsed_ms, error = run_command(cmd, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=600)
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": "setup",
            "mode": "build",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"build failed status={status} stderr={stderr}")

    def resolve_image(self) -> None:
        if "@sha256:" in self.args.image:
            return
        stdout = self.log_dir / "rootfs-resolve.stdout"
        stderr = self.log_dir / "rootfs-resolve.stderr"
        argv = [str(self.spore_bin), "rootfs", "resolve", self.args.image, "--platform", self.args.platform]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        resolved = stdout.read_text(encoding="utf-8", errors="replace").strip() if stdout.exists() else ""
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": "setup",
            "mode": "rootfs_resolve",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "resolved": resolved,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0 or "@sha256:" not in resolved:
            die(f"rootfs resolve failed status={status} stderr={stderr}")
        self.effective_image = resolved

    def prewarm_rootfs(self) -> None:
        stdout = self.log_dir / "rootfs-prewarm.stdout"
        stderr = self.log_dir / "rootfs-prewarm.stderr"
        argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.args.backend,
            "--image",
            self.effective_image,
            "--memory",
            self.args.prewarm_memory,
            "--",
            "/bin/true",
        ]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": "setup",
            "mode": "rootfs_prewarm",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"rootfs prewarm failed status={status} stderr={stderr}")

    def capture_base(self) -> Path:
        base_dir = self.work_dir / "base.spore"
        shutil.rmtree(base_dir, ignore_errors=True)
        stdout = self.log_dir / "base-capture.stdout"
        stderr = self.log_dir / "base-capture.stderr"
        argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.args.backend,
            "--image",
            self.effective_image,
            "--memory",
            self.args.memory,
            "--capture",
            str(base_dir),
            "--",
            "/bin/true",
        ]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        success = status == 0 and (base_dir / "manifest.json").exists()
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": "setup",
            "mode": "base_capture",
            "success": success,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "spore_dir": str(base_dir),
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if not success:
            die(f"base spore capture failed status={status} stderr={stderr}")
        return base_dir

    def rootfs_digest(self, spore_dir: Path) -> str:
        manifest = json.loads((spore_dir / "manifest.json").read_text(encoding="utf-8"))
        rootfs = manifest.get("rootfs") or {}
        artifact = rootfs.get("artifact") if isinstance(rootfs, dict) else None
        digest = artifact.get("digest") if isinstance(artifact, dict) else None
        if not isinstance(digest, str) or not digest.startswith("blake3:"):
            die(f"spore manifest missing rootfs artifact digest: {spore_dir}")
        return digest

    def preload_and_attach(self, base_dir: Path, digest: str) -> dict[str, str]:
        stdout = self.log_dir / "cas-preload.stdout"
        stderr = self.log_dir / "cas-preload.stderr"
        argv = [
            str(self.spore_bin),
            "rootfs",
            "cas-preload",
            digest,
            "--chunk-size",
            str(self.args.chunk_size),
            "--attach-spore",
            str(base_dir),
        ]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.preload_timeout_s)
        values = read_key_values(stdout)
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": "manifest_cas",
            "mode": "cas_preload_attach",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "chunk_size": self.args.chunk_size,
            "preload": values,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"cas-preload attach failed status={status} stderr={stderr}")
        return values

    def fork_children(self, base_dir: Path, variant: str, count: int) -> Path:
        out_dir = self.work_dir / variant / f"count-{count}" / "children"
        shutil.rmtree(out_dir, ignore_errors=True)
        out_dir.parent.mkdir(parents=True, exist_ok=True)
        stdout = self.log_dir / variant / f"count-{count}" / "fork.stdout"
        stderr = self.log_dir / variant / f"count-{count}" / "fork.stderr"
        argv = [str(self.spore_bin), "fork", str(base_dir), "--count", str(count), "--out", str(out_dir)]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        success = status == 0 and out_dir.exists()
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": variant,
            "mode": "fork",
            "count": count,
            "success": success,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "fork_ms_per_child": elapsed_ms / count,
            "error": error,
            "children_dir": str(out_dir),
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if not success:
            die(f"fork failed for {variant} count={count} status={status} stderr={stderr}")
        return out_dir

    def run_child(self, variant: str, count: int, children_dir: Path, iteration: int) -> dict[str, object]:
        child_name = f"{iteration:06d}"
        child_dir = children_dir / child_name
        prefix = self.log_dir / variant / f"count-{count}" / child_name
        stdout = prefix.with_suffix(".events.jsonl")
        stderr = prefix.with_suffix(".stderr")
        trace = prefix.with_suffix(".rootfs-trace.jsonl")
        env = self.env.copy()
        env["SPOREVM_ROOTFS_TRACE"] = str(trace)
        argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.args.backend,
            "--events=jsonl",
            "--from",
            str(child_dir),
            "--",
            *self.command,
        ]
        status, tti_ms, error = run_command(argv, env=env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        events = parse_run_events(stdout)
        trace_summary = summarize_trace(trace)
        guest_exit = events.get("guest_exit_code")
        success = status == 0 and guest_exit == 0
        return {
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": variant,
            "mode": "run_child",
            "count": count,
            "iteration": iteration,
            "child": child_name,
            "success": success,
            "status": status,
            "error": error,
            "tti_ms": tti_ms,
            **events,
            **trace_summary,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
            "trace_path": str(trace),
        }

    def run_children(self, variant: str, count: int, children_dir: Path) -> None:
        started = monotonic_ms()
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.concurrency) as pool:
            futures = [pool.submit(self.run_child, variant, count, children_dir, iteration) for iteration in range(count)]
            for future in concurrent.futures.as_completed(futures):
                row = self.emit(future.result())
                status = "ok" if row.get("success") else "failed"
                print(
                    f"{variant} count={count} iteration={row.get('iteration')} {status} "
                    f"tti_ms={row.get('tti_ms')}",
                    file=sys.stderr,
                )
        rows = [
            row for row in self.rows
            if row.get("benchmark") == "manifest_rootfs_cas_gate"
            and row.get("variant") == variant
            and row.get("mode") == "run_child"
            and row.get("count") == count
        ]
        self.emit({
            "benchmark": "manifest_rootfs_cas_gate",
            "variant": variant,
            "mode": "batch",
            "count": count,
            "success": all(bool(row.get("success")) for row in rows) if rows else False,
            "success_count": sum(1 for row in rows if row.get("success")),
            "wall_clock_ms": monotonic_ms() - started,
        })

    def run_variant_counts(self, base_dir: Path, variant: str, counts: tuple[int, ...]) -> None:
        for count in counts:
            children_dir = self.fork_children(base_dir, variant, count)
            self.run_children(variant, count, children_dir)

    def summary(self, preload_values: dict[str, str]) -> dict[str, object]:
        results: list[dict[str, object]] = []
        run_rows = [row for row in self.rows if row.get("mode") == "run_child"]
        groups: dict[tuple[str, int], list[dict[str, object]]] = {}
        for row in run_rows:
            count = row.get("count")
            if isinstance(count, int):
                groups.setdefault((str(row.get("variant")), count), []).append(row)

        fields = (
            "tti_ms",
            "rootfs_open_verified_ms",
            "rootfs_index_open_ms",
            "rootfs_read_count",
            "rootfs_read_bytes",
            "rootfs_read_elapsed_ms",
            "cas_chunk_accesses",
            "cas_cache_hits",
            "cas_cache_misses",
            "cas_object_opens",
            "cas_bytes_hashed",
            "rootfs_bytes_verified",
            "rootfs_verification_elapsed_ms",
            "vsock_connect_ms",
            "exec_response_ms",
            "probe_duration_ms",
        )
        for (variant, count), rows in sorted(groups.items()):
            success_rows = [row for row in rows if row.get("success")]
            batch = next(
                (
                    row for row in self.rows
                    if row.get("variant") == variant and row.get("mode") == "batch" and row.get("count") == count
                ),
                {},
            )
            results.append({
                "variant": variant,
                "count": count,
                "success_count": len(success_rows),
                "success_rate": len(success_rows) / len(rows) if rows else 0,
                "wall_clock_ms": batch.get("wall_clock_ms"),
                "metrics": {field: summarize_field(success_rows, field) for field in fields},
            })

        comparisons = []
        counts = sorted({count for _, count in groups})
        for count in counts:
            baseline = [row for row in groups.get(("baseline", count), []) if row.get("success")]
            cas = [row for row in groups.get(("manifest_cas", count), []) if row.get("success")]
            if not baseline or not cas:
                continue
            baseline_tti = summarize_field(baseline, "tti_ms")
            cas_tti = summarize_field(cas, "tti_ms")
            baseline_verify = summarize_field(baseline, "rootfs_verification_elapsed_ms")
            cas_verify = summarize_field(cas, "rootfs_verification_elapsed_ms")
            comparisons.append({
                "count": count,
                "cold_first_child_overhead_ms": float(cas[0]["tti_ms"]) - float(baseline[0]["tti_ms"]),
                "median_tti_delta_ms": (
                    float(cas_tti["median"]) - float(baseline_tti["median"])
                    if cas_tti["median"] is not None and baseline_tti["median"] is not None
                    else None
                ),
                "p95_tti_delta_ms": (
                    float(cas_tti["p95"]) - float(baseline_tti["p95"])
                    if cas_tti["p95"] is not None and baseline_tti["p95"] is not None
                    else None
                ),
                "median_rootfs_verification_delta_ms": (
                    float(cas_verify["median"]) - float(baseline_verify["median"])
                    if cas_verify["median"] is not None and baseline_verify["median"] is not None
                    else None
                ),
            })

        return {
            "version": 1,
            "run_id": self.run_id,
            "generated_at": utc_now(),
            "config": {
                "backend": self.args.backend,
                "image": self.effective_image,
                "requested_image": self.args.image,
                "platform": self.args.platform,
                "memory": self.args.memory,
                "command": self.command,
                "chunk_size": self.args.chunk_size,
                "baseline_counts": self.args.baseline_counts,
                "cas_counts": self.args.cas_counts,
                "concurrency": self.args.concurrency,
                "timeout_s": self.args.timeout_s,
                "rootfs_cache_dir": str(self.rootfs_cache_dir),
                "spore_bin": str(self.spore_bin),
            },
            "preload": preload_values,
            "results": results,
            "comparisons": comparisons,
            "raw_results": str(self.raw_path),
        }

    def run(self) -> None:
        self.setup()
        base_dir = self.capture_base()
        digest = self.rootfs_digest(base_dir)
        self.run_variant_counts(base_dir, "baseline", self.args.baseline_counts)
        preload_values = self.preload_and_attach(base_dir, digest)
        self.run_variant_counts(base_dir, "manifest_cas", self.args.cas_counts)
        summary = self.summary(preload_values)
        write_json(self.summary_path, summary)
        write_json(self.output_dir / "latest-manifest-rootfs-cas-summary.json", summary)
        print(f"manifest rootfs CAS benchmark ok: results={self.raw_path} summary={self.summary_path}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default="zig-cache/manifest-rootfs-cas-benchmarks")
    parser.add_argument("--rootfs-cache-dir", default="")
    parser.add_argument("--spore-bin", default=str(repo_root() / "zig-out/bin/spore"))
    parser.add_argument("--backend", default=infer_backend(), choices=("auto", "hvf", "kvm"))
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--platform", default=DEFAULT_PLATFORM)
    parser.add_argument("--memory", default="auto")
    parser.add_argument("--command", default=DEFAULT_COMMAND)
    parser.add_argument("--chunk-size", type=int, default=64 * 1024)
    parser.add_argument("--counts", default="10,100", help="Default comma-separated fan-out counts")
    parser.add_argument("--baseline-counts", help="Comma-separated fd-backed fan-out counts")
    parser.add_argument("--cas-counts", help="Comma-separated manifest CAS fan-out counts")
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--timeout-s", type=int, default=300)
    parser.add_argument("--preload-timeout-s", type=int, default=900)
    parser.add_argument("--prewarm-memory", default="512mb")
    parser.add_argument("--no-prewarm-rootfs", dest="prewarm_rootfs", action="store_false")
    parser.add_argument("--no-build", dest="build", action="store_false")
    parser.set_defaults(build=True, prewarm_rootfs=True)
    args = parser.parse_args(argv)
    counts = parse_csv_ints(args.counts)
    args.baseline_counts = parse_csv_ints(args.baseline_counts) if args.baseline_counts else counts
    args.cas_counts = parse_csv_ints(args.cas_counts) if args.cas_counts else counts
    if args.chunk_size <= 0 or args.chunk_size % 512 != 0:
        die("--chunk-size must be a positive multiple of 512")
    if args.concurrency <= 0:
        die("--concurrency must be positive")
    return args


def main(argv: list[str]) -> int:
    ManifestCasGate(parse_args(argv)).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
