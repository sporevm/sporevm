#!/usr/bin/env python3
"""Run isolated Spore build rootfs-growth probes.

This is an engineering harness, not a product configuration surface. It keeps
the P0 negative controls and isolated preparation probes out of `spore build`
help while producing machine-readable evidence from the real guest/kernel.
"""

from __future__ import annotations

import argparse
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


MODES = ("native", "checksum-noinit", "checksum-lazy", "force-fallback")
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


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spore", type=Path, default=root / "zig-out/bin/spore")
    parser.add_argument("--mode", choices=MODES, action="append", dest="modes")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--idle-ms", type=int, default=6000)
    parser.add_argument("--measure-rss", action="store_true")
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


def main() -> int:
    args = parse_args()
    if not args.spore.is_file():
        print(f"error: spore binary not found: {args.spore}", file=sys.stderr)
        return 2
    owned_root = args.work_dir is None
    root = args.work_dir or Path(tempfile.mkdtemp(prefix="spore-build-rootfs-capacity."))
    root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    try:
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
        if owned_root and not args.keep and not any(row.get("validation_errors") for row in rows):
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
