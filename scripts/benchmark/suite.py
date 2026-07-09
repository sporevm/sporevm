#!/usr/bin/env python3
"""Run repeatable SporeVM benchmarks and emit comparable JSON output."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid


SUITE_VERSION = "1.4"
DEFAULT_IMAGE = "docker.io/library/node:22-alpine"
DEFAULT_COMMAND = "/usr/local/bin/node -v"
DEFAULT_PLATFORM = "linux/arm64"
DEFAULT_SYNTHETIC_ROOTFS_REF = "local/sporevm-benchmark-synthetic:nightly"
DEFAULT_SYNTHETIC_ROOTFS_FILE_COUNT = 16_384
DEFAULT_SYNTHETIC_ROOTFS_FILE_SIZE = 256
DEFAULT_SYNTHETIC_ROOTFS_DIR_COUNT = 4_096
DEFAULT_SYNTHETIC_ROOTFS_SYMLINK_COUNT = 1_024
DEFAULT_SYNTHETIC_ROOTFS_HARDLINK_COUNT = 1_024
DEFAULT_SYNTHETIC_ROOTFS_DEPTH = 4
SYNTHETIC_ROOTFS_SEED = 0x5A17_0F57
EAGER_ROOTFS_ENV = "SPOREVM_ROOTFS_EAGER_MATERIALIZE_FOR_BENCHMARK"
RESTORE_METRICS_RE = re.compile(r"(?:kvm|hvf) restore metrics: (?P<fields>.+)")
EXEC_PROBE_TIMING_RE = re.compile(r"run exec probe timing: (?P<fields>.+)")
BACKEND_TIMING_RE = re.compile(r"run backend timing: (?P<fields>.+)")
GUEST_TIMING_RE = re.compile(r"vsock host stream guest timing: timing (?P<fields>.+)")
KVM_PROBE_COMPLETION_RE = re.compile(r"kvm probe completion timing: (?P<fields>.+)")
ROOTFS_PROFILE_RE = re.compile(r"spore rootfs profile: phase=(?P<phase>\S+) ms=(?P<ms>\d+)(?P<tail>.*)")
HISTORY_RESET_RE = re.compile(r"(?im)^\s*spore-benchmark-reset:\s*(?P<targets>[^\n]+)")

PHASE_METRIC_FIELDS = (
    "rootfs_open_verified_ms",
    "rootfs_verification_elapsed_ms",
    "backend_map_ram_ms",
    "backend_memory_ms",
    "backend_state_ms",
    "backend_pre_run_ms",
    "backend_restore_ms",
    "backend_run_ms",
    "backend_tail_ms",
    "vsock_connect_ms",
    "exec_response_ms",
    "first_output_ms",
    "exec_probe_attach_ms",
    "exec_connect_request_delivery_ms",
    "exec_connect_ack_ms",
    "exec_request_delivered_ms",
    "exec_request_delivery_ms",
    "exec_guest_timing_ms",
    "guest_listen_ms",
    "guest_accept_ms",
    "guest_decode_ms",
    "guest_spawn_ms",
    "guest_exit_ms",
    "guest_now_ms",
    "guest_accept_delay_ms",
    "guest_decode_delay_ms",
    "guest_spawn_delay_ms",
    "guest_exit_delay_ms",
    "kvm_probe_complete_observed_ms",
    "kvm_pending_exit_completion_ms",
    "kvm_probe_return_ms",
)

IMAGE_SETUP_BENCHMARKS = {"cold_tti", "warm_spore_tti", "distribution_tti", "lazy_rootfs_tti"}

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
    "nightly": {
        "iterations": 5,
        "concurrency": 8,
        "stagger_delay_ms": 200,
        "modes": ("sequential",),
        "benchmarks": ("cold_tti", "cold_import", "warm_spore_tti", "distribution_tti", "writable_rootfs"),
        "writable_rootfs_iterations": 1,
        "writable_rootfs_workloads": ("package",),
        "timeout_s": 300,
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
    return Path(__file__).resolve().parents[2]


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
    try:
        words = shlex.split(value)
    except ValueError as err:
        die(f"--command parse failed: {err}")
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


def parse_ms_field(value: object) -> int | None:
    parsed = parse_int_field(value)
    if parsed is None or parsed < 0:
        return None
    return parsed


def delta_ms(after: object, before: object) -> int | None:
    after_ms = parse_ms_field(after)
    before_ms = parse_ms_field(before)
    if after_ms is None or before_ms is None or after_ms < before_ms:
        return None
    return after_ms - before_ms


def parse_key_value_tail(value: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in value.split():
        if "=" in part:
            key, raw = part.split("=", 1)
            fields[key] = raw
    return fields


def metric_component(value: str) -> str:
    normalized = []
    for char in value:
        if char.isalnum():
            normalized.append(char.lower())
        else:
            normalized.append("_")
    return re.sub(r"_+", "_", "".join(normalized)).strip("_")


def parse_rootfs_profile_text(text: str) -> dict[str, object]:
    metrics: dict[str, object] = {}
    for match in ROOTFS_PROFILE_RE.finditer(text):
        phase = metric_component(match.group("phase"))
        prefix = f"rootfs_profile_{phase}"
        metrics[f"{prefix}_ms"] = int(match.group("ms"))
        for key, raw in parse_key_value_tail(match.group("tail")).items():
            parsed = parse_int_field(raw)
            if parsed is not None:
                metrics[f"{prefix}_{metric_component(key)}"] = parsed
    return metrics


def parse_rootfs_profile_metrics(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    return parse_rootfs_profile_text(path.read_text(encoding="utf-8", errors="replace"))


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
        # "rootfs_open" is the current trace event; "rootfs_open_verified" is
        # accepted for older logs. The metric keys keep the historical names
        # so trend series stay continuous across the trust-at-open change.
        if isinstance(event, dict) and event.get("event") in ("rootfs_open", "rootfs_open_verified"):
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
        metrics["exec_connect_request_delivery_ms"] = delta_ms(
            fields.get("connect_request_delivered_ms"),
            fields.get("attach_ms"),
        )
        metrics["exec_connect_ack_ms"] = delta_ms(
            fields.get("connect_ms"),
            fields.get("connect_request_delivered_ms"),
        )
        metrics["exec_request_delivery_ms"] = delta_ms(
            fields.get("request_delivered_ms"),
            fields.get("connect_ms"),
        )
    for match in BACKEND_TIMING_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        metrics["backend_run_ms"] = parse_int_field(fields.get("elapsed_ms"))
        metrics["backend_tail_ms"] = parse_int_field(fields.get("tail_ms"))
    for match in GUEST_TIMING_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        metrics["guest_listen_ms"] = parse_ms_field(fields.get("listen"))
        metrics["guest_accept_ms"] = parse_ms_field(fields.get("accept"))
        metrics["guest_decode_ms"] = parse_ms_field(fields.get("decode"))
        metrics["guest_spawn_ms"] = parse_ms_field(fields.get("spawn"))
        metrics["guest_exit_ms"] = parse_ms_field(fields.get("exit"))
        metrics["guest_now_ms"] = parse_ms_field(fields.get("now"))
        metrics["guest_accept_delay_ms"] = delta_ms(fields.get("accept"), fields.get("listen"))
        metrics["guest_decode_delay_ms"] = delta_ms(fields.get("decode"), fields.get("accept"))
        metrics["guest_spawn_delay_ms"] = delta_ms(fields.get("spawn"), fields.get("decode"))
        metrics["guest_exit_delay_ms"] = delta_ms(fields.get("exit"), fields.get("spawn"))
    for match in KVM_PROBE_COMPLETION_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        metrics["kvm_probe_complete_observed_ms"] = parse_ms_field(fields.get("observed_ms"))
        metrics["kvm_pending_exit_completion_ms"] = parse_ms_field(fields.get("pending_completion_ms"))
        metrics["kvm_probe_return_ms"] = parse_ms_field(fields.get("return_ms"))
    return {key: value for key, value in metrics.items() if value is not None}


def parse_rootfs_base_mode(path: Path) -> str | None:
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    if "runtime disk rootfs base: lazy chunk index" in text:
        return "lazy"
    if "runtime disk rootfs base: flat artifact" in text:
        return "flat"
    return None


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


def rootfs_digest_cache_path(cache_root: Path, digest: str) -> Path:
    prefix = "blake3:"
    if not digest.startswith(prefix):
        die(f"unsupported rootfs digest for cache path: {digest}")
    hex_digest = digest[len(prefix):]
    if len(hex_digest) != 64 or any(c not in "0123456789abcdef" for c in hex_digest):
        die(f"invalid rootfs digest for cache path: {digest}")
    return cache_root / "by-digest" / "blake3" / f"{hex_digest}.ext4"


def parse_rootfs_import_stdout(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    fields: dict[str, object] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = metric_component(key)
        value = value.strip()
        if key and value:
            fields[f"rootfs_import_{key}"] = value
            if key == "rootfs_identity":
                fields["rootfs_import_index_digest"] = value
    return fields


def deterministic_payload(index: int, size: int) -> bytes:
    seed = f"sporevm synthetic rootfs fixture seed={SYNTHETIC_ROOTFS_SEED:x} file={index:06d}\n".encode("utf-8")
    digest = hashlib.blake2s(seed, digest_size=32).hexdigest().encode("ascii")
    chunk = seed + digest + b"\n"
    return (chunk * ((size // len(chunk)) + 1))[:size]


def tar_info(
    name: str,
    *,
    size: int = 0,
    mode: int = 0o644,
    kind: bytes = tarfile.REGTYPE,
    linkname: str = "",
) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    info.type = kind
    info.linkname = linkname
    return info


def synthetic_leaf_dir(index: int, depth: int) -> str:
    depth = max(1, min(depth, 4))
    parts = [
        f"tenant-{index // 1024:04d}",
        f"repo-{(index // 128) % 8:02d}",
        f"pkg-{(index // 16) % 8:02d}",
        f"dir-{index % 16:02d}-{index:06d}",
    ]
    return "/".join(parts[-depth:])


def parent_directories(path: str) -> list[str]:
    parts = path.split("/")
    return ["/".join(parts[:index]) for index in range(1, len(parts) + 1)]


def synthetic_rootfs_directories(dir_count: int, depth: int) -> list[str]:
    root = "var/lib/sporevm-benchmark/tree"
    dirs: set[str] = {
        "bin",
        "etc",
        "usr",
        "usr/bin",
        "var",
        "var/lib",
        "var/lib/sporevm-benchmark",
        root,
        "var/lib/sporevm-benchmark/links",
        "var/lib/sporevm-benchmark/links/hardlinks",
        "var/lib/sporevm-benchmark/links/symlinks",
    }
    for index in range(dir_count):
        leaf = f"{root}/{synthetic_leaf_dir(index, depth)}"
        dirs.update(parent_directories(leaf))
    return sorted(dirs, key=lambda item: (item.count("/"), item))


def synthetic_file_path(index: int, dir_count: int, depth: int) -> str:
    leaf_index = index % max(dir_count, 1)
    leaf = synthetic_leaf_dir(leaf_index, depth)
    return f"var/lib/sporevm-benchmark/tree/{leaf}/payload-{index:06d}.dat"


def deterministic_target_index(index: int, file_count: int) -> int:
    return (index * 7919 + SYNTHETIC_ROOTFS_SEED) % file_count


def write_synthetic_rootfs_tar(
    path: Path,
    *,
    file_count: int,
    file_size: int,
    dir_count: int,
    symlink_count: int,
    hardlink_count: int,
    depth: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for directory in synthetic_rootfs_directories(dir_count, depth):
            tar.addfile(tar_info(directory, mode=0o755, kind=tarfile.DIRTYPE))
        files = {
            "etc/os-release": b'NAME="SporeVM benchmark fixture"\nID=sporevm-benchmark\n',
            "bin/benchmark-fixture": b"#!/bin/sh\nprintf 'sporevm synthetic fixture\\n'\n",
        }
        for name, data in files.items():
            tar.addfile(tar_info(name, size=len(data), mode=0o755 if name.startswith("bin/") else 0o644), io.BytesIO(data))
        for index in range(file_count):
            data = deterministic_payload(index, file_size)
            name = synthetic_file_path(index, dir_count, depth)
            tar.addfile(tar_info(name, size=len(data)), io.BytesIO(data))
        for index in range(min(hardlink_count, file_count)):
            target = synthetic_file_path(deterministic_target_index(index, file_count), dir_count, depth)
            name = f"var/lib/sporevm-benchmark/links/hardlinks/payload-hardlink-{index:06d}.dat"
            tar.addfile(tar_info(name, mode=0o644, kind=tarfile.LNKTYPE, linkname=target))
        for index in range(min(symlink_count, file_count)):
            target = synthetic_file_path(deterministic_target_index(index + hardlink_count, file_count), dir_count, depth)
            name = f"var/lib/sporevm-benchmark/links/symlinks/payload-symlink-{index:06d}.dat"
            tar.addfile(tar_info(name, mode=0o777, kind=tarfile.SYMTYPE, linkname=f"/{target}"))


def load_benchmark_expectations(root: Path) -> dict[str, object]:
    path = root / "benchmarks" / "expectations.json"
    if not path.exists():
        return {"version": 1, "metrics": {}}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        die(f"invalid benchmark expectations JSON {path}: {err}")
    if not isinstance(value, dict):
        die(f"benchmark expectations must be a JSON object: {path}")
    return value


def benchmark_history_reset() -> dict[str, object] | None:
    raw = os.environ.get("SPOREVM_BENCHMARK_RESET", "").strip()
    source = "SPOREVM_BENCHMARK_RESET"
    if not raw:
        message = os.environ.get("BUILDKITE_MESSAGE", "")
        match = HISTORY_RESET_RE.search(message)
        if match:
            raw = match.group("targets").strip()
            source = "BUILDKITE_MESSAGE"
    if not raw:
        return None
    targets = [part.strip() for part in re.split(r"[, ]+", raw) if part.strip()]
    if not targets:
        targets = ["all"]
    return {"source": source, "raw": raw, "targets": targets}


def default_host_id() -> str:
    for key in ("SPOREVM_BENCHMARK_HOST_ID", "BUILDKITE_AGENT_NAME"):
        value = os.environ.get(key, "").strip()
        if value:
            return value
    return socket.gethostname()


def memory_economics(spore_dir: Path) -> dict[str, object]:
    manifest_path = spore_dir / "manifest.json"
    if not manifest_path.exists():
        return {"spore_dir": str(spore_dir), "manifest_present": False}
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    memory = manifest.get("memory", {})
    chunks = memory.get("chunks") or []
    zero_chunks = memory.get("zero_chunks") or []
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
        "chunks_total": len(chunks) + len(zero_chunks),
        "chunks_nonzero": len(chunks),
        "chunks_zero_elided": len(zero_chunks),
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
        self.env.pop(EAGER_ROOTFS_ENV, None)
        self.env["SPOREVM_ROOTFS_CACHE_DIR"] = str(self.rootfs_cache_dir)
        self.env["SPOREVM_BUNDLE_CACHE_DIR"] = str(self.bundle_cache_dir)
        self.effective_image = args.image
        self.expectations = load_benchmark_expectations(self.root)
        self.history_reset = benchmark_history_reset()

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
        if self.needs_image_setup():
            self.resolve_image()
        if self.needs_image_setup() and self.args.prewarm_rootfs:
            self.prewarm_rootfs()
        json_dump(self.run_dir / "config.json", self.config_json())

    def needs_image_setup(self) -> bool:
        return any(benchmark in IMAGE_SETUP_BENCHMARKS for benchmark in self.args.benchmarks)

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
            if self.args.allow_image_resolve_fallback:
                self.effective_image = self.args.image
                self.emit({
                    "benchmark": "rootfs_resolve",
                    "mode": "setup",
                    "success": False,
                    "status": rc,
                    "elapsed_ms": elapsed_ms,
                    "requested_image": self.args.image,
                    "image": self.effective_image,
                    "error": error,
                    "stdout_path": str(stdout),
                    "stderr_path": str(stderr),
                })
                return
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
            "host_id": self.args.host_id,
            "writable_rootfs_iterations": self.args.writable_rootfs_iterations,
            "writable_rootfs_workloads": self.args.writable_rootfs_workloads,
            "writable_rootfs_memory_mib": self.args.writable_rootfs_memory_mib,
            "synthetic_rootfs_ref": self.args.synthetic_rootfs_ref,
            "synthetic_rootfs_file_count": self.args.synthetic_rootfs_file_count,
            "synthetic_rootfs_file_size": self.args.synthetic_rootfs_file_size,
            "synthetic_rootfs_dir_count": self.args.synthetic_rootfs_dir_count,
            "synthetic_rootfs_symlink_count": self.args.synthetic_rootfs_symlink_count,
            "synthetic_rootfs_hardlink_count": self.args.synthetic_rootfs_hardlink_count,
            "synthetic_rootfs_depth": self.args.synthetic_rootfs_depth,
            "synthetic_rootfs_seed": SYNTHETIC_ROOTFS_SEED,
            "prewarm_rootfs": self.args.prewarm_rootfs,
            "prewarm_memory": self.args.prewarm_memory,
            "spore_bin": str(self.spore_bin),
            "spore_version": self.spore_version(),
            "output_dir": str(self.run_dir),
            "scratch_dir": str(self.scratch_run_dir),
            "rootfs_cache_dir": str(self.rootfs_cache_dir),
            "bundle_cache_dir": str(self.bundle_cache_dir),
            "benchmark_expectations": self.expectations,
            "benchmark_history_reset": self.history_reset,
        }

    def spore_version(self) -> str | None:
        try:
            out = subprocess.run([str(self.spore_bin), "version"], capture_output=True, text=True, timeout=10)
            return out.stdout.strip() or None
        except Exception:
            return None

    def emit(self, row: dict[str, object]) -> dict[str, object]:
        enriched = {
            "version": SUITE_VERSION,
            "run_id": self.run_id,
            "created_at": utc_now(),
            "backend": self.backend,
            "host_id": self.args.host_id,
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
        if "lazy_rootfs_tti" in self.args.benchmarks:
            self.run_lazy_rootfs_tti()
        if "cold_tti" in self.args.benchmarks:
            for mode in self.args.modes:
                self.run_cold_tti(mode)
        if "cold_import" in self.args.benchmarks:
            self.run_cold_import()
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

    def image_rootfs_cache_records(self) -> list[dict[str, object]]:
        records: list[dict[str, object]] = []
        for metadata_path in sorted(self.rootfs_cache_dir.glob("*.json")):
            data = parse_json_file(metadata_path)
            if not isinstance(data, dict):
                continue
            rootfs_path_raw = data.get("rootfs_path")
            rootfs_size = data.get("rootfs_size")
            storage = data.get("rootfs_storage")
            if not isinstance(rootfs_path_raw, str) or not isinstance(rootfs_size, int) or not isinstance(storage, dict):
                continue
            index_digest = storage.get("index_digest")
            if not isinstance(index_digest, str) or not index_digest.startswith("blake3:"):
                continue
            rootfs_path = Path(rootfs_path_raw)
            if not rootfs_path.is_absolute():
                rootfs_path = (metadata_path.parent / rootfs_path).resolve()
            if not rootfs_path.is_file():
                continue
            records.append({
                "metadata_path": str(metadata_path),
                "rootfs_path": str(rootfs_path),
                "rootfs_size": rootfs_size,
                "index_digest": index_digest,
                "flat_path": str(rootfs_digest_cache_path(self.rootfs_cache_dir, index_digest)),
            })
        return records

    def evict_flat_materializations(self, records: list[dict[str, object]]) -> tuple[int, int]:
        count = 0
        bytes_removed = 0
        for record in records:
            flat_path = Path(str(record["flat_path"]))
            try:
                stat = flat_path.stat()
                flat_path.unlink()
            except FileNotFoundError:
                continue
            count += 1
            bytes_removed += stat.st_size
        return count, bytes_removed

    def restore_flat_materializations(self, records: list[dict[str, object]]) -> int:
        count = 0
        for record in records:
            source_path = Path(str(record["rootfs_path"]))
            flat_path = Path(str(record["flat_path"]))
            if flat_path.exists():
                continue
            flat_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(source_path, flat_path)
            except FileExistsError:
                continue
            except OSError:
                shutil.copy2(source_path, flat_path)
            count += 1
        return count

    def run_image_tti_once(
        self,
        benchmark: str,
        mode: str,
        iteration: int,
        batch_start: int,
        extra_env: dict[str, str] | None = None,
    ) -> dict[str, object]:
        prefix = self.log_dir / benchmark / mode / f"{iteration:06d}"
        stdout = prefix.with_suffix(".stdout")
        stderr = prefix.with_suffix(".stderr")
        env = self.env
        if extra_env:
            env = self.env.copy()
            env.update(extra_env)
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
        started_at_ms = monotonic_ms() - batch_start
        status, tti_ms, error = run_command(argv, env=env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        ended_at_ms = monotonic_ms() - batch_start
        return {
            "benchmark": benchmark,
            "mode": mode,
            "iteration": iteration,
            "tti_ms": tti_ms,
            "success": status == 0,
            "status": status,
            "error": error,
            "rootfs_base_mode": parse_rootfs_base_mode(stderr),
            "stdout_first_line": first_output_line(stdout),
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
            "started_at_ms": started_at_ms,
            "ended_at_ms": ended_at_ms,
            **parse_run_stderr_metrics(stderr),
        }

    def run_lazy_rootfs_tti(self) -> None:
        records = self.image_rootfs_cache_records()
        if not records:
            die("lazy_rootfs_tti requires a prewarmed chunked image rootfs cache; run with prewarm enabled")

        batch_start = monotonic_ms()
        rows_by_mode: dict[str, list[dict[str, object]]] = {"lazy-cold": [], "eager-cold": [], "flat-hot": []}
        for iteration in range(self.args.iterations):
            evicted_count, evicted_bytes = self.evict_flat_materializations(records)
            lazy_row = self.run_image_tti_once("lazy_rootfs_tti", "lazy-cold", iteration, batch_start)
            lazy_row["flat_materializations_evicted"] = evicted_count
            lazy_row["flat_materialization_bytes_evicted"] = evicted_bytes
            lazy_row["success"] = lazy_row["status"] == 0 and lazy_row.get("rootfs_base_mode") == "lazy"
            self.emit(lazy_row)
            rows_by_mode["lazy-cold"].append(lazy_row)
            print(
                f"lazy_rootfs_tti lazy-cold iteration={iteration} "
                f"{'ok' if lazy_row.get('success') else 'failed'} "
                f"tti_ms={lazy_row.get('tti_ms')} first_output_ms={lazy_row.get('first_output_ms')}",
                file=sys.stderr,
            )

            restored_for_eager_count = self.restore_flat_materializations(records)
            evicted_count, evicted_bytes = self.evict_flat_materializations(records)
            eager_row = self.run_image_tti_once(
                "lazy_rootfs_tti",
                "eager-cold",
                iteration,
                batch_start,
                {EAGER_ROOTFS_ENV: "1"},
            )
            eager_row["flat_materializations_evicted"] = evicted_count
            eager_row["flat_materialization_bytes_evicted"] = evicted_bytes
            eager_row["flat_materializations_restored_before_evict"] = restored_for_eager_count
            eager_row["success"] = eager_row["status"] == 0 and eager_row.get("rootfs_base_mode") == "flat"
            self.emit(eager_row)
            rows_by_mode["eager-cold"].append(eager_row)
            print(
                f"lazy_rootfs_tti eager-cold iteration={iteration} "
                f"{'ok' if eager_row.get('success') else 'failed'} "
                f"tti_ms={eager_row.get('tti_ms')} first_output_ms={eager_row.get('first_output_ms')}",
                file=sys.stderr,
            )

            restored_count = self.restore_flat_materializations(records)
            flat_row = self.run_image_tti_once("lazy_rootfs_tti", "flat-hot", iteration, batch_start)
            flat_row["flat_materializations_restored"] = restored_count
            flat_row["success"] = flat_row["status"] == 0 and flat_row.get("rootfs_base_mode") == "flat"
            self.emit(flat_row)
            rows_by_mode["flat-hot"].append(flat_row)
            print(
                f"lazy_rootfs_tti flat-hot iteration={iteration} "
                f"{'ok' if flat_row.get('success') else 'failed'} "
                f"tti_ms={flat_row.get('tti_ms')} first_output_ms={flat_row.get('first_output_ms')}",
                file=sys.stderr,
            )

        for mode, rows in rows_by_mode.items():
            success_rows = [row for row in rows if row.get("success")]
            self.emit({
                "benchmark": "lazy_rootfs_tti",
                "mode": f"{mode}_batch",
                "success": len(success_rows) == len(rows),
                "count": len(rows),
                "wall_clock_ms": monotonic_ms() - batch_start,
                "time_to_first_ready_ms": min((row.get("tti_ms") for row in success_rows), default=None),
            })

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

    def synthetic_rootfs_tar(self) -> Path:
        fixture = self.work_dir / "synthetic-rootfs" / "rootfs.tar"
        if not fixture.exists():
            write_synthetic_rootfs_tar(
                fixture,
                file_count=self.args.synthetic_rootfs_file_count,
                file_size=self.args.synthetic_rootfs_file_size,
                dir_count=self.args.synthetic_rootfs_dir_count,
                symlink_count=self.args.synthetic_rootfs_symlink_count,
                hardlink_count=self.args.synthetic_rootfs_hardlink_count,
                depth=self.args.synthetic_rootfs_depth,
            )
        return fixture

    def run_cold_import(self) -> None:
        fixture = self.synthetic_rootfs_tar()
        for iteration in range(self.args.iterations):
            prefix = self.log_dir / "cold_import" / "synthetic_tar" / f"{iteration:06d}"
            stdout = prefix.with_suffix(".stdout")
            stderr = prefix.with_suffix(".stderr")
            import_cache = self.work_dir / "cold_import" / f"cache-{iteration:06d}"
            shutil.rmtree(import_cache, ignore_errors=True)
            import_cache.mkdir(parents=True, exist_ok=True)
            env = self.env.copy()
            env["SPOREVM_ROOTFS_CACHE_DIR"] = str(import_cache)
            env["SPOREVM_ROOTFS_BUILD_PROFILE"] = "1"
            argv = [
                str(self.spore_bin),
                "rootfs",
                "import-tar",
                str(fixture),
                "--ref",
                self.args.synthetic_rootfs_ref,
                "--platform",
                self.args.platform,
            ]
            status, elapsed_ms, error = run_command(argv, env=env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
            success = status == 0
            row = self.emit({
                "benchmark": "cold_import",
                "mode": "synthetic_tar",
                "iteration": iteration,
                "success": success,
                "status": status,
                "elapsed_ms": elapsed_ms,
                "tti_ms": elapsed_ms,
                "error": error,
                "fixture_tar": str(fixture),
                "fixture_tar_bytes": fixture.stat().st_size,
                "synthetic_rootfs_ref": self.args.synthetic_rootfs_ref,
                "synthetic_rootfs_file_count": self.args.synthetic_rootfs_file_count,
                "synthetic_rootfs_file_size": self.args.synthetic_rootfs_file_size,
                "synthetic_rootfs_dir_count": self.args.synthetic_rootfs_dir_count,
                "synthetic_rootfs_symlink_count": self.args.synthetic_rootfs_symlink_count,
                "synthetic_rootfs_hardlink_count": self.args.synthetic_rootfs_hardlink_count,
                "synthetic_rootfs_depth": self.args.synthetic_rootfs_depth,
                "synthetic_rootfs_seed": SYNTHETIC_ROOTFS_SEED,
                "stdout_path": str(stdout),
                "stderr_path": str(stderr),
                **parse_rootfs_import_stdout(stdout),
                **parse_rootfs_profile_metrics(stderr),
            })
            print(
                f"cold_import synthetic_tar iteration={iteration} "
                f"{'ok' if row.get('success') else 'failed'} elapsed_ms={row.get('elapsed_ms')}",
                file=sys.stderr,
            )
            if not success:
                die(f"cold synthetic import failed status={status} stdout={stdout} stderr={stderr}")
        rows = [
            row for row in self.rows
            if row.get("benchmark") == "cold_import" and row.get("mode") == "synthetic_tar" and isinstance(row.get("iteration"), int)
        ]
        self.emit({
            "benchmark": "cold_import",
            "mode": "synthetic_tar_batch",
            "success": all(bool(row.get("success")) for row in rows) if rows else False,
            "count": len(rows),
        })

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
            "--save",
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
            str(self.root / "scripts/benchmark/writable-rootfs.sh"),
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
            "--timeout",
            f"{self.args.timeout_s}s",
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
                **parse_rootfs_profile_text(str(row.get("stderr", ""))),
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
            samples = [row["tti_ms"] for row in success_rows]
            values = [float(value) for value in samples]
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
                "samples": samples,
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
                '{"event":"rootfs_open","digest":"abc","size":4096,"elapsed_ms":7}',
                "kvm restore metrics: mode=local_backing ram_mib=512 chunks=4 nonzero_chunks=2 manifest_ms=1 map_ram_ms=2 memory_ms=3 state_ms=4 pre_run_ms=10",
                "run exec probe timing: attach_ms=1 connect_request_delivered_ms=2 connect_ms=3 request_delivered_ms=4 first_output_ms=5 guest_timing_ms=6 response_ms=8",
                "run backend timing: elapsed_ms=12 stream_response_ms=8 tail_ms=4 cause=probe_complete",
                "vsock host stream guest timing: timing listen=20 accept=30 decode=31 spawn=34 exit=39 now=40",
                "kvm probe completion timing: observed_ms=8 pending_completion_ms=2 return_ms=10",
            ]) + "\n",
            encoding="utf-8",
        )
        metrics = parse_run_stderr_metrics(stderr)
        assert metrics["rootfs_open_verified_ms"] == 7
        assert metrics["rootfs_bytes_verified"] == 4096
        assert metrics["backend_restore_mode"] == "local_backing"
        assert metrics["backend_restore_ms"] == 10
        assert metrics["backend_run_ms"] == 12
        assert metrics["backend_tail_ms"] == 4
        assert metrics["vsock_connect_ms"] == 3
        assert metrics["exec_connect_request_delivery_ms"] == 1
        assert metrics["exec_connect_ack_ms"] == 1
        assert metrics["exec_request_delivery_ms"] == 1
        assert metrics["guest_listen_ms"] == 20
        assert metrics["guest_accept_delay_ms"] == 10
        assert metrics["guest_exit_delay_ms"] == 5
        assert metrics["kvm_pending_exit_completion_ms"] == 2
        assert metrics["exec_response_ms"] == 8
        assert summarize_field([metrics], "exec_response_ms")["median"] == 8.0
        stderr.write_text(
            "spore rootfs profile: phase=rootfs_cas_inline ms=42 chunks=3 zero_chunks=1 nonzero_chunks=2 objects_written=2 object_bytes_written=8192 index_bytes=256\n",
            encoding="utf-8",
        )
        rootfs_profile = parse_rootfs_profile_metrics(stderr)
        assert rootfs_profile["rootfs_profile_rootfs_cas_inline_ms"] == 42
        assert rootfs_profile["rootfs_profile_rootfs_cas_inline_objects_written"] == 2
        memory_spore = Path(tmp) / "memory-spore"
        memory_spore.mkdir()
        (memory_spore / "manifest.json").write_text(json.dumps({
            "platform": {"ram_size": 8},
            "memory": {
                "logical_size": 8,
                "chunk_size": 2,
                "chunks": [{"logical_chunk": 1, "digest": "blake3:test"}],
                "zero_chunks": [0, 2, 3],
            },
        }), encoding="utf-8")
        memory_metrics = memory_economics(memory_spore)
        assert memory_metrics["chunks_total"] == 4
        assert memory_metrics["chunks_nonzero"] == 1
        assert memory_metrics["chunks_zero_elided"] == 3
        stdout = Path(tmp) / "import.stdout"
        stdout.write_text(
            "rootfs: /tmp/rootfs.ext4\nmetadata: /tmp/rootfs.json\nref: local/test:fixture\nresolved: local/test:fixture@sha256:abc\nrootfs_identity: blake3:"
            + ("a" * 64)
            + "\n",
            encoding="utf-8",
        )
        import_fields = parse_rootfs_import_stdout(stdout)
        assert import_fields["rootfs_import_rootfs_identity"] == "blake3:" + ("a" * 64)
        assert import_fields["rootfs_import_index_digest"] == "blake3:" + ("a" * 64)
        writable_profile = parse_rootfs_profile_text(
            "spore rootfs profile: phase=native_ext4_emit ms=11 objects_written=4 object_bytes_written=16384\n"
        )
        assert writable_profile["rootfs_profile_native_ext4_emit_ms"] == 11
        assert writable_profile["rootfs_profile_native_ext4_emit_objects_written"] == 4
        assert "writable_rootfs" in PROFILES["nightly"]["benchmarks"]
        fixture_a = Path(tmp) / "fixture-a.tar"
        fixture_b = Path(tmp) / "fixture-b.tar"
        fixture_kwargs = {
            "file_count": 12,
            "file_size": 64,
            "dir_count": 6,
            "symlink_count": 3,
            "hardlink_count": 3,
            "depth": 3,
        }
        write_synthetic_rootfs_tar(fixture_a, **fixture_kwargs)
        write_synthetic_rootfs_tar(fixture_b, **fixture_kwargs)
        assert fixture_a.read_bytes() == fixture_b.read_bytes()
        with tarfile.open(fixture_a, "r", format=tarfile.USTAR_FORMAT) as tar:
            members = tar.getmembers()
            dirs = [member for member in members if member.isdir()]
            symlinks = [member for member in members if member.issym()]
            hardlinks = [member for member in members if member.islnk()]
            payloads = [member for member in members if member.isfile() and "/payload-" in member.name]
        assert len(dirs) >= fixture_kwargs["dir_count"]
        assert len(payloads) == fixture_kwargs["file_count"]
        assert len(symlinks) == fixture_kwargs["symlink_count"]
        assert len(hardlinks) == fixture_kwargs["hardlink_count"]
        stderr.write_text("debug: runtime disk rootfs base: lazy chunk index blake3:abc\n", encoding="utf-8")
        assert parse_rootfs_base_mode(stderr) == "lazy"
        stderr.write_text("debug: runtime disk rootfs base: flat artifact blake3:abc\n", encoding="utf-8")
        assert parse_rootfs_base_mode(stderr) == "flat"
        cache_root = Path(tmp) / "cache"
        cache_root.mkdir()
        digest = "blake3:" + ("a" * 64)
        assert rootfs_digest_cache_path(cache_root, digest) == cache_root / "by-digest" / "blake3" / f"{'a' * 64}.ext4"
        rootfs_path = cache_root / "image.ext4"
        rootfs_path.write_bytes(b"rootfs")
        (cache_root / "image.json").write_text(json.dumps({
            "rootfs_path": str(rootfs_path),
            "rootfs_size": 6,
            "rootfs_storage": {
                "index_digest": digest,
            },
        }), encoding="utf-8")
        cache_runner = object.__new__(BenchmarkRunner)
        cache_runner.rootfs_cache_dir = cache_root
        records = BenchmarkRunner.image_rootfs_cache_records(cache_runner)
        assert len(records) == 1
        assert records[0]["index_digest"] == digest
        flat_path = Path(str(records[0]["flat_path"]))
        flat_path.parent.mkdir(parents=True)
        flat_path.write_bytes(b"rootfs")
        evicted_count, evicted_bytes = BenchmarkRunner.evict_flat_materializations(cache_runner, records)
        assert evicted_count == 1
        assert evicted_bytes == 6
        assert not flat_path.exists()
        restored_count = BenchmarkRunner.restore_flat_materializations(cache_runner, records)
        assert restored_count == 1
        assert flat_path.read_bytes() == b"rootfs"
        runner = object.__new__(BenchmarkRunner)
        runner.run_id = "self-test"
        runner.raw_path = Path(tmp) / "results.jsonl"
        runner.rows = [
            {"benchmark": "cold_tti", "mode": "burst", "iteration": 0, "tti_ms": 214, "success": True},
            {"benchmark": "cold_tti", "mode": "burst", "iteration": 1, "tti_ms": 999, "success": False},
            {"benchmark": "cold_tti", "mode": "burst", "iteration": 2, "tti_ms": 216, "success": True},
        ]
        runner.config_json = lambda: {}
        result = BenchmarkRunner.summary(runner)["results"][0]
        assert result["count"] == 3
        assert result["success_count"] == 2
        assert result["samples"] == [214, 216]
        assert result["tti_ms"]["median"] == 215.0
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
    parser.add_argument("--benchmarks", help="Comma-separated subset: cold_tti,cold_import,warm_spore_tti,distribution_tti,writable_rootfs,lazy_rootfs_tti")
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
    parser.add_argument("--host-id", default=default_host_id())
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--platform", default=DEFAULT_PLATFORM)
    parser.add_argument("--memory", default="512mb")
    parser.add_argument("--command", default=DEFAULT_COMMAND)
    parser.add_argument("--allow-image-resolve-fallback", action="store_true", help="Use the requested image ref when rootfs resolve fails")
    parser.add_argument("--timeout-s", type=int)
    parser.add_argument("--synthetic-rootfs-ref", default=DEFAULT_SYNTHETIC_ROOTFS_REF)
    parser.add_argument("--synthetic-rootfs-file-count", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_FILE_COUNT)
    parser.add_argument("--synthetic-rootfs-file-size", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_FILE_SIZE)
    parser.add_argument("--synthetic-rootfs-dir-count", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_DIR_COUNT)
    parser.add_argument("--synthetic-rootfs-symlink-count", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_SYMLINK_COUNT)
    parser.add_argument("--synthetic-rootfs-hardlink-count", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_HARDLINK_COUNT)
    parser.add_argument("--synthetic-rootfs-depth", type=int, default=DEFAULT_SYNTHETIC_ROOTFS_DEPTH)
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
        if benchmark not in ("cold_tti", "cold_import", "warm_spore_tti", "distribution_tti", "writable_rootfs", "lazy_rootfs_tti"):
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
    if args.synthetic_rootfs_file_count <= 0:
        die("--synthetic-rootfs-file-count must be positive")
    if args.synthetic_rootfs_file_size <= 0:
        die("--synthetic-rootfs-file-size must be positive")
    if args.synthetic_rootfs_dir_count <= 0:
        die("--synthetic-rootfs-dir-count must be positive")
    if args.synthetic_rootfs_symlink_count < 0:
        die("--synthetic-rootfs-symlink-count must be non-negative")
    if args.synthetic_rootfs_hardlink_count < 0:
        die("--synthetic-rootfs-hardlink-count must be non-negative")
    if args.synthetic_rootfs_depth <= 0:
        die("--synthetic-rootfs-depth must be positive")
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
