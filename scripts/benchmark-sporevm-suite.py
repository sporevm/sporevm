#!/usr/bin/env python3
"""Run repeatable SporeVM benchmarks and emit comparable JSON output."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


SUITE_VERSION = "1.1"
DEFAULT_IMAGE = "docker.io/library/node:22-alpine"
DEFAULT_COMMAND = "/usr/local/bin/node -v"
DEFAULT_PLATFORM = "linux/arm64"
RESTORE_METRICS_RE = re.compile(r"(?:kvm|hvf) restore metrics: (?P<fields>.+)")
EXEC_PROBE_TIMING_RE = re.compile(r"run exec probe timing: (?P<fields>.+)")

PHASE_METRIC_FIELDS = (
    "rootfs_open_verified_ms",
    "rootfs_verification_elapsed_ms",
    "backend_map_ram_ms",
    "backend_memory_ms",
    "backend_state_ms",
    "backend_pre_run_ms",
    "backend_restore_ms",
    "vsock_connect_ms",
    "exec_response_ms",
    "first_output_ms",
    "exec_probe_attach_ms",
    "exec_request_delivered_ms",
    "exec_guest_timing_ms",
)

PROFILES = {
    "smoke": {
        "iterations": 1,
        "concurrency": 2,
        "stagger_delay_ms": 200,
        "modes": ("sequential",),
        "benchmarks": ("cold_tti", "warm_spore_tti", "distribution_tti", "writable_rootfs"),
        "writable_rootfs_iterations": 1,
        "writable_rootfs_workloads": ("package",),
        "timeout_s": 180,
    },
    "ci": {
        "iterations": 3,
        "concurrency": 4,
        "stagger_delay_ms": 200,
        "modes": ("sequential", "burst"),
        "benchmarks": ("cold_tti", "warm_spore_tti"),
        "writable_rootfs_iterations": 1,
        "writable_rootfs_workloads": ("package",),
        "timeout_s": 180,
    },
    "comparison": {
        "iterations": 5,
        "concurrency": 8,
        "stagger_delay_ms": 200,
        "modes": ("sequential", "burst"),
        "benchmarks": ("cold_tti", "warm_spore_tti", "distribution_tti", "writable_rootfs"),
        "writable_rootfs_iterations": 1,
        "writable_rootfs_workloads": ("sqlite", "package"),
        "timeout_s": 240,
    },
    "full": {
        "iterations": 100,
        "concurrency": 100,
        "stagger_delay_ms": 200,
        "modes": ("sequential", "staggered", "burst"),
        "benchmarks": ("cold_tti", "warm_spore_tti", "distribution_tti", "writable_rootfs"),
        "writable_rootfs_iterations": 3,
        "writable_rootfs_workloads": ("sqlite", "package"),
        "timeout_s": 300,
    },
}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def monotonic_ms() -> int:
    return time.monotonic_ns() // 1_000_000


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def infer_backend() -> str:
    if os.environ.get("SPORE_BACKEND"):
        return os.environ["SPORE_BACKEND"]
    uname = os.uname()
    if uname.sysname == "Darwin" and uname.machine == "arm64":
        return "hvf"
    if uname.sysname == "Linux" and uname.machine in ("aarch64", "arm64"):
        return "kvm"
    return "auto"


def parse_shell_words(value: str) -> list[str]:
    # Keep command parsing intentionally small: the default and documented
    # examples are whitespace-delimited argv, not shell programs.
    words = [word for word in value.split(" ") if word]
    if not words:
        die("--command must contain at least one argv element")
    return words


def json_dump(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


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


def first_output_line(path: Path) -> str:
    if not path.exists():
        return ""
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line:
                return line[:512]
    return ""


def parse_int_field(value: object) -> int | None:
    if value is None:
        return None
    try:
        return int(str(value))
    except ValueError:
        return None


def parse_key_value_tail(value: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in value.split():
        if "=" in part:
            key, raw = part.split("=", 1)
            fields[key] = raw
    return fields


def parse_run_stderr_metrics(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    metrics: dict[str, object] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("event") == "rootfs_open_verified":
            elapsed_ms = parse_int_field(event.get("elapsed_ms"))
            metrics["rootfs_open_verified_ms"] = elapsed_ms
            metrics["rootfs_verification_elapsed_ms"] = elapsed_ms
            metrics["rootfs_bytes_verified"] = parse_int_field(event.get("size"))
    for match in RESTORE_METRICS_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        metrics["backend_restore_mode"] = fields.get("mode")
        metrics["backend_map_ram_ms"] = parse_int_field(fields.get("map_ram_ms"))
        metrics["backend_memory_ms"] = parse_int_field(fields.get("memory_ms"))
        metrics["backend_state_ms"] = parse_int_field(fields.get("state_ms"))
        metrics["backend_pre_run_ms"] = parse_int_field(fields.get("pre_run_ms"))
        metrics["backend_restore_ms"] = metrics["backend_pre_run_ms"]
    for match in EXEC_PROBE_TIMING_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        metrics["exec_probe_attach_ms"] = parse_int_field(fields.get("attach_ms"))
        metrics["vsock_connect_ms"] = parse_int_field(fields.get("connect_ms"))
        metrics["exec_request_delivered_ms"] = parse_int_field(fields.get("request_delivered_ms"))
        metrics["first_output_ms"] = parse_int_field(fields.get("first_output_ms"))
        metrics["exec_guest_timing_ms"] = parse_int_field(fields.get("guest_timing_ms"))
        metrics["exec_response_ms"] = parse_int_field(fields.get("response_ms"))
    return {key: value for key, value in metrics.items() if value is not None}


def file_allocated_bytes(path: Path) -> int | None:
    try:
        return path.stat().st_blocks * 512
    except (AttributeError, OSError):
        return None


def directory_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total


def memory_economics(spore_dir: Path) -> dict[str, object]:
    manifest_path = spore_dir / "manifest.json"
    if not manifest_path.exists():
        return {"spore_dir": str(spore_dir), "manifest_present": False}
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    memory = manifest.get("memory", {})
    chunks = memory.get("chunks") or []
    nonzero_chunks = sum(1 for chunk in chunks if chunk is not None)
    backing = memory.get("backing")
    backing_logical_bytes = None
    backing_allocated_bytes = None
    if isinstance(backing, dict) and backing.get("path"):
        backing_path = spore_dir / str(backing["path"])
        if backing_path.exists():
            backing_logical_bytes = backing_path.stat().st_size
            backing_allocated_bytes = file_allocated_bytes(backing_path)
    rootfs = manifest.get("rootfs") or {}
    artifact = rootfs.get("artifact") if isinstance(rootfs, dict) else None
    rootfs_bytes = artifact.get("size") if isinstance(artifact, dict) else None
    return {
        "spore_dir": str(spore_dir),
        "manifest_present": True,
        "configured_ram_bytes": manifest.get("platform", {}).get("ram_size"),
        "chunk_size": memory.get("chunk_size"),
        "chunks_total": len(chunks),
        "chunks_nonzero": nonzero_chunks,
        "chunks_zero_elided": len(chunks) - nonzero_chunks,
        "chunk_store_bytes": directory_size(spore_dir / "chunks"),
        "backing_logical_bytes": backing_logical_bytes,
        "backing_allocated_bytes": backing_allocated_bytes,
        "rootfs_artifact_bytes": rootfs_bytes,
    }


class BenchmarkRunner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.root = repo_root()
        self.run_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
        self.output_dir = Path(args.output_dir).resolve()
        self.run_dir = self.output_dir / self.run_id
        scratch_dir = Path(args.scratch_dir).resolve() if args.scratch_dir else None
        self.scratch_run_dir = scratch_dir / self.run_id if scratch_dir else self.run_dir
        self.log_dir = self.run_dir / "logs"
        self.work_dir = self.scratch_run_dir / "work"
        self.raw_path = self.run_dir / "results.jsonl"
        self.summary_path = self.run_dir / "summary.json"
        self.rootfs_cache_dir = Path(args.rootfs_cache_dir).resolve() if args.rootfs_cache_dir else self.scratch_run_dir / "rootfs-cache"
        self.bundle_cache_dir = self.scratch_run_dir / "bundle-cache"
        self.spore_bin = Path(args.spore_bin).resolve()
        self.backend = args.backend
        self.command = parse_shell_words(args.command)
        self.rows: list[dict[str, object]] = []
        self.batch_rows: list[dict[str, object]] = []
        self.env = os.environ.copy()
        self.env["SPOREVM_ROOTFS_CACHE_DIR"] = str(self.rootfs_cache_dir)
        self.env["SPOREVM_BUNDLE_CACHE_DIR"] = str(self.bundle_cache_dir)
        self.effective_image = args.image

    def setup(self) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.rootfs_cache_dir.mkdir(parents=True, exist_ok=True)
        self.bundle_cache_dir.mkdir(parents=True, exist_ok=True)
        if self.args.build:
            self.build()
        if not self.spore_bin.is_file() or not os.access(self.spore_bin, os.X_OK):
            die(f"spore binary not executable: {self.spore_bin}")
        self.resolve_image()
        if self.args.prewarm_rootfs:
            self.prewarm_rootfs()
        json_dump(self.run_dir / "config.json", self.config_json())

    def build(self) -> None:
        cmd = ["mise", "run", "build"] if shutil.which("mise") else ["zig", "build"]
        stdout = self.log_dir / "build.stdout"
        stderr = self.log_dir / "build.stderr"
        rc, elapsed_ms, error = run_command(cmd, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=600)
        if rc != 0:
            die(f"build failed rc={rc} elapsed_ms={elapsed_ms} error={error or ''} stderr={stderr}")

    def resolve_image(self) -> None:
        if "@sha256:" in self.args.image:
            self.effective_image = self.args.image
            return
        argv = [str(self.spore_bin), "rootfs", "resolve", self.args.image, "--platform", self.args.platform]
        stdout = self.log_dir / "rootfs-resolve.stdout"
        stderr = self.log_dir / "rootfs-resolve.stderr"
        rc, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        if rc != 0:
            die(f"rootfs resolve failed rc={rc} elapsed_ms={elapsed_ms} error={error or ''} stderr={stderr}")
        resolved = stdout.read_text(encoding="utf-8").strip()
        if "@sha256:" not in resolved:
            die(f"rootfs resolve did not return a digest-pinned image ref: {resolved}")
        self.effective_image = resolved
        self.emit({
            "benchmark": "rootfs_resolve",
            "mode": "setup",
            "success": True,
            "status": rc,
            "elapsed_ms": elapsed_ms,
            "requested_image": self.args.image,
            "image": self.effective_image,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })

    def prewarm_rootfs(self) -> None:
        stdout = self.log_dir / "rootfs-prewarm.stdout"
        stderr = self.log_dir / "rootfs-prewarm.stderr"
        argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.backend,
            "--image",
            self.effective_image,
            "--memory",
            self.args.prewarm_memory,
            "--",
            "/bin/true",
        ]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        self.emit({
            "benchmark": "rootfs_prewarm",
            "mode": "setup",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"rootfs prewarm failed rc={status} elapsed_ms={elapsed_ms} error={error or ''} stderr={stderr}")

    def config_json(self) -> dict[str, object]:
        return {
            "version": SUITE_VERSION,
            "run_id": self.run_id,
            "created_at": utc_now(),
            "profile": self.args.profile,
            "benchmarks": self.args.benchmarks,
            "modes": self.args.modes,
            "iterations": self.args.iterations,
            "concurrency": self.args.concurrency,
            "stagger_delay_ms": self.args.stagger_delay_ms,
            "backend": self.backend,
            "memory": self.args.memory,
            "requested_image": self.args.image,
            "image": self.effective_image,
            "platform": self.args.platform,
            "command": self.command,
            "timeout_s": self.args.timeout_s,
            "writable_rootfs_iterations": self.args.writable_rootfs_iterations,
            "writable_rootfs_workloads": self.args.writable_rootfs_workloads,
            "writable_rootfs_memory_mib": self.args.writable_rootfs_memory_mib,
            "prewarm_rootfs": self.args.prewarm_rootfs,
            "prewarm_memory": self.args.prewarm_memory,
            "spore_bin": str(self.spore_bin),
            "output_dir": str(self.run_dir),
            "scratch_dir": str(self.scratch_run_dir),
            "rootfs_cache_dir": str(self.rootfs_cache_dir),
            "bundle_cache_dir": str(self.bundle_cache_dir),
        }

    def emit(self, row: dict[str, object]) -> dict[str, object]:
        enriched = {
            "version": SUITE_VERSION,
            "run_id": self.run_id,
            "created_at": utc_now(),
            "backend": self.backend,
            "memory": self.args.memory,
            "requested_image": self.args.image,
            "image": self.effective_image,
            **row,
        }
        append_jsonl(self.raw_path, enriched)
        self.rows.append(enriched)
        return enriched

    def run(self) -> None:
        self.setup()
        if "cold_tti" in self.args.benchmarks:
            for mode in self.args.modes:
                self.run_cold_tti(mode)
        base_dir: Path | None = None
        if "warm_spore_tti" in self.args.benchmarks or "distribution_tti" in self.args.benchmarks:
            base_dir = self.prepare_base_spore()
            self.emit({"benchmark": "memory_economics", "mode": "base_spore", "success": True, **memory_economics(base_dir)})
        if base_dir is not None and "warm_spore_tti" in self.args.benchmarks:
            for mode in self.args.modes:
                self.run_warm_spore_tti(mode, base_dir)
        if base_dir is not None and "distribution_tti" in self.args.benchmarks:
            distribution_modes = self.args.modes if self.args.include_distribution_concurrency else ("sequential",)
            for mode in distribution_modes:
                self.run_distribution_tti(mode, base_dir)
        if "writable_rootfs" in self.args.benchmarks:
            self.run_writable_rootfs()
        self.copy_rootfs_cache_metadata()
        summary = self.summary()
        json_dump(self.summary_path, summary)
        latest_path = self.output_dir / "latest-summary.json"
        json_dump(latest_path, summary)
        print(f"benchmark suite ok: results={self.raw_path} summary={self.summary_path}")

    def copy_rootfs_cache_metadata(self) -> None:
        output_cache_dir = self.run_dir / "rootfs-cache"
        if self.rootfs_cache_dir == output_cache_dir or not self.rootfs_cache_dir.exists():
            return
        output_cache_dir.mkdir(parents=True, exist_ok=True)
        for metadata_path in self.rootfs_cache_dir.glob("*.json"):
            shutil.copy2(metadata_path, output_cache_dir / metadata_path.name)

    def run_cold_tti(self, mode: str) -> None:
        count = self.count_for_mode(mode)

        def worker(iteration: int, launch_offset_ms: int) -> dict[str, object]:
            prefix = self.log_dir / "cold_tti" / mode / f"{iteration:06d}"
            stdout = prefix.with_suffix(".stdout")
            stderr = prefix.with_suffix(".stderr")
            argv = [
                str(self.spore_bin),
                "--debug",
                "run",
                "--backend",
                self.backend,
                "--image",
                self.effective_image,
                "--memory",
                self.args.memory,
                "--",
                *self.command,
            ]
            status, tti_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
            success = status == 0
            return {
                "benchmark": "cold_tti",
                "mode": mode,
                "iteration": iteration,
                "launch_offset_ms": launch_offset_ms,
                "tti_ms": tti_ms,
                "success": success,
                "status": status,
                "error": error,
                "stdout_first_line": first_output_line(stdout),
                "stdout_path": str(stdout),
                "stderr_path": str(stderr),
                **parse_run_stderr_metrics(stderr),
            }

        self.run_batch("cold_tti", mode, count, worker)

    def prepare_base_spore(self) -> Path:
        base_dir = self.work_dir / "base.spore"
        shutil.rmtree(base_dir, ignore_errors=True)
        stdout = self.log_dir / "base-capture.stdout"
        stderr = self.log_dir / "base-capture.stderr"
        argv = [
            str(self.spore_bin),
            "--debug",
            "run",
            "--backend",
            self.backend,
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
            "benchmark": "warm_spore_prepare",
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
            die(f"base spore capture failed status={status} stdout={stdout} stderr={stderr}")
        return base_dir

    def fork_children(self, base_dir: Path, benchmark: str, mode: str, count: int) -> Path:
        out_dir = self.work_dir / benchmark / mode / "children"
        shutil.rmtree(out_dir, ignore_errors=True)
        out_dir.parent.mkdir(parents=True, exist_ok=True)
        stdout = self.log_dir / benchmark / mode / "fork.stdout"
        stderr = self.log_dir / benchmark / mode / "fork.stderr"
        argv = [str(self.spore_bin), "fork", str(base_dir), "--count", str(count), "--out", str(out_dir)]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        success = status == 0 and out_dir.exists()
        self.emit({
            "benchmark": benchmark,
            "mode": f"{mode}_fork",
            "success": success,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "fork_count": count,
            "fork_ms_per_child": elapsed_ms / count if count else None,
            "error": error,
            "children_dir": str(out_dir),
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if not success:
            die(f"fork failed for {benchmark}/{mode} status={status} stdout={stdout} stderr={stderr}")
        return out_dir

    def run_warm_spore_tti(self, mode: str, base_dir: Path) -> None:
        count = self.count_for_mode(mode)
        children_dir = self.fork_children(base_dir, "warm_spore_tti", mode, count)

        def worker(iteration: int, launch_offset_ms: int) -> dict[str, object]:
            child_name = f"{iteration:06d}"
            child_dir = children_dir / child_name
            prefix = self.log_dir / "warm_spore_tti" / mode / child_name
            stdout = prefix.with_suffix(".stdout")
            stderr = prefix.with_suffix(".stderr")
            argv = [
                str(self.spore_bin),
                "--debug",
                "run",
                "--backend",
                self.backend,
                "--from",
                str(child_dir),
                "--",
                *self.command,
            ]
            status, tti_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
            success = status == 0
            return {
                "benchmark": "warm_spore_tti",
                "mode": mode,
                "iteration": iteration,
                "child": child_name,
                "launch_offset_ms": launch_offset_ms,
                "tti_ms": tti_ms,
                "success": success,
                "status": status,
                "error": error,
                "stdout_first_line": first_output_line(stdout),
                "stdout_path": str(stdout),
                "stderr_path": str(stderr),
                **parse_run_stderr_metrics(stderr),
            }

        self.run_batch("warm_spore_tti", mode, count, worker)

    def run_distribution_tti(self, mode: str, base_dir: Path) -> None:
        count = self.count_for_mode(mode)
        children_dir = self.fork_children(base_dir, "distribution_tti", mode, count)
        bundle_dir = self.work_dir / "distribution_tti" / mode / "bundle"
        shutil.rmtree(bundle_dir, ignore_errors=True)
        bundle_dir.parent.mkdir(parents=True, exist_ok=True)
        pack_stdout = self.log_dir / "distribution_tti" / mode / "pack.stdout"
        pack_stderr = self.log_dir / "distribution_tti" / mode / "pack.stderr"
        pack_argv = [
            str(self.spore_bin),
            "pack",
            str(base_dir),
            "--children",
            str(children_dir),
            "--out",
            str(bundle_dir),
        ]
        pack_status, pack_ms, pack_error = run_command(pack_argv, env=self.env, stdout_path=pack_stdout, stderr_path=pack_stderr, timeout_s=self.args.timeout_s)
        pack_result = parse_json_file(pack_stdout)
        pack_success = pack_status == 0 and bundle_dir.exists()
        self.emit({
            "benchmark": "distribution_tti",
            "mode": f"{mode}_pack",
            "success": pack_success,
            "status": pack_status,
            "elapsed_ms": pack_ms,
            "error": pack_error,
            "bundle_dir": str(bundle_dir),
            "bundle_bytes": directory_size(bundle_dir),
            "pack_result": pack_result,
            "stdout_path": str(pack_stdout),
            "stderr_path": str(pack_stderr),
        })
        if not pack_success:
            die(f"pack failed for distribution/{mode} status={pack_status} stdout={pack_stdout} stderr={pack_stderr}")
        source = f"file://{bundle_dir}"

        def worker(iteration: int, launch_offset_ms: int) -> dict[str, object]:
            child_name = f"{iteration:06d}"
            pulled_dir = self.work_dir / "distribution_tti" / mode / "pulled" / child_name
            shutil.rmtree(pulled_dir, ignore_errors=True)
            pulled_dir.parent.mkdir(parents=True, exist_ok=True)
            pull_prefix = self.log_dir / "distribution_tti" / mode / f"pull-{child_name}"
            pull_stdout = pull_prefix.with_suffix(".stdout")
            pull_stderr = pull_prefix.with_suffix(".stderr")
            pull_argv = [
                str(self.spore_bin),
                "pull",
                source,
                "--child",
                str(iteration),
                "--out",
                str(pulled_dir),
            ]
            pull_status, pull_ms, pull_error = run_command(pull_argv, env=self.env, stdout_path=pull_stdout, stderr_path=pull_stderr, timeout_s=self.args.timeout_s)
            pull_result = parse_json_file(pull_stdout)
            if pull_status != 0:
                return {
                    "benchmark": "distribution_tti",
                    "mode": mode,
                    "iteration": iteration,
                    "child": child_name,
                    "launch_offset_ms": launch_offset_ms,
                    "tti_ms": pull_ms,
                    "pull_ms": pull_ms,
                    "resume_exec_ms": None,
                    "success": False,
                    "status": pull_status,
                    "error": pull_error,
                    "pull_result": pull_result,
                    "stdout_path": str(pull_stdout),
                    "stderr_path": str(pull_stderr),
                }
            run_prefix = self.log_dir / "distribution_tti" / mode / f"run-{child_name}"
            run_stdout = run_prefix.with_suffix(".stdout")
            run_stderr = run_prefix.with_suffix(".stderr")
            run_argv = [
                str(self.spore_bin),
                "--debug",
                "run",
                "--backend",
                self.backend,
                "--from",
                str(pulled_dir),
                "--",
                *self.command,
            ]
            run_status, run_ms, run_error = run_command(run_argv, env=self.env, stdout_path=run_stdout, stderr_path=run_stderr, timeout_s=self.args.timeout_s)
            success = run_status == 0
            return {
                "benchmark": "distribution_tti",
                "mode": mode,
                "iteration": iteration,
                "child": child_name,
                "launch_offset_ms": launch_offset_ms,
                "tti_ms": pull_ms + run_ms,
                "pull_ms": pull_ms,
                "resume_exec_ms": run_ms,
                "success": success,
                "status": run_status,
                "error": run_error,
                "pull_result": pull_result,
                "stdout_first_line": first_output_line(run_stdout),
                "stdout_path": str(run_stdout),
                "stderr_path": str(run_stderr),
                "pull_stdout_path": str(pull_stdout),
                "pull_stderr_path": str(pull_stderr),
                **parse_run_stderr_metrics(run_stderr),
            }

        self.run_batch("distribution_tti", mode, count, worker)

    def run_writable_rootfs(self) -> None:
        raw_output = self.work_dir / "writable_rootfs" / "results.jsonl"
        raw_output.parent.mkdir(parents=True, exist_ok=True)
        stdout = self.log_dir / "writable_rootfs" / "script.stdout"
        stderr = self.log_dir / "writable_rootfs" / "script.stderr"
        workload = writable_workload_arg(self.args.writable_rootfs_workloads)
        argv = [
            str(self.root / "scripts/benchmark-writable-rootfs.sh"),
            "--backend",
            self.backend,
            "--platform",
            self.args.platform,
            "--workload",
            workload,
            "--iterations",
            str(self.args.writable_rootfs_iterations),
            "--memory-mib",
            str(self.args.writable_rootfs_memory_mib),
            "--timeout-ms",
            str(self.args.timeout_s * 1000),
            "--output",
            str(raw_output),
            "--spore-bin",
            str(self.spore_bin),
            "--no-build",
        ]
        status, elapsed_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s * 12)
        raw_rows = load_jsonl(raw_output)
        self.emit({
            "benchmark": "writable_rootfs",
            "mode": "script",
            "success": status == 0,
            "status": status,
            "elapsed_ms": elapsed_ms,
            "error": error,
            "workload": workload,
            "iterations": self.args.writable_rootfs_iterations,
            "raw_output": str(raw_output),
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        for row in raw_rows:
            workload_name = str(row.get("workload", "unknown"))
            writable_mode = str(row.get("mode", "unknown"))
            converted = {
                "benchmark": "writable_rootfs",
                "mode": f"{workload_name}:{writable_mode}",
                "iteration": row.get("iteration"),
                "tti_ms": row.get("duration_ms"),
                "success": row.get("status") == 0,
                "status": row.get("status"),
                "writable_rootfs_workload": workload_name,
                "writable_rootfs_mode": writable_mode,
                "source_duration_ms": row.get("duration_ms"),
                "source_spore_dir": row.get("spore_dir"),
                "source_stdout": row.get("stdout"),
                "source_stderr": row.get("stderr"),
                "source_row": row,
                "source_jsonl": str(raw_output),
            }
            self.emit(converted)
        self.emit_writable_rootfs_batches(raw_rows)
        if status != 0:
            die(f"writable rootfs benchmark failed status={status} stdout={stdout} stderr={stderr}")

    def emit_writable_rootfs_batches(self, raw_rows: list[dict[str, object]]) -> None:
        groups: dict[tuple[str, str], list[dict[str, object]]] = {}
        for row in raw_rows:
            key = (str(row.get("workload", "unknown")), str(row.get("mode", "unknown")))
            groups.setdefault(key, []).append(row)
        for (workload_name, writable_mode), rows in groups.items():
            self.emit({
                "benchmark": "writable_rootfs",
                "mode": f"{workload_name}:{writable_mode}_batch",
                "success": all(row.get("status") == 0 for row in rows),
                "count": len(rows),
            })

    def count_for_mode(self, mode: str) -> int:
        if mode == "sequential":
            return self.args.iterations
        if mode in ("staggered", "burst"):
            return self.args.concurrency
        die(f"unknown benchmark mode: {mode}")

    def run_batch(self, benchmark: str, mode: str, count: int, worker) -> None:
        max_workers = 1 if mode == "sequential" else count
        delay_ms = self.args.stagger_delay_ms if mode == "staggered" else 0
        batch_start = monotonic_ms()
        futures: list[concurrent.futures.Future[dict[str, object]]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            for iteration in range(count):
                launch_offset_ms = monotonic_ms() - batch_start
                futures.append(pool.submit(self.run_one_timed, worker, iteration, launch_offset_ms, batch_start))
                if delay_ms:
                    time.sleep(delay_ms / 1000)
            for future in concurrent.futures.as_completed(futures):
                row = self.emit(future.result())
                self.batch_rows.append(row)
                status = "ok" if row.get("success") else "failed"
                print(
                    f"{benchmark} {mode} iteration={row.get('iteration')} {status} "
                    f"tti_ms={row.get('tti_ms')}",
                    file=sys.stderr,
                )
        batch_rows = [
            row for row in self.rows
            if row.get("benchmark") == benchmark and row.get("mode") == mode and isinstance(row.get("iteration"), int)
        ]
        wall_clock_ms = monotonic_ms() - batch_start
        time_to_first_ready_ms = min((row.get("ended_at_ms") for row in batch_rows if row.get("success")), default=None)
        self.emit({
            "benchmark": benchmark,
            "mode": f"{mode}_batch",
            "success": all(bool(row.get("success")) for row in batch_rows) if batch_rows else False,
            "count": count,
            "wall_clock_ms": wall_clock_ms,
            "time_to_first_ready_ms": time_to_first_ready_ms,
        })

    def run_one_timed(self, worker, iteration: int, launch_offset_ms: int, batch_start: int) -> dict[str, object]:
        started_at_ms = monotonic_ms() - batch_start
        row = worker(iteration, launch_offset_ms)
        row["started_at_ms"] = started_at_ms
        row["ended_at_ms"] = monotonic_ms() - batch_start
        return row

    def summary(self) -> dict[str, object]:
        groups: dict[tuple[str, str], list[dict[str, object]]] = {}
        for row in self.rows:
            if not isinstance(row.get("tti_ms"), (int, float)):
                continue
            key = (str(row.get("benchmark")), str(row.get("mode")))
            groups.setdefault(key, []).append(row)
        results = []
        for (benchmark, mode), rows in sorted(groups.items()):
            success_rows = [row for row in rows if row.get("success")]
            values = [float(row["tti_ms"]) for row in success_rows]
            batch = next(
                (
                    row for row in self.rows
                    if row.get("benchmark") == benchmark and row.get("mode") == f"{mode}_batch"
                ),
                {},
            )
            result = {
                "benchmark": benchmark,
                "mode": mode,
                "count": len(rows),
                "success_count": len(success_rows),
                "success_rate": len(success_rows) / len(rows) if rows else 0,
                "tti_ms": summarize_values(values),
                "composite_score": composite_score(values, len(success_rows) / len(rows) if rows else 0),
                "wall_clock_ms": batch.get("wall_clock_ms"),
                "time_to_first_ready_ms": batch.get("time_to_first_ready_ms"),
            }
            phase_metrics = {}
            for field in PHASE_METRIC_FIELDS:
                summary = summarize_field(success_rows, field)
                if summary is not None:
                    phase_metrics[field] = summary
            if phase_metrics:
                result["phase_metrics"] = phase_metrics
            results.append(result)
        return {
            "version": SUITE_VERSION,
            "run_id": self.run_id,
            "generated_at": utc_now(),
            "config": self.config_json(),
            "results": results,
            "raw_results": str(self.raw_path),
        }


def parse_json_file(path: Path) -> object | None:
    if not path.exists() or path.stat().st_size == 0:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def load_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    rows: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8") as fh:
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
            else:
                die(f"expected JSON object in {path}:{line_number}")
    return rows


def summarize_field(rows: list[dict[str, object]], field: str) -> dict[str, float | int | None] | None:
    values = [float(row[field]) for row in rows if isinstance(row.get(field), (int, float))]
    return summarize_values(values) if values else None


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


def trim_for_score(values: list[float]) -> list[float]:
    if len(values) < 20:
        return values
    sorted_values = sorted(values)
    trim = max(1, math.floor(len(sorted_values) * 0.05))
    return sorted_values[trim:-trim]


def summarize_values(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "min": None,
            "max": None,
            "mean": None,
            "median": None,
            "p95": None,
            "p99": None,
        }
    sorted_values = sorted(values)
    return {
        "min": sorted_values[0],
        "max": sorted_values[-1],
        "mean": statistics.fmean(sorted_values),
        "median": statistics.median(sorted_values),
        "p95": percentile(sorted_values, 95),
        "p99": percentile(sorted_values, 99),
    }


def metric_score(value: float | None) -> float:
    if value is None:
        return 0.0
    return max(0.0, 100.0 * (1.0 - value / 10_000.0))


def composite_score(values: list[float], success_rate: float) -> float:
    scored_values = trim_for_score(values)
    summary = summarize_values(scored_values)
    timing = (
        metric_score(summary["median"]) * 0.60
        + metric_score(summary["p95"]) * 0.25
        + metric_score(summary["p99"]) * 0.15
    )
    return timing * success_rate


def parse_csv(value: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in value.split(",") if part.strip())


def writable_workload_arg(workloads: tuple[str, ...]) -> str:
    wanted = set(workloads)
    if wanted == {"sqlite", "package"}:
        return "all"
    if len(wanted) == 1:
        item = next(iter(wanted))
        if item == "package":
            return "package"
        if item == "sqlite":
            return "sqlite"
    die("--writable-rootfs-workloads must be sqlite, package, or sqlite,package")


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        stderr = Path(tmp) / "run.stderr"
        stderr.write_text(
            "\n".join([
                '{"event":"rootfs_open_verified","digest":"abc","size":4096,"elapsed_ms":7}',
                "kvm restore metrics: mode=local_backing ram_mib=512 chunks=4 nonzero_chunks=2 manifest_ms=1 map_ram_ms=2 memory_ms=3 state_ms=4 pre_run_ms=10",
                "run exec probe timing: attach_ms=1 connect_request_delivered_ms=2 connect_ms=3 request_delivered_ms=4 first_output_ms=5 guest_timing_ms=6 response_ms=8",
            ]) + "\n",
            encoding="utf-8",
        )
        metrics = parse_run_stderr_metrics(stderr)
        assert metrics["rootfs_open_verified_ms"] == 7
        assert metrics["rootfs_bytes_verified"] == 4096
        assert metrics["backend_restore_mode"] == "local_backing"
        assert metrics["backend_restore_ms"] == 10
        assert metrics["vsock_connect_ms"] == 3
        assert metrics["exec_response_ms"] == 8
        assert summarize_field([metrics], "exec_response_ms")["median"] == 8.0
    print("self-test ok")


def apply_profile_defaults(args: argparse.Namespace) -> None:
    profile = PROFILES[args.profile]
    if args.iterations is None:
        args.iterations = profile["iterations"]
    if args.concurrency is None:
        args.concurrency = profile["concurrency"]
    if args.stagger_delay_ms is None:
        args.stagger_delay_ms = profile["stagger_delay_ms"]
    if args.timeout_s is None:
        args.timeout_s = profile["timeout_s"]
    if args.writable_rootfs_iterations is None:
        args.writable_rootfs_iterations = profile["writable_rootfs_iterations"]
    if args.writable_rootfs_workloads is None:
        args.writable_rootfs_workloads = profile["writable_rootfs_workloads"]
    else:
        args.writable_rootfs_workloads = parse_csv(args.writable_rootfs_workloads)
    if args.modes is None:
        args.modes = profile["modes"]
    else:
        args.modes = parse_csv(args.modes)
    if args.benchmarks is None:
        args.benchmarks = profile["benchmarks"]
    else:
        args.benchmarks = parse_csv(args.benchmarks)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="ci")
    parser.add_argument("--benchmarks", help="Comma-separated subset: cold_tti,warm_spore_tti,distribution_tti,writable_rootfs")
    parser.add_argument("--modes", help="Comma-separated subset: sequential,staggered,burst")
    parser.add_argument("--iterations", type=int, help="Sequential iterations")
    parser.add_argument("--concurrency", type=int, help="Staggered/burst concurrency")
    parser.add_argument("--stagger-delay-ms", type=int, help="Delay between staggered launches")
    parser.add_argument("--include-distribution-concurrency", action="store_true", help="Run distribution TTI for every selected mode, not just sequential")
    parser.add_argument("--output-dir", default="zig-cache/sporevm-benchmarks")
    parser.add_argument("--scratch-dir", default="", help="Directory for large benchmark work/cache; durable output stays under --output-dir")
    parser.add_argument("--rootfs-cache-dir", default="")
    parser.add_argument("--spore-bin", default=str(repo_root() / "zig-out/bin/spore"))
    parser.add_argument("--backend", default=infer_backend(), choices=("auto", "hvf", "kvm"))
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--platform", default=DEFAULT_PLATFORM)
    parser.add_argument("--memory", default="auto")
    parser.add_argument("--command", default=DEFAULT_COMMAND)
    parser.add_argument("--timeout-s", type=int)
    parser.add_argument("--writable-rootfs-iterations", type=int, help="Writable-rootfs iterations per workload")
    parser.add_argument("--writable-rootfs-workloads", help="Comma-separated subset: sqlite,package")
    parser.add_argument("--writable-rootfs-memory-mib", type=int, default=1024)
    parser.add_argument("--no-prewarm-rootfs", dest="prewarm_rootfs", action="store_false")
    parser.add_argument("--prewarm-memory", default="512mb")
    parser.add_argument("--no-build", dest="build", action="store_false")
    parser.add_argument("--self-test", action="store_true")
    parser.set_defaults(build=True, prewarm_rootfs=True)
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    apply_profile_defaults(args)
    for mode in args.modes:
        if mode not in ("sequential", "staggered", "burst"):
            die(f"unknown mode: {mode}")
    for benchmark in args.benchmarks:
        if benchmark not in ("cold_tti", "warm_spore_tti", "distribution_tti", "writable_rootfs"):
            die(f"unknown benchmark: {benchmark}")
    if args.iterations <= 0:
        die("--iterations must be positive")
    if args.concurrency <= 0:
        die("--concurrency must be positive")
    if args.stagger_delay_ms < 0:
        die("--stagger-delay-ms must not be negative")
    if args.writable_rootfs_iterations <= 0:
        die("--writable-rootfs-iterations must be positive")
    if args.writable_rootfs_memory_mib <= 0:
        die("--writable-rootfs-memory-mib must be positive")
    for workload in args.writable_rootfs_workloads:
        if workload not in ("sqlite", "package"):
            die(f"unknown writable rootfs workload: {workload}")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
    else:
        runner = BenchmarkRunner(args)
        runner.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
