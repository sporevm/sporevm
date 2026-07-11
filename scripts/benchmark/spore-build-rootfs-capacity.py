#!/usr/bin/env python3
"""Run isolated Spore build rootfs-growth probes.

This is an engineering harness, not a product configuration surface. It keeps
the P0 negative controls and isolated preparation probes out of `spore build`
help while producing machine-readable evidence from the real guest/kernel. The
paired matrix mode uses the historical tiny Dockerfile fixture and keeps its
literal default-path measurements separate from instrumented controls.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import statistics
import subprocess
import sys
import tempfile
import time


MODES = ("native", "checksum-noinit", "checksum-lazy", "force-fallback")
PAIRED_PROFILES = ("default-path", "instrumented")
PAIRED_SCENARIOS = (
    "compact_cold",
    "pregrown_cold_control",
    "shared_prepare_no_cache",
    "compact_warm",
    "pregrown_warm_control",
    "compact_incremental",
    "pregrown_incremental_control",
)
PAIRED_BASE_IMAGE = (
    "docker.io/library/alpine@"
    "sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d"
)
PAIRED_DISK_SIZE = "16gb"
MIN_PAIRED_GATE_SAMPLES = 5
MAX_VERSION_OUTPUT_BYTES = 4096
MAX_RAW_COMMAND_OUTPUT_BYTES = 64 * 1024
PREGROWN_CONTROL_CONTRACT = (
    "The pre-grown lane is independently grown from the same cloned compact "
    "parent to the same 16 GiB geometry before measurement. Its measured build "
    "must require no PREPARE operation. The run-commit command takes its own "
    "snapshot, so its rootfs index is not expected to be byte-identical to the "
    "build PREPARE child."
)
EXPERIMENT_ENV = (
    "SPOREVM_ROOTFS_GROWTH_EXPERIMENTS",
    "SPOREVM_EXT4_WRITER",
    "SPOREVM_EXT4_METADATA_CSUM_EXPERIMENT",
    "SPOREVM_ROOTFS_LAZY_INIT_NEGATIVE_CONTROL",
    "SPOREVM_WRITE_ZEROES_FORCE_UNSUPPORTED_EXPERIMENT",
    "SPOREVM_WRITE_ZEROES_FORCE_BACKEND_FAILURE_EXPERIMENT",
    "SPOREVM_ROOTFS_GROWTH_P0_IDLE_MS",
)
MAX_POSITIVE_ZERO_OUT_BYTES = 64 * 1024
METRICS_RE = re.compile(r"rootfs growth blk metrics: (?P<fields>.+)")
PREPARE_RE = re.compile(r"rootfs preparation metrics: (?P<fields>.+)")
IDLE_RE = re.compile(
    r"rootfs growth P0 idle: ms=(?P<ms>\d+) write_zeroes_delta=0 out_delta=0"
)
FIELD_RE = re.compile(r"(?P<key>[a-z_]+)=(?P<value>0x[0-9a-f]+|\d+)")
DARWIN_RSS_RE = re.compile(r"(?m)^\s*(?P<bytes>\d+)\s+maximum resident set size\s*$")
LINUX_RSS_RE = re.compile(r"(?m)^\s*Maximum resident set size \(kbytes\):\s*(?P<kib>\d+)\s*$")
ROOTFS_INDEX_RE = re.compile(r"(?m)^  Rootfs index: (?P<value>\S+)\s*$")
RESOLVED_IMAGE_RE = re.compile(r"(?m)^  Resolved: (?P<value>\S+)\s*$")
CACHE_STATUS_RE = re.compile(r"(?m)^  Cache: (?P<value>\S+)\s*$")
DISK_SNAPSHOT_RE = re.compile(r"disk snapshot metrics:")
BUILD_BOOT_RE = re.compile(r"runtime disk rootfs base:")


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Paired control contract: " + PREGROWN_CONTROL_CONTRACT,
    )
    parser.add_argument("--spore", type=Path, default=root / "zig-out/bin/spore")
    parser.add_argument("--mode", choices=MODES, action="append", dest="modes")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--idle-ms", type=int, default=6000)
    parser.add_argument("--measure-rss", action="store_true")
    parser.add_argument(
        "--paired-matrix",
        action="store_true",
        help=(
            "run the historical tiny-build paired performance matrix instead "
            "of the P0 growth probe"
        ),
    )
    parser.add_argument(
        "--paired-profile",
        choices=PAIRED_PROFILES,
        default="default-path",
        help=(
            "paired matrix measurement class: literal commands without debug/"
            "experiment controls, or a separately labelled instrumented run"
        ),
    )
    parser.add_argument(
        "--raw-output",
        type=Path,
        help="write paired setup, measurement, and verification events as JSONL",
    )
    parser.add_argument(
        "--default-path",
        action="store_true",
        help="time the literal user path without --debug or experiment controls",
    )
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.modes = args.modes or ["native"]
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    if not 0 <= args.idle_ms <= 10_000:
        parser.error("--idle-ms must be between 0 and 10000")
    if args.default_path and (args.modes != ["native"] or args.idle_ms != 0):
        parser.error("--default-path requires native mode and --idle-ms 0")
    if args.paired_matrix:
        if args.default_path:
            parser.error(
                "--paired-matrix selects its path with --paired-profile; "
                "do not also pass --default-path"
            )
        if args.modes != ["native"]:
            parser.error("--paired-matrix supports only the native product path")
        if args.idle_ms != 6000:
            parser.error("--idle-ms is a P0 control and cannot be used with --paired-matrix")
    elif args.raw_output is not None or args.paired_profile != "default-path":
        parser.error("--raw-output/--paired-profile require --paired-matrix")
    return args


def parse_fields(text: str) -> dict[str, int] | None:
    matches = list(METRICS_RE.finditer(text))
    if not matches:
        return None
    fields: dict[str, int] = {}
    for match in FIELD_RE.finditer(matches[-1].group("fields")):
        fields[match.group("key")] = int(match.group("value"), 0)
    return fields


def parse_prepare_ms(text: str) -> int | None:
    matches = list(PREPARE_RE.finditer(text))
    if not matches:
        return None
    fields = {
        match.group("key"): int(match.group("value"), 0)
        for match in FIELD_RE.finditer(matches[-1].group("fields"))
    }
    return fields.get("publish_ms")


def mode_env(base: dict[str, str], mode: str) -> dict[str, str]:
    env = dict(base)
    for name in EXPERIMENT_ENV:
        env.pop(name, None)
    if mode in ("checksum-noinit", "checksum-lazy"):
        env["SPOREVM_EXT4_WRITER"] = "external"
        env["SPOREVM_EXT4_METADATA_CSUM_EXPERIMENT"] = "1"
    if mode == "checksum-lazy":
        env["SPOREVM_ROOTFS_LAZY_INIT_NEGATIVE_CONTROL"] = "1"
    if mode == "force-fallback":
        env["SPOREVM_WRITE_ZEROES_FORCE_UNSUPPORTED_EXPERIMENT"] = "1"
    return env


def measured_command(command: list[str], enabled: bool) -> list[str]:
    if not enabled:
        return command
    time_bin = Path("/usr/bin/time")
    if not time_bin.is_file():
        return command
    if sys.platform == "darwin":
        return [str(time_bin), "-l", *command]
    if sys.platform.startswith("linux"):
        return [str(time_bin), "-v", *command]
    return command


def parse_peak_rss(stderr: str, enabled: bool) -> int | None:
    if not enabled:
        return None
    match = DARWIN_RSS_RE.search(stderr)
    if match:
        return int(match.group("bytes"))
    match = LINUX_RSS_RE.search(stderr)
    if match:
        return int(match.group("kib")) * 1024
    return None


def median_or_none(values: list[int]) -> float | None:
    return statistics.median(values) if values else None


def nearest_rank_or_none(values: list[int], percentile: float) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def run_trial(args: argparse.Namespace, root: Path, mode: str, iteration: int) -> dict[str, object]:
    trial = root / mode / f"trial-{iteration:02d}"
    context = trial / "context"
    context.mkdir(parents=True)
    env = mode_env(os.environ, mode)
    env["SPOREVM_ROOTFS_CACHE_DIR"] = str(trial / "rootfs-cache")
    env["SPOREVM_RUNTIME_DIR"] = str(trial / "runtime")
    if not args.default_path:
        env["SPOREVM_ROOTFS_GROWTH_EXPERIMENTS"] = "1"
        env["SPOREVM_ROOTFS_GROWTH_P0_IDLE_MS"] = str(args.idle_ms)
    base_ref = f"local/rootfs-capacity-p0-base-{mode}:trial-{iteration}"
    setup_command = [
        str(args.spore),
        "run",
        "--image",
        "docker.io/library/alpine:3.20",
        "--commit",
        base_ref,
        "--",
        "/bin/true",
    ]
    setup = subprocess.run(setup_command, env=env, text=True, capture_output=True, check=False)
    (trial / "setup.stdout.log").write_text(setup.stdout, encoding="utf-8")
    (trial / "setup.stderr.log").write_text(setup.stderr, encoding="utf-8")
    if setup.returncode != 0:
        return {
            "mode": mode,
            "iteration": iteration,
            "elapsed_ms": 0,
            "prepare_ms": None,
            "peak_rss_bytes": None,
            "rss_requested": args.measure_rss,
            "instrumented": not args.default_path,
            "exit_code": setup.returncode,
            "idle_quiescent": False,
            "idle_ms": None,
            "idle_requested_ms": args.idle_ms,
            "background_writes_detected": False,
            "blk": None,
            "command": setup_command,
            "trial_dir": str(trial),
            "setup_failed": True,
        }
    (context / "Dockerfile").write_text(
        f"FROM {base_ref}\nRUN true\nRUN true\n",
        encoding="utf-8",
    )
    command = [str(args.spore)]
    if not args.default_path:
        command.append("--debug")
    command.extend([
        "build",
        "--network",
        "none",
        "--no-cache",
        "-t",
        f"local/rootfs-capacity-p0-{mode}:trial-{iteration}",
    ])
    command.append(str(context))

    started = time.monotonic_ns()
    completed = subprocess.run(
        measured_command(command, args.measure_rss),
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
    (trial / "stdout.log").write_text(completed.stdout, encoding="utf-8")
    (trial / "stderr.log").write_text(completed.stderr, encoding="utf-8")
    combined = completed.stdout + "\n" + completed.stderr
    stats = parse_fields(combined)
    idle = IDLE_RE.search(combined)
    return {
        "mode": mode,
        "iteration": iteration,
        "elapsed_ms": elapsed_ms,
        "prepare_ms": parse_prepare_ms(combined),
        "peak_rss_bytes": parse_peak_rss(completed.stderr, args.measure_rss),
        "rss_requested": args.measure_rss,
        "instrumented": not args.default_path,
        "exit_code": completed.returncode,
        "idle_quiescent": idle is not None,
        "idle_ms": int(idle.group("ms")) if idle else None,
        "idle_requested_ms": args.idle_ms,
        "background_writes_detected": "RootfsBackgroundWritesDetected" in combined,
        "blk": stats,
        "command": command,
        "trial_dir": str(trial),
        "setup_failed": False,
    }


def validate_trial(row: dict[str, object]) -> list[str]:
    mode = str(row["mode"])
    stats = row["blk"]
    errors: list[str] = []
    if not row.get("instrumented"):
        if row["exit_code"] != 0:
            errors.append(f"default-path build exited {row['exit_code']}")
        if row.get("rss_requested") and row.get("peak_rss_bytes") is None:
            errors.append("peak RSS was requested but could not be parsed")
        return errors
    if not isinstance(stats, dict):
        return ["missing rootfs growth block metrics"]
    if mode != "checksum-lazy" and row.get("prepare_ms") is None:
        errors.append("missing rootfs preparation timing")
    if row.get("rss_requested") and row.get("peak_rss_bytes") is None:
        errors.append("peak RSS was requested but could not be parsed")
    accepted = int(stats.get("accepted_features", 0))
    requests = int(stats.get("write_zeroes_requests", 0))
    unsupported = int(stats.get("write_zeroes_unsupported", 0))
    backend_failures = int(stats.get("write_zeroes_backend_failures", 0))
    all_zero_out = int(stats.get("out_all_zero_bytes", 0))
    if accepted & (1 << 14) == 0:
        errors.append("WRITE_ZEROES bit 14 was not accepted")
    if requests == 0:
        errors.append("no WRITE_ZEROES request reached the device")
    if mode == "force-fallback":
        if row["exit_code"] != 0:
            errors.append(f"forced-fallback build exited {row['exit_code']}")
        if unsupported == 0:
            errors.append("forced fallback produced no UNSUPP request")
        if all_zero_out == 0:
            errors.append("forced fallback produced no all-zero OUT bytes")
        if int(row["idle_requested_ms"]) != 0 and not row["idle_quiescent"]:
            errors.append("forced-fallback post-checkpoint quiescence proof is missing")
    elif mode == "checksum-lazy":
        if row["exit_code"] == 0:
            errors.append("lazy-init negative control unexpectedly succeeded")
        if not row["background_writes_detected"]:
            errors.append("lazy-init negative control did not expose post-checkpoint writes")
    else:
        if row["exit_code"] != 0:
            errors.append(f"build exited {row['exit_code']}")
        if unsupported != 0 or int(stats.get("write_zeroes_errors", 0)) != 0:
            errors.append("WRITE_ZEROES completed with errors/unsupported status")
        if backend_failures != 0:
            errors.append("WRITE_ZEROES backend failure poisoned the mutable head")
        if int(stats.get("write_zeroes_ok", 0)) != requests:
            errors.append("not every WRITE_ZEROES request completed OK")
        if int(stats.get("write_zeroes_unmap", 0)) != requests:
            errors.append("not every WRITE_ZEROES request carried UNMAP")
        if all_zero_out > MAX_POSITIVE_ZERO_OUT_BYTES:
            errors.append(
                "successful WRITE_ZEROES path emitted more than one chunk of "
                "ordinary all-zero OUT payload"
            )
        if int(row["idle_requested_ms"]) != 0 and not row["idle_quiescent"]:
            errors.append("requested post-checkpoint quiescence proof is missing")
    return errors


def paired_env(cache_dir: Path, runtime_dir: Path, instrumented: bool) -> dict[str, str]:
    env = mode_env(os.environ, "native")
    env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache_dir)
    env["SPOREVM_RUNTIME_DIR"] = str(runtime_dir)
    if instrumented:
        env["SPOREVM_ROOTFS_GROWTH_EXPERIMENTS"] = "1"
        env["SPOREVM_ROOTFS_GROWTH_P0_IDLE_MS"] = "0"
    return env


def historical_context(context: Path, base_ref: str, changing: str) -> None:
    context.mkdir(parents=True, exist_ok=True)
    (context / "Dockerfile").write_text(
        "ARG BASE=" + base_ref + "\n"
        "FROM ${BASE}\n"
        "ARG MESSAGE=hello\n"
        "ENV MESSAGE=${MESSAGE}\n"
        "WORKDIR /work\n"
        "COPY stable.txt ./stable.txt\n"
        "COPY changing.txt ./changing.txt\n"
        'RUN test "$(cat stable.txt)" = stable && test -n "$MESSAGE" '
        "&& cp changing.txt result.txt\n"
        'CMD ["/bin/sh", "-c", "test -s /work/result.txt"]\n',
        encoding="utf-8",
    )
    (context / "stable.txt").write_text("stable\n", encoding="utf-8")
    (context / "changing.txt").write_text(changing, encoding="utf-8")


def first_match(pattern: re.Pattern[str], text: str) -> str | None:
    match = pattern.search(text)
    return match.group("value") if match else None


def paired_counts(text: str, instrumented: bool) -> dict[str, int] | None:
    if not instrumented:
        return None
    resize_count = len(PREPARE_RE.findall(text))
    snapshot_count = len(DISK_SNAPSHOT_RE.findall(text))
    return {
        "boot_count": len(BUILD_BOOT_RE.findall(text)),
        "resize_count": resize_count,
        "executed_steps": max(0, snapshot_count - resize_count),
        "snapshot_count": snapshot_count,
    }


def run_paired_command(
    args: argparse.Namespace,
    *,
    command: list[str],
    env: dict[str, str],
    log_dir: Path,
    log_name: str,
    row_type: str,
    profile: str,
    iteration: int,
    lane: str,
    scenario: str,
    measured: bool,
    cwd: Path | None = None,
) -> dict[str, object]:
    log_dir.mkdir(parents=True, exist_ok=True)
    executed = measured_command(command, args.measure_rss and measured)
    started = time.monotonic_ns()
    completed = subprocess.run(
        executed,
        env=env,
        cwd=cwd,
        capture_output=True,
        check=False,
    )
    elapsed_ms = (time.monotonic_ns() - started) / 1_000_000
    stdout_path = log_dir / f"{log_name}.stdout.log"
    stderr_path = log_dir / f"{log_name}.stderr.log"
    stdout_path.write_bytes(completed.stdout)
    stderr_path.write_bytes(completed.stderr)
    stdout_text = completed.stdout.decode("utf-8", errors="replace")
    stderr_text = completed.stderr.decode("utf-8", errors="replace")
    combined = stdout_text + "\n" + stderr_text
    return {
        "row_type": row_type,
        "profile": profile,
        "measurement_class": (
            "instrumented-engineering-control"
            if profile == "instrumented"
            else "literal-default-path"
        ),
        "iteration": iteration,
        "lane": lane,
        "scenario": scenario,
        "measured": measured,
        "elapsed_ms": round(elapsed_ms, 3),
        "exit_code": completed.returncode,
        "command": command,
        "executed_command": executed,
        "cwd": str(cwd or Path.cwd()),
        "stdout_log": str(stdout_path),
        "stderr_log": str(stderr_path),
        "stdout": bounded_process_output(
            completed.stdout,
            MAX_RAW_COMMAND_OUTPUT_BYTES,
        ),
        "stderr": bounded_process_output(
            completed.stderr,
            MAX_RAW_COMMAND_OUTPUT_BYTES,
        ),
        "rootfs_index": first_match(ROOTFS_INDEX_RE, stdout_text),
        "resolved_image": first_match(RESOLVED_IMAGE_RE, stdout_text),
        "cache_status": first_match(CACHE_STATUS_RE, stdout_text),
        "prepare_ms": parse_prepare_ms(combined),
        "counts": paired_counts(combined, profile == "instrumented") if measured else None,
        "peak_rss_bytes": (
            parse_peak_rss(stderr_text, args.measure_rss) if measured else None
        ),
        "rss_requested": args.measure_rss and measured,
        "validation_errors": [],
    }


def find_local_image_identity(cache_dir: Path, image_ref: str) -> dict[str, object] | None:
    for path in sorted(cache_dir.glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(value, dict) or value.get("image_ref") != image_ref:
            continue
        storage = value.get("rootfs_storage")
        if not isinstance(storage, dict):
            continue
        return {
            "image_ref": image_ref,
            "resolved_image_ref": value.get("resolved_image_ref"),
            "index_digest": storage.get("index_digest"),
            "logical_size": storage.get("logical_size"),
            "metadata_path": str(path),
        }
    return None


def find_prepare_records(cache_dir: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for path in sorted((cache_dir / "build" / "steps").glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(value, dict) or value.get("instruction_kind") != "PREPARE":
            continue
        records.append(
            {
                "step_key": value.get("step_key"),
                "parent_index_digest": value.get("parent_index_digest"),
                "child_index_digest": value.get("child_index_digest"),
                "exact_target": value.get("exact_target"),
                "producer_identity": value.get("producer_identity"),
                "record_path": str(path),
            }
        )
    return records


EXPECTED_PAIRED_COUNTS = {
    "compact_cold": (1, 1, 4),
    "pregrown_cold_control": (1, 0, 4),
    "shared_prepare_no_cache": (1, 0, 4),
    "compact_warm": (0, 0, 0),
    "pregrown_warm_control": (0, 0, 0),
    "compact_incremental": (1, 0, 2),
    "pregrown_incremental_control": (1, 0, 2),
}


def validate_paired_measurement(row: dict[str, object]) -> list[str]:
    errors: list[str] = []
    scenario = str(row["scenario"])
    if row["exit_code"] != 0:
        errors.append(f"build exited {row['exit_code']}")
        return errors
    for field in ("rootfs_index", "resolved_image", "cache_status"):
        if row.get(field) is None:
            errors.append(f"missing {field.replace('_', ' ')}")
    expected_cache = "hit" if scenario.endswith("warm") or scenario.endswith("warm_control") else "miss"
    if row.get("cache_status") != expected_cache:
        errors.append(f"expected cache {expected_cache}, got {row.get('cache_status')}")
    if row.get("rss_requested") and row.get("peak_rss_bytes") is None:
        errors.append("peak RSS was requested but could not be parsed")
    counts = row.get("counts")
    if row.get("profile") == "instrumented":
        if not isinstance(counts, dict):
            errors.append("instrumented measurement has no observed counts")
        else:
            boot, resize, steps = EXPECTED_PAIRED_COUNTS[scenario]
            expected = {
                "boot_count": boot,
                "resize_count": resize,
                "executed_steps": steps,
                "snapshot_count": resize + steps,
            }
            for field, value in expected.items():
                if counts.get(field) != value:
                    errors.append(
                        f"expected {field}={value}, got {counts.get(field)}"
                    )
        if scenario == "compact_cold" and row.get("prepare_ms") is None:
            errors.append("compact cold build has no preparation timing")
        if scenario != "compact_cold" and row.get("prepare_ms") is not None:
            errors.append("non-preparation path unexpectedly emitted preparation timing")
    elif counts is not None:
        errors.append("literal default-path measurement unexpectedly inferred counts")
    return errors


def paired_build_command(
    args: argparse.Namespace,
    profile: str,
    context: Path,
    tag: str,
    no_cache: bool,
) -> list[str]:
    command = [str(args.spore)]
    if profile == "instrumented":
        command.append("--debug")
    command.extend(["build", "--network", "none"])
    if no_cache:
        command.append("--no-cache")
    command.extend(["-t", tag, str(context)])
    return command


def number_stats(values: list[float]) -> dict[str, object]:
    return {
        "samples": len(values),
        "median_ms": statistics.median(values) if values else None,
        "p95_ms": nearest_rank_or_none(values, 0.95),
    }


def delta_stats(rows: list[dict[str, object]], name: str) -> dict[str, object]:
    paired_rows = [row for row in rows if row["name"] == name]
    values_ms = [float(row["delta_ms"]) for row in paired_rows]
    values_pct = [
        float(row["delta_pct_of_control"])
        for row in paired_rows
        if row["delta_pct_of_control"] is not None
    ]
    return {
        **number_stats(values_ms),
        "median_delta_pct": statistics.median(values_pct) if values_pct else None,
        "p95_delta_pct": nearest_rank_or_none(values_pct, 0.95),
        "paired_observations": [
            {
                "iteration": row["iteration"],
                "candidate_ms": row["left_ms"],
                "control_ms": row["right_ms"],
                "delta_ms": row["delta_ms"],
                "delta_pct_of_control": row["delta_pct_of_control"],
            }
            for row in paired_rows
        ],
    }


def upper_bound_gate(
    *,
    observed_name: str,
    observed: float | int | None,
    threshold: float | int,
    unit: str,
    samples: int,
    details: dict[str, object] | None = None,
) -> dict[str, object]:
    if samples < MIN_PAIRED_GATE_SAMPLES or observed is None:
        status = "insufficient-samples"
    else:
        status = "pass" if observed <= threshold else "fail"
    result: dict[str, object] = {
        "status": status,
        "observed": {observed_name: observed},
        "threshold": {
            "operator": "<=",
            "value": threshold,
            "unit": unit,
        },
        "sample_count": samples,
        "required_samples": MIN_PAIRED_GATE_SAMPLES,
    }
    if details:
        observed_fields = result["observed"]
        assert isinstance(observed_fields, dict)
        observed_fields.update(details)
    return result


def aggregate_gate_status(gates: dict[str, dict[str, object]]) -> str:
    statuses = {gate["status"] for gate in gates.values()}
    if "fail" in statuses:
        return "fail"
    if "insufficient-samples" in statuses:
        return "insufficient-samples"
    return "pass"


def bounded_process_output(
    data: bytes | None,
    limit: int = MAX_VERSION_OUTPUT_BYTES,
) -> dict[str, object]:
    payload = data or b""
    bounded = payload[:limit]
    return {
        "text": bounded.decode("utf-8", errors="replace"),
        "bytes": len(payload),
        "sha256": "sha256:" + hashlib.sha256(payload).hexdigest(),
        "truncated": len(payload) > len(bounded),
        "limit_bytes": limit,
    }


def spore_binary_identity(path: Path) -> dict[str, object]:
    errors: list[str] = []
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = resolved.stat()
        digest = hashlib.sha256()
        with resolved.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        size = metadata.st_size
        sha256 = "sha256:" + digest.hexdigest()
    except OSError as err:
        resolved = path.expanduser().resolve()
        size = None
        sha256 = None
        errors.append(f"cannot fingerprint Spore binary: {type(err).__name__}: {err}")

    version_command = [str(resolved), "version"]
    try:
        version = subprocess.run(
            version_command,
            capture_output=True,
            check=False,
            timeout=10,
        )
        version_result = {
            "command": version_command,
            "exit_code": version.returncode,
            "timed_out": False,
            "stdout": bounded_process_output(version.stdout),
            "stderr": bounded_process_output(version.stderr),
        }
        if version.returncode != 0:
            errors.append(f"spore version exited {version.returncode}")
    except subprocess.TimeoutExpired as err:
        version_result = {
            "command": version_command,
            "exit_code": None,
            "timed_out": True,
            "stdout": bounded_process_output(err.stdout),
            "stderr": bounded_process_output(err.stderr),
        }
        errors.append("spore version timed out after 10 seconds")
    except OSError as err:
        version_result = {
            "command": version_command,
            "exit_code": None,
            "timed_out": False,
            "stdout": bounded_process_output(None),
            "stderr": bounded_process_output(None),
            "error": f"{type(err).__name__}: {err}",
        }
        errors.append(f"cannot execute spore version: {type(err).__name__}: {err}")

    return {
        "requested_path": str(path),
        "resolved_path": str(resolved),
        "size_bytes": size,
        "sha256": sha256,
        "version": version_result,
        "validation_errors": errors,
    }


def spore_binary_stability(
    before: dict[str, object],
    after: dict[str, object],
) -> dict[str, object]:
    before_version = before["version"]
    after_version = after["version"]
    assert isinstance(before_version, dict)
    assert isinstance(after_version, dict)
    fields = {
        "resolved_path": (before.get("resolved_path"), after.get("resolved_path")),
        "size_bytes": (before.get("size_bytes"), after.get("size_bytes")),
        "sha256": (before.get("sha256"), after.get("sha256")),
        "version_exit_code": (
            before_version.get("exit_code"),
            after_version.get("exit_code"),
        ),
        "version_stdout_sha256": (
            before_version.get("stdout", {}).get("sha256"),
            after_version.get("stdout", {}).get("sha256"),
        ),
        "version_stderr_sha256": (
            before_version.get("stderr", {}).get("sha256"),
            after_version.get("stderr", {}).get("sha256"),
        ),
    }
    changed = {
        name: {"before": values[0], "after": values[1]}
        for name, values in fields.items()
        if values[0] != values[1]
    }
    return {
        "stable": not changed,
        "changed_fields": changed,
    }


def host_environment() -> dict[str, object]:
    system = platform.system()
    architecture = platform.machine()
    kernel = platform.release()
    hostname = platform.node()
    stable_token: str | None = None
    descriptor_source = "hostname"
    machine_id = Path("/etc/machine-id")
    if machine_id.is_file():
        try:
            stable_token = machine_id.read_text(encoding="ascii").strip()
            descriptor_source = "/etc/machine-id"
        except OSError:
            pass
    elif system == "Darwin":
        try:
            ioreg = subprocess.run(
                ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                capture_output=True,
                check=False,
                timeout=5,
            )
            match = re.search(rb'"IOPlatformUUID"\s*=\s*"([^"]+)"', ioreg.stdout)
            if ioreg.returncode == 0 and match:
                stable_token = match.group(1).decode("ascii", errors="replace")
                descriptor_source = "IOPlatformUUID"
        except (OSError, subprocess.TimeoutExpired):
            pass
    if not stable_token:
        stable_token = hostname
    descriptor_payload = "\0".join(
        (system, architecture, stable_token or "unknown")
    ).encode()
    lowered_arch = architecture.lower()
    if system == "Darwin" and lowered_arch in ("arm64", "aarch64"):
        backend = "hvf"
        backend_basis = "Darwin arm64 paired builds use Hypervisor.framework"
    elif system == "Linux":
        backend = "kvm"
        backend_basis = "Linux paired builds use KVM"
    else:
        backend = "unknown"
        backend_basis = "no supported paired backend inferred from host OS/arch"
    return {
        "inferred_effective_backend": backend,
        "backend_inference_basis": backend_basis,
        "os": system,
        "architecture": architecture,
        "kernel_release": kernel,
        "stable_host_descriptor": (
            "sha256:" + hashlib.sha256(descriptor_payload).hexdigest()
        ),
        "stable_descriptor_source": descriptor_source,
        "kvm_device_present": Path("/dev/kvm").exists() if system == "Linux" else None,
    }


def git_command(root: Path, args: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        check=False,
    )


def hash_untracked_files(root: Path) -> tuple[str | None, int]:
    completed = git_command(
        root,
        ["ls-files", "--others", "--exclude-standard", "-z"],
    )
    if completed.returncode != 0:
        return None, 0
    paths = [path for path in completed.stdout.split(b"\0") if path]
    digest = hashlib.sha256()
    for raw_path in paths:
        digest.update(len(raw_path).to_bytes(8, "big"))
        digest.update(raw_path)
        path = root / os.fsdecode(raw_path)
        try:
            metadata = path.lstat()
            digest.update(metadata.st_mode.to_bytes(8, "big"))
            if stat.S_ISLNK(metadata.st_mode):
                payload = os.fsencode(os.readlink(path))
                digest.update(b"symlink\0")
                digest.update(len(payload).to_bytes(8, "big"))
                digest.update(payload)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                digest.update(b"special\0")
                digest.update(metadata.st_rdev.to_bytes(8, "big"))
                continue
            digest.update(b"file\0")
            size = metadata.st_size
            digest.update(size.to_bytes(8, "big"))
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
        except OSError as err:
            payload = f"{type(err).__name__}:{err.errno}".encode()
            digest.update(b"unreadable\0")
            digest.update(len(payload).to_bytes(8, "big"))
            digest.update(payload)
    return "sha256:" + digest.hexdigest(), len(paths)


def repository_identity(root: Path) -> dict[str, object]:
    head_result = git_command(root, ["rev-parse", "HEAD"])
    status_result = git_command(
        root,
        ["status", "--porcelain=v1", "--untracked-files=all"],
    )
    diff_result = git_command(root, ["diff", "--binary", "HEAD", "--"])
    head = (
        head_result.stdout.decode("ascii", errors="replace").strip()
        if head_result.returncode == 0
        else None
    )
    status = (
        status_result.stdout.decode("utf-8", errors="surrogateescape").splitlines()
        if status_result.returncode == 0
        else []
    )
    diff_hash = (
        "sha256:" + hashlib.sha256(diff_result.stdout).hexdigest()
        if diff_result.returncode == 0
        else None
    )
    untracked_hash, untracked_count = hash_untracked_files(root)
    identity = hashlib.sha256()
    for payload in (
        (head or "").encode(),
        status_result.stdout if status_result.returncode == 0 else b"",
        diff_result.stdout if diff_result.returncode == 0 else b"",
        (untracked_hash or "").encode(),
    ):
        identity.update(len(payload).to_bytes(8, "big"))
        identity.update(payload)
    return {
        "head": head,
        "dirty": bool(status),
        "status_porcelain_v1": status,
        "tracked_diff_sha256": diff_hash,
        "tracked_diff_bytes": len(diff_result.stdout) if diff_result.returncode == 0 else None,
        "untracked_content_sha256": untracked_hash,
        "untracked_file_count": untracked_count,
        "worktree_identity_sha256": "sha256:" + identity.hexdigest(),
    }


def prepare_identity_stability_gate(
    identities: list[dict[str, object]],
    complete_iterations: list[int],
) -> dict[str, object]:
    complete = set(complete_iterations)
    samples: list[dict[str, object]] = []
    for identity in identities:
        iteration = identity.get("iteration")
        records = identity.get("prepare_records")
        errors = identity.get("validation_errors")
        if iteration not in complete or errors or not isinstance(records, list):
            continue
        if len(records) != 1 or not isinstance(records[0], dict):
            continue
        record = records[0]
        samples.append(
            {
                "iteration": iteration,
                "step_key": record.get("step_key"),
                "child_index_digest": record.get("child_index_digest"),
                "producer_identity": record.get("producer_identity"),
            }
        )
    unique_step_keys = sorted(
        {str(sample["step_key"]) for sample in samples if sample["step_key"] is not None}
    )
    unique_children = sorted(
        {
            str(sample["child_index_digest"])
            for sample in samples
            if sample["child_index_digest"] is not None
        }
    )
    unique_producers = sorted(
        {
            str(sample["producer_identity"])
            for sample in samples
            if sample["producer_identity"] is not None
        }
    )
    stable = (
        len(unique_step_keys) == 1
        and len(unique_children) == 1
        and len(unique_producers) == 1
    )
    if samples and not stable:
        status = "fail"
    elif len(samples) < MIN_PAIRED_GATE_SAMPLES:
        status = "insufficient-samples"
    else:
        status = "pass"
    return {
        "status": status,
        "observed": {
            "samples": samples,
            "unique_step_keys": unique_step_keys,
            "unique_child_index_digests": unique_children,
            "unique_producer_identities": unique_producers,
        },
        "threshold": {
            "requirement": (
                "one stable PREPARE step key, child index digest, and producer "
                "identity across complete paired trials"
            )
        },
        "sample_count": len(samples),
        "required_samples": MIN_PAIRED_GATE_SAMPLES,
    }


def run_paired_matrix(args: argparse.Namespace, root: Path) -> tuple[dict[str, object], bool]:
    profile = args.paired_profile
    instrumented = profile == "instrumented"
    measurement_class = (
        "instrumented-engineering-control"
        if instrumented
        else "literal-default-path"
    )
    repo_root = Path(__file__).resolve().parents[2]
    requested_spore = args.spore.expanduser().resolve()
    checkout_spore = (repo_root / "zig-out/bin/spore").resolve()
    args.spore = checkout_spore
    raw_path = args.raw_output or root / f"paired-{profile}-raw.jsonl"
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_text("", encoding="utf-8")
    rows: list[dict[str, object]] = []
    setup_rows: list[dict[str, object]] = []
    verification_rows: list[dict[str, object]] = []
    trial_identities: list[dict[str, object]] = []
    matrix_errors: list[str] = []

    def record(row: dict[str, object]) -> None:
        with raw_path.open("a", encoding="utf-8") as raw:
            raw.write(json.dumps(row, sort_keys=True) + "\n")
        print(json.dumps(row, sort_keys=True), flush=True)

    host = host_environment()
    host_errors = (
        []
        if host["inferred_effective_backend"] in ("hvf", "kvm")
        else ["cannot infer a supported effective backend from the host"]
    )
    host_row = {
        "row_type": "setup",
        "profile": profile,
        "measurement_class": measurement_class,
        "iteration": 0,
        "lane": "provenance",
        "scenario": "host_environment",
        "measured": False,
        "host": host,
        "validation_errors": host_errors,
    }
    setup_rows.append(host_row)
    record(host_row)
    matrix_errors.extend(host_errors)

    binding_errors = []
    if requested_spore != checkout_spore:
        binding_errors.append(
            "paired release matrix requires --spore to resolve to "
            f"{checkout_spore}, got {requested_spore}"
        )
    binding_row = {
        "row_type": "setup",
        "profile": profile,
        "measurement_class": measurement_class,
        "iteration": 0,
        "lane": "provenance",
        "scenario": "checkout_spore_binding",
        "measured": False,
        "requested_spore": str(requested_spore),
        "required_checkout_spore": str(checkout_spore),
        "matches": not binding_errors,
        "validation_errors": binding_errors,
    }
    setup_rows.append(binding_row)
    record(binding_row)
    matrix_errors.extend(binding_errors)

    release_build = run_paired_command(
        args,
        command=[str(shutil.which("mise") or "mise"), "run", "build:release"],
        env=mode_env(os.environ, "native"),
        log_dir=root / profile / "provenance-logs",
        log_name="release-safe-build",
        row_type="setup",
        profile=profile,
        iteration=0,
        lane="provenance",
        scenario="checkout_release_safe_build_not_timed",
        measured=False,
        cwd=repo_root,
    )
    if release_build["exit_code"] != 0:
        release_build["validation_errors"] = [
            f"ReleaseSafe build exited {release_build['exit_code']}"
        ]
        matrix_errors.extend(release_build["validation_errors"])
    setup_rows.append(release_build)
    record(release_build)

    binary_identity_pre = spore_binary_identity(checkout_spore)
    binary_errors = list(binary_identity_pre["validation_errors"])
    binary_row: dict[str, object] = {
        "row_type": "setup",
        "profile": profile,
        "measurement_class": measurement_class,
        "iteration": 0,
        "lane": "provenance",
        "scenario": "measured_spore_binary_pre",
        "measured": False,
        "spore_binary": binary_identity_pre,
        "validation_errors": binary_errors,
    }
    setup_rows.append(binary_row)
    record(binary_row)
    matrix_errors.extend(binary_errors)
    repo_identity = repository_identity(repo_root)

    suffix = profile.replace("-", "")
    compact_ref = f"local/rootfs-capacity-paired-base-{suffix}:seed"
    seed = root / profile / "seed"
    shutil.rmtree(seed, ignore_errors=True)
    seed_cache = seed / "rootfs-cache"
    seed_runtime = seed / "runtime"
    seed_env = paired_env(seed_cache, seed_runtime, instrumented)
    if not matrix_errors:
        seed_row = run_paired_command(
            args,
            command=[
                str(args.spore),
                "run",
                "--image",
                PAIRED_BASE_IMAGE,
                "--pull=missing",
                "--commit",
                compact_ref,
                "--",
                "/bin/true",
            ],
            env=seed_env,
            log_dir=seed / "logs",
            log_name="setup-compact-seed",
            row_type="setup",
            profile=profile,
            iteration=0,
            lane="seed",
            scenario="compact_seed_setup_not_timed",
            measured=False,
        )
        if seed_row["exit_code"] != 0:
            seed_row["validation_errors"] = [
                f"compact seed setup exited {seed_row['exit_code']}"
            ]
            matrix_errors.append("compact seed setup failed")
        setup_rows.append(seed_row)
        record(seed_row)
    copy_bin = shutil.which("cp")
    if copy_bin is None:
        matrix_errors.append("cp is required to clone the exact compact seed cache")

    for iteration in range(1, args.iterations + 1):
        if matrix_errors:
            break
        trial = root / profile / f"trial-{iteration:02d}"
        shutil.rmtree(trial, ignore_errors=True)
        trial.mkdir(parents=True)
        pregrown_ref = f"local/rootfs-capacity-paired-pregrown-{suffix}:trial-{iteration}"
        compact_tag = f"local/rootfs-capacity-paired-compact-{suffix}:trial-{iteration}"
        control_tag = f"local/rootfs-capacity-paired-control-{suffix}:trial-{iteration}"
        compact_cache = trial / "compact-cache"
        control_cache = trial / "pregrown-control-cache"
        compact_runtime = trial / "compact-runtime"
        control_runtime = trial / "pregrown-control-runtime"
        compact_context = trial / "compact-context"
        control_context = trial / "pregrown-control-context"
        compact_env = paired_env(compact_cache, compact_runtime, instrumented)
        control_env = paired_env(control_cache, control_runtime, instrumented)
        setup_ok = True
        for lane, cache, env in (
            ("compact", compact_cache, compact_env),
            ("pregrown-control", control_cache, control_env),
        ):
            row = run_paired_command(
                args,
                command=[
                    str(copy_bin),
                    "-a",
                    str(seed_cache),
                    str(cache),
                ],
                env=env,
                log_dir=trial / "logs",
                log_name=f"setup-{lane}-cache-clone",
                row_type="setup",
                profile=profile,
                iteration=iteration,
                lane=lane,
                scenario="compact_seed_cache_clone_not_timed",
                measured=False,
            )
            if row["exit_code"] != 0:
                row["validation_errors"] = [f"compact cache clone exited {row['exit_code']}"]
                setup_ok = False
            setup_rows.append(row)
            record(row)

        if setup_ok:
            historical_context(compact_context, compact_ref, "version-one\n")
            historical_context(control_context, pregrown_ref, "version-one\n")
            row = run_paired_command(
                args,
                command=[
                    str(args.spore),
                    "run",
                    "--image",
                    compact_ref,
                    "--pull=never",
                    "--disk-size",
                    PAIRED_DISK_SIZE,
                    "--commit",
                    pregrown_ref,
                    "--",
                    "/bin/true",
                ],
                env=control_env,
                log_dir=trial / "logs",
                log_name="setup-pregrown-control",
                row_type="setup",
                profile=profile,
                iteration=iteration,
                lane="pregrown-control",
                scenario="pregrown_base_setup_not_timed",
                measured=False,
            )
            if row["exit_code"] != 0:
                row["validation_errors"] = [f"pre-grown control setup exited {row['exit_code']}"]
                setup_ok = False
            setup_rows.append(row)
            record(row)
        if not setup_ok:
            matrix_errors.append(f"trial {iteration}: setup failed")
            continue

        def measure(lane: str, scenario: str, no_cache: bool) -> dict[str, object]:
            context = compact_context if lane == "compact" else control_context
            tag = compact_tag if lane == "compact" else control_tag
            env = compact_env if lane == "compact" else control_env
            row = run_paired_command(
                args,
                command=paired_build_command(args, profile, context, tag, no_cache),
                env=env,
                log_dir=trial / "logs",
                log_name=scenario,
                row_type="measurement",
                profile=profile,
                iteration=iteration,
                lane=lane,
                scenario=scenario,
                measured=True,
            )
            row["validation_errors"] = validate_paired_measurement(row)
            rows.append(row)
            record(row)
            return row

        pair_order = ("compact", "pregrown-control")
        if iteration % 2 == 0:
            pair_order = tuple(reversed(pair_order))
        for lane in pair_order:
            measure(
                lane,
                "compact_cold" if lane == "compact" else "pregrown_cold_control",
                True,
            )
        control_conditioning: dict[str, object] | None = None
        for lane in pair_order:
            if lane == "compact":
                measure("compact", "shared_prepare_no_cache", True)
                continue
            control_conditioning = run_paired_command(
                args,
                command=paired_build_command(
                    args,
                    profile,
                    control_context,
                    control_tag,
                    True,
                ),
                env=control_env,
                log_dir=trial / "logs",
                log_name="pregrown-repeat-no-cache-conditioning",
                row_type="conditioning",
                profile=profile,
                iteration=iteration,
                lane="pregrown-control",
                scenario="pregrown_repeat_no_cache_conditioning_not_measured",
                measured=False,
            )
            if control_conditioning["exit_code"] != 0:
                control_conditioning["validation_errors"] = [
                    f"pre-grown conditioning build exited {control_conditioning['exit_code']}"
                ]
            elif control_conditioning.get("rootfs_index") is None:
                control_conditioning["validation_errors"] = [
                    "pre-grown conditioning build has no rootfs identity"
                ]
            setup_rows.append(control_conditioning)
            record(control_conditioning)
        if control_conditioning is None or control_conditioning["validation_errors"]:
            matrix_errors.append(f"trial {iteration}: paired conditioning failed")
            continue
        for lane in pair_order:
            measure(
                lane,
                "compact_warm" if lane == "compact" else "pregrown_warm_control",
                False,
            )
        (compact_context / "changing.txt").write_text("version-two\n", encoding="utf-8")
        (control_context / "changing.txt").write_text("version-two\n", encoding="utf-8")
        for lane in pair_order:
            measure(
                lane,
                (
                    "compact_incremental"
                    if lane == "compact"
                    else "pregrown_incremental_control"
                ),
                False,
            )

        for lane, tag, env in (
            ("compact", compact_tag, compact_env),
            ("pregrown-control", control_tag, control_env),
        ):
            row = run_paired_command(
                args,
                command=[
                    str(args.spore),
                    "run",
                    "--image",
                    tag,
                    "--pull=never",
                    "--",
                    "/bin/sh",
                    "-c",
                    'test "$(cat /work/stable.txt)" = stable '
                    '&& test "$(cat /work/result.txt)" = version-two',
                ],
                env=env,
                log_dir=trial / "logs",
                log_name=f"verify-{lane}",
                row_type="verification",
                profile=profile,
                iteration=iteration,
                lane=lane,
                scenario="runnable_output",
                measured=False,
            )
            if row["exit_code"] != 0:
                row["validation_errors"] = [f"runnable output exited {row['exit_code']}"]
            verification_rows.append(row)
            record(row)

        compact_base = find_local_image_identity(compact_cache, compact_ref)
        control_base = find_local_image_identity(control_cache, compact_ref)
        pregrown_base = find_local_image_identity(control_cache, pregrown_ref)
        prepare_records = find_prepare_records(compact_cache)
        control_prepare_records = find_prepare_records(control_cache)
        expected_target = 16 * 1024 * 1024 * 1024
        control_contract = {
            "description": PREGROWN_CONTROL_CONTRACT,
            "same_compact_parent": (
                compact_base is not None
                and control_base is not None
                and compact_base.get("index_digest")
                == control_base.get("index_digest")
            ),
            "same_target_geometry": (
                pregrown_base is not None
                and pregrown_base.get("logical_size") == expected_target
            ),
            "measured_build_has_no_prepare_record": len(control_prepare_records) == 0,
            "build_prepare_child_index": (
                prepare_records[0].get("child_index_digest")
                if len(prepare_records) == 1
                else None
            ),
            "independent_run_commit_index": (
                pregrown_base.get("index_digest") if pregrown_base else None
            ),
            "byte_identity_requirement": "not required and not evaluated",
        }
        identities: dict[str, object] = {
            "iteration": iteration,
            "compact_base": compact_base,
            "control_compact_base": control_base,
            "pregrown_base": pregrown_base,
            "prepare_records": prepare_records,
            "pregrown_control_prepare_records": control_prepare_records,
            "pregrown_control_contract": control_contract,
            "pregrown_conditioning_output": control_conditioning.get("rootfs_index"),
            "build_outputs": {
                str(row["scenario"]): row.get("rootfs_index")
                for row in rows
                if row["iteration"] == iteration and not row["validation_errors"]
            },
            "validation_errors": [],
        }
        identity_errors = identities["validation_errors"]
        assert isinstance(identity_errors, list)
        if compact_base is None or control_base is None or pregrown_base is None:
            identity_errors.append("missing local base identity metadata")
        if len(prepare_records) != 1:
            identity_errors.append(f"expected one PREPARE record, found {len(prepare_records)}")
        if compact_base and control_base:
            if compact_base.get("index_digest") != control_base.get("index_digest"):
                identity_errors.append("paired lanes did not start from the same compact parent")
        if compact_base and prepare_records:
            if prepare_records[0].get("parent_index_digest") != compact_base.get("index_digest"):
                identity_errors.append("PREPARE parent does not match the compact base")
        if prepare_records:
            prepare_record = prepare_records[0]
            if prepare_record.get("exact_target") != expected_target:
                identity_errors.append("PREPARE target is not the fixed 16 GiB capacity")
            producer = prepare_record.get("producer_identity")
            if not isinstance(producer, str) or not re.fullmatch(r"blake3:[0-9a-f]{64}", producer):
                identity_errors.append("PREPARE producer identity is missing or malformed")
        if not control_contract["same_target_geometry"]:
            identity_errors.append("pre-grown control does not have the fixed 16 GiB geometry")
        if not control_contract["measured_build_has_no_prepare_record"]:
            identity_errors.append("pre-grown control unexpectedly published a PREPARE record")
        iteration_rows = [row for row in rows if row["iteration"] == iteration]
        by_scenario = {str(row["scenario"]): row for row in iteration_rows}
        equal_groups = (
            ("shared_prepare_no_cache", "compact_warm"),
        )
        for group in equal_groups:
            values = {by_scenario[name].get("rootfs_index") for name in group}
            if len(values) != 1 or None in values:
                identity_errors.append(f"rootfs identity mismatch: {', '.join(group)}")
        if control_conditioning.get("rootfs_index") != by_scenario[
            "pregrown_warm_control"
        ].get("rootfs_index"):
            identity_errors.append(
                "pre-grown warm output does not match its conditioning build"
            )
        trial_identities.append(identities)
        record({"row_type": "identities", "profile": profile, **identities})

    binary_identity_post = spore_binary_identity(checkout_spore)
    binary_stability = spore_binary_stability(
        binary_identity_pre,
        binary_identity_post,
    )
    post_binary_errors = list(binary_identity_post["validation_errors"])
    if not binary_stability["stable"]:
        post_binary_errors.append("measured Spore binary changed during the matrix")
    post_binary_row = {
        "row_type": "verification",
        "profile": profile,
        "measurement_class": measurement_class,
        "iteration": 0,
        "lane": "provenance",
        "scenario": "measured_spore_binary_post",
        "measured": False,
        "spore_binary": binary_identity_post,
        "stability": binary_stability,
        "validation_errors": post_binary_errors,
    }
    verification_rows.append(post_binary_row)
    record(post_binary_row)
    matrix_errors.extend(post_binary_errors)

    valid_rows = [row for row in rows if not row["validation_errors"]]
    scenario_stats = {
        scenario: number_stats(
            [
                float(row["elapsed_ms"])
                for row in valid_rows
                if row["scenario"] == scenario
            ]
        )
        for scenario in PAIRED_SCENARIOS
    }
    delta_pairs = {
        "cold_minus_pregrown_control": ("compact_cold", "pregrown_cold_control"),
        "warm_minus_pregrown_control": ("compact_warm", "pregrown_warm_control"),
        "incremental_minus_pregrown_control": (
            "compact_incremental",
            "pregrown_incremental_control",
        ),
        "cold_minus_shared_prepare": ("compact_cold", "shared_prepare_no_cache"),
    }
    paired_deltas: list[dict[str, object]] = []
    for iteration in range(1, args.iterations + 1):
        iteration_rows = {
            str(row["scenario"]): row
            for row in valid_rows
            if row["iteration"] == iteration
        }
        for name, (left, right) in delta_pairs.items():
            if left not in iteration_rows or right not in iteration_rows:
                continue
            left_ms = float(iteration_rows[left]["elapsed_ms"])
            right_ms = float(iteration_rows[right]["elapsed_ms"])
            paired_deltas.append(
                {
                    "iteration": iteration,
                    "name": name,
                    "left": left,
                    "right": right,
                    "left_ms": left_ms,
                    "right_ms": right_ms,
                    "delta_ms": round(left_ms - right_ms, 3),
                    "delta_pct_of_control": (
                        round((left_ms - right_ms) * 100 / right_ms, 3)
                        if right_ms != 0
                        else None
                    ),
                }
            )
    paired_delta_stats = {
        name: delta_stats(paired_deltas, name) for name in delta_pairs
    }
    failed = bool(matrix_errors)
    failed = failed or any(row["validation_errors"] for row in rows)
    failed = failed or any(row["validation_errors"] for row in setup_rows)
    failed = failed or any(row["validation_errors"] for row in verification_rows)
    failed = failed or any(identity["validation_errors"] for identity in trial_identities)
    complete_iterations = sorted(
        iteration
        for iteration in range(1, args.iterations + 1)
        if {
            str(row["scenario"])
            for row in valid_rows
            if row["iteration"] == iteration
        }
        == set(PAIRED_SCENARIOS)
    )
    eligibility_reasons: list[str] = []
    if instrumented:
        eligibility_reasons.append("instrumented profile is not default-path evidence")
    if failed:
        eligibility_reasons.append("one or more matrix validations failed")
    if len(complete_iterations) < 5:
        eligibility_reasons.append("fewer than five complete paired iterations")
    performance_gate_eligible = not eligibility_reasons
    default_path_gates: dict[str, object] | None = None
    instrumented_gates: dict[str, object] | None = None
    if not instrumented:
        cold_delta = paired_delta_stats["cold_minus_pregrown_control"]
        warm_delta = paired_delta_stats["warm_minus_pregrown_control"]
        incremental_delta = paired_delta_stats[
            "incremental_minus_pregrown_control"
        ]
        default_gates = {
            "cold_median_paired_delta": upper_bound_gate(
                observed_name="median_paired_delta_ms",
                observed=cold_delta["median_ms"],
                threshold=150,
                unit="ms",
                samples=int(cold_delta["samples"]),
            ),
            "warm_median_paired_percentage_delta": upper_bound_gate(
                observed_name="median_paired_delta_pct",
                observed=warm_delta["median_delta_pct"],
                threshold=20,
                unit="percent",
                samples=int(warm_delta["samples"]),
                details={
                    "paired_observations": warm_delta["paired_observations"],
                },
            ),
            "incremental_median_paired_percentage_delta": upper_bound_gate(
                observed_name="median_paired_delta_pct",
                observed=incremental_delta["median_delta_pct"],
                threshold=20,
                unit="percent",
                samples=int(incremental_delta["samples"]),
                details={
                    "paired_observations": incremental_delta[
                        "paired_observations"
                    ],
                },
            ),
        }
        default_path_gates = {
            "status": aggregate_gate_status(default_gates),
            "gates": default_gates,
        }
    else:
        preparation_stats = number_stats(
            [
                float(row["prepare_ms"])
                for row in valid_rows
                if row["scenario"] == "compact_cold"
                and row["prepare_ms"] is not None
            ]
        )
        warm_boot_pairs: list[dict[str, int]] = []
        for iteration in range(1, args.iterations + 1):
            iteration_rows = {
                str(row["scenario"]): row
                for row in rows
                if row["iteration"] == iteration
            }
            compact = iteration_rows.get("compact_warm")
            control = iteration_rows.get("pregrown_warm_control")
            if compact is None or control is None:
                continue
            compact_counts = compact.get("counts")
            control_counts = control.get("counts")
            if not isinstance(compact_counts, dict) or not isinstance(control_counts, dict):
                continue
            compact_boots = compact_counts.get("boot_count")
            control_boots = control_counts.get("boot_count")
            if not isinstance(compact_boots, int) or not isinstance(control_boots, int):
                continue
            warm_boot_pairs.append(
                {
                    "iteration": iteration,
                    "compact": compact_boots,
                    "pregrown_control": control_boots,
                }
            )
        max_warm_boots = max(
            (
                max(pair["compact"], pair["pregrown_control"])
                for pair in warm_boot_pairs
            ),
            default=None,
        )
        instrumented_gate_results = {
            "prepare_p95": upper_bound_gate(
                observed_name="p95_prepare_ms",
                observed=preparation_stats["p95_ms"],
                threshold=250,
                unit="ms",
                samples=int(preparation_stats["samples"]),
                details={"median_prepare_ms": preparation_stats["median_ms"]},
            ),
            "warm_zero_boot": upper_bound_gate(
                observed_name="max_boot_count",
                observed=max_warm_boots,
                threshold=0,
                unit="boots_per_build",
                samples=len(warm_boot_pairs),
                details={"paired_boot_counts": warm_boot_pairs},
            ),
        }
        instrumented_gates = {
            "status": aggregate_gate_status(instrumented_gate_results),
            "gates": instrumented_gate_results,
        }
    gate_evaluation = {
        "evaluated_profile": profile,
        "required_samples": MIN_PAIRED_GATE_SAMPLES,
        "default_path": default_path_gates,
        "instrumented": instrumented_gates,
    }
    prepare_stability = prepare_identity_stability_gate(
        trial_identities,
        complete_iterations,
    )
    active_profile_gates = instrumented_gates if instrumented else default_path_gates
    assert active_profile_gates is not None
    aggregate_status = aggregate_gate_status(
        {
            "profile_performance": {
                "status": active_profile_gates["status"],
            },
            "prepare_identity_stability": prepare_stability,
        }
    )
    gate_evaluation.update(
        {
            "prepare_identity_stability": prepare_stability,
            "status": aggregate_status,
            "exit_policy": "nonzero unless validation succeeds and aggregate gate status is pass",
        }
    )
    failed = failed or aggregate_status != "pass"
    gate_evaluation["command_exit_nonzero"] = failed
    spore_binary_summary = {
        "required_checkout_path": str(checkout_spore),
        "requested_path": str(requested_spore),
        "checkout_binding_matches": requested_spore == checkout_spore,
        "release_safe_build": release_build,
        "pre_matrix": binary_identity_pre,
        "post_matrix": binary_identity_post,
        "stability": binary_stability,
    }
    summary = {
        "schema": "spore-build-rootfs-capacity-paired-v1",
        "profile": profile,
        "measurement_class": measurement_class,
        "performance_gate_eligible": performance_gate_eligible,
        "performance_gate_ineligible_reasons": eligibility_reasons,
        "complete_paired_iterations": complete_iterations,
        "gate_evaluation": gate_evaluation,
        "repository_commit": repo_identity["head"],
        "repository_identity": repo_identity,
        "repository_identity_captured_at": "post-release-build-matrix-start",
        "spore_binary": spore_binary_summary,
        "host": host,
        "base_image": PAIRED_BASE_IMAGE,
        "pregrown_control_disk_size": PAIRED_DISK_SIZE,
        "pregrown_control_contract": PREGROWN_CONTROL_CONTRACT,
        "fixture": "ARG/ENV/WORKDIR/two-COPY/one-RUN",
        "iterations": args.iterations,
        "work_dir": str(root),
        "raw_jsonl": str(raw_path),
        "scenario_stats": scenario_stats,
        "paired_deltas": paired_deltas,
        "paired_delta_stats": paired_delta_stats,
        "rows": rows,
        "setup_rows": setup_rows,
        "verification_rows": verification_rows,
        "identities": trial_identities,
        "validation_errors": matrix_errors,
    }
    return summary, failed


def main() -> int:
    args = parse_args()
    if not args.paired_matrix and not args.spore.is_file():
        print(f"error: spore binary not found: {args.spore}", file=sys.stderr)
        return 2
    owned_root = args.work_dir is None
    root = args.work_dir or Path(tempfile.mkdtemp(prefix="spore-build-rootfs-capacity."))
    root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    failed = False
    try:
        if args.paired_matrix:
            summary, failed = run_paired_matrix(args, root)
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(
                    json.dumps(summary, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            print(
                json.dumps(
                    {
                        "schema": summary["schema"],
                        "profile": summary["profile"],
                        "performance_gate_eligible": summary[
                            "performance_gate_eligible"
                        ],
                        "performance_gate_ineligible_reasons": summary[
                            "performance_gate_ineligible_reasons"
                        ],
                        "complete_paired_iterations": summary[
                            "complete_paired_iterations"
                        ],
                        "gate_evaluation": summary["gate_evaluation"],
                        "spore_binary": summary["spore_binary"],
                        "host": summary["host"],
                        "pregrown_control_contract": summary[
                            "pregrown_control_contract"
                        ],
                        "scenario_stats": summary["scenario_stats"],
                        "paired_delta_stats": summary["paired_delta_stats"],
                        "raw_jsonl": summary["raw_jsonl"],
                        "output": str(args.output) if args.output else None,
                        "failed": failed,
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
            return 1 if failed else 0
        for mode in args.modes:
            for iteration in range(1, args.iterations + 1):
                row = run_trial(args, root, mode, iteration)
                row["validation_errors"] = validate_trial(row)
                rows.append(row)
                print(json.dumps(row, sort_keys=True), flush=True)
        valid_rows = [row for row in rows if not row["validation_errors"]]
        summary = {
            "schema": "spore-build-rootfs-capacity-v1",
            "work_dir": str(root),
            "rows": rows,
            "valid_sample_counts": {
                mode: sum(row["mode"] == mode for row in valid_rows)
                for mode in args.modes
            },
            "invalid_sample_counts": {
                mode: sum(
                    row["mode"] == mode and bool(row["validation_errors"])
                    for row in rows
                )
                for mode in args.modes
            },
            "medians_ms": {
                mode: median_or_none(
                    [int(row["elapsed_ms"]) for row in valid_rows if row["mode"] == mode]
                )
                for mode in args.modes
            },
            "p95_ms": {
                mode: nearest_rank_or_none(
                    [int(row["elapsed_ms"]) for row in valid_rows if row["mode"] == mode],
                    0.95,
                )
                for mode in args.modes
            },
            "medians_prepare_ms": {
                mode: median_or_none(
                    [
                        int(row["prepare_ms"])
                        for row in valid_rows
                        if row["mode"] == mode and row["prepare_ms"] is not None
                    ]
                )
                for mode in args.modes
            },
            "p95_prepare_ms": {
                mode: nearest_rank_or_none(
                    [
                        int(row["prepare_ms"])
                        for row in valid_rows
                        if row["mode"] == mode and row["prepare_ms"] is not None
                    ],
                    0.95,
                )
                for mode in args.modes
            },
            "medians_peak_rss_bytes": {
                mode: median_or_none(
                    [
                        int(row["peak_rss_bytes"])
                        for row in valid_rows
                        if row["mode"] == mode and row["peak_rss_bytes"] is not None
                    ]
                )
                for mode in args.modes
            },
        }
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 1 if any(row["validation_errors"] for row in rows) else 0
    finally:
        if (
            owned_root
            and not args.paired_matrix
            and not args.keep
            and not failed
            and not any(row.get("validation_errors") for row in rows)
        ):
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
