#!/usr/bin/env python3
"""Export SporeVM benchmark summaries as append-only dashboard data."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


EXPORT_VERSION = "1.0"
DEFAULT_OUTPUT_DIR = Path("zig-cache/sporevm-benchmarks/site")
DEFAULT_MAX_RUNS = 500
JS_GLOBAL = "window.SPOREVM_BENCHMARK_DATA"

LABELS = {
    "cold_tti": "Cold TTI",
    "warm_spore_tti": "Warm Spore TTI",
    "distribution_tti": "Distribution TTI",
    "writable_rootfs": "Writable Rootfs",
    "memory_throughput": "Memory Throughput",
}

RUNNER_LABELS = {
    "cleanroom-mac": "macOS",
    "cleanroom-linux-arm64": "Linux ARM64",
}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"file not found: {path}")
    except json.JSONDecodeError as err:
        die(f"invalid JSON {path}: {err}")
    if not isinstance(value, dict):
        die(f"expected JSON object: {path}")
    return value


def load_history(path: Path | None) -> dict[str, object]:
    if path is None or not path.exists():
        return {"version": EXPORT_VERSION, "suite": "sporevm", "runs": []}
    history = load_json(path)
    runs = history.get("runs")
    if not isinstance(runs, list):
        die(f"history runs must be an array: {path}")
    return history


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_js(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True)
    path.write_text(f"{JS_GLOBAL} = {payload};\n", encoding="utf-8")


def git_value(args: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            ["git", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


def command_value(args: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


def env_or_git(name: str, git_args: list[str]) -> str | None:
    value = os.environ.get(name)
    return value if value else git_value(git_args)


def commit_metadata() -> dict[str, object]:
    return {
        "sha": env_or_git("BUILDKITE_COMMIT", ["rev-parse", "HEAD"]),
        "branch": env_or_git("BUILDKITE_BRANCH", ["rev-parse", "--abbrev-ref", "HEAD"]),
        "message": env_or_git("BUILDKITE_MESSAGE", ["log", "-1", "--pretty=%s"]),
        "url": os.environ.get("BUILDKITE_BUILD_URL"),
    }


def runner_metadata(config: dict[str, object]) -> dict[str, object]:
    return {
        "backend": config.get("backend"),
        "profile": config.get("profile"),
        "build_url": os.environ.get("BUILDKITE_BUILD_URL"),
        "build_number": os.environ.get("BUILDKITE_BUILD_NUMBER"),
        "job_id": os.environ.get("BUILDKITE_JOB_ID"),
        "pipeline": os.environ.get("BUILDKITE_PIPELINE_SLUG"),
        "agent_name": os.environ.get("BUILDKITE_AGENT_NAME"),
        "queue": os.environ.get("BUILDKITE_AGENT_META_DATA_QUEUE") or os.environ.get("BUILDKITE_AGENT_QUEUE"),
    }


def linux_mem_total_bytes() -> int | None:
    meminfo = Path("/proc/meminfo")
    if not meminfo.exists():
        return None
    for line in meminfo.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("MemTotal:"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    return int(parts[1]) * 1024
                except ValueError:
                    return None
    return None


def mem_total_bytes() -> int | None:
    value = command_value(["sysctl", "-n", "hw.memsize"])
    if value and value.isdigit():
        return int(value)
    return linux_mem_total_bytes()


def cpu_model() -> str | None:
    value = command_value(["sysctl", "-n", "machdep.cpu.brand_string"])
    if value:
        return value
    cpuinfo = Path("/proc/cpuinfo")
    if not cpuinfo.exists():
        return None
    for line in cpuinfo.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        if key.strip() in ("model name", "Hardware", "Processor"):
            value = raw.strip()
            if value:
                return value
    return None


def host_metadata() -> dict[str, object]:
    uname = os.uname()
    disk = shutil.disk_usage(Path.cwd())
    try:
        loadavg = list(os.getloadavg())
    except OSError:
        loadavg = None
    return {
        "os": uname.sysname,
        "arch": uname.machine,
        "kernel": uname.release,
        "cpu_model": cpu_model(),
        "cpu_count": os.cpu_count(),
        "mem_total_bytes": mem_total_bytes(),
        "loadavg": loadavg,
        "disk_total_bytes": disk.total,
        "disk_free_bytes": disk.free,
    }


def number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) else None


def metric_value(result: dict[str, object]) -> float | None:
    tti = result.get("tti_ms")
    if isinstance(tti, dict):
        return number(tti.get("median"))
    return number(result.get("value"))


def benchmark_label(benchmark: str, mode: str) -> str:
    return f"{LABELS.get(benchmark, benchmark.replace('_', ' ').title())} / {mode}"


def export_result(result: dict[str, object]) -> dict[str, object] | None:
    benchmark = str(result.get("benchmark", ""))
    mode = str(result.get("mode", ""))
    value = metric_value(result)
    if not benchmark or not mode or value is None:
        return None
    stats = result.get("tti_ms") if isinstance(result.get("tti_ms"), dict) else {}
    samples = result.get("samples") if isinstance(result.get("samples"), list) else None
    numeric_samples = [
        sample for sample in samples if isinstance(sample, (int, float)) and not isinstance(sample, bool)
    ] if samples is not None else None
    exported = {
        "name": f"{benchmark}/{mode}",
        "benchmark": benchmark,
        "mode": mode,
        "label": benchmark_label(benchmark, mode),
        "unit": "ms",
        "lower_is_better": True,
        "value": value,
        "stats": stats,
        "count": len(numeric_samples) if numeric_samples is not None else result.get("count"),
        "success_count": result.get("success_count"),
        "success_rate": result.get("success_rate"),
        "wall_clock_ms": result.get("wall_clock_ms"),
        "time_to_first_ready_ms": result.get("time_to_first_ready_ms"),
        "composite_score": result.get("composite_score"),
    }
    if numeric_samples is not None:
        exported["samples"] = numeric_samples
    phase_metrics = result.get("phase_metrics")
    if isinstance(phase_metrics, dict):
        exported["phase_metrics"] = phase_metrics
    return exported


def export_run(summary: dict[str, object], source: Path) -> dict[str, object]:
    config = summary.get("config") if isinstance(summary.get("config"), dict) else {}
    raw_results = summary.get("results") if isinstance(summary.get("results"), list) else []
    results = []
    for raw_result in raw_results:
        if not isinstance(raw_result, dict):
            continue
        result = export_result(raw_result)
        if result is not None:
            results.append(result)
    run_id = str(summary.get("run_id") or config.get("run_id") or source.stem)
    return {
        "run_id": run_id,
        "generated_at": summary.get("generated_at") or config.get("created_at") or utc_now(),
        "source_summary": str(source),
        "commit": commit_metadata(),
        "runner": runner_metadata(config),
        "host": host_metadata(),
        "config": {
            "profile": config.get("profile"),
            "backend": config.get("backend"),
            "memory": config.get("memory"),
            "image": config.get("image"),
            "requested_image": config.get("requested_image"),
            "command": config.get("command"),
            "platform": config.get("platform"),
        },
        "results": results,
    }


def run_sort_key(run: dict[str, object]) -> tuple[str, str]:
    return (str(run.get("generated_at") or ""), str(run.get("run_id") or ""))


def merge_runs(runs: list[object], new_run: dict[str, object], max_runs: int) -> list[dict[str, object]]:
    merged: dict[str, dict[str, object]] = {}
    for run in runs:
        if isinstance(run, dict) and run.get("run_id"):
            merged[str(run["run_id"])] = run
    merged[str(new_run["run_id"])] = new_run
    ordered = sorted(merged.values(), key=run_sort_key)
    return ordered[-max_runs:]


def build_series(runs: list[dict[str, object]]) -> list[dict[str, object]]:
    series: dict[str, dict[str, object]] = {}
    for run in runs:
        runner = run.get("runner") if isinstance(run.get("runner"), dict) else {}
        commit = run.get("commit") if isinstance(run.get("commit"), dict) else {}
        runner_key = str(runner.get("queue") or "")
        runner_label = RUNNER_LABELS.get(runner_key, runner_key)
        for raw_result in run.get("results", []):
            if not isinstance(raw_result, dict):
                continue
            name = str(raw_result.get("name") or "")
            value = number(raw_result.get("value"))
            if not name or value is None:
                continue
            stats = raw_result.get("stats") if isinstance(raw_result.get("stats"), dict) else {}
            phase_metrics = raw_result.get("phase_metrics") if isinstance(raw_result.get("phase_metrics"), dict) else {}
            phase_values = {
                key: metrics.get("median")
                for key, metrics in phase_metrics.items()
                if isinstance(metrics, dict) and metrics.get("median") is not None
            }
            series_name = f"{name}@{runner_key}" if runner_key else name
            label = raw_result.get("label")
            if runner_label:
                label = f"{label} / {runner_label}"
            item = series.setdefault(
                series_name,
                {
                    "name": series_name,
                    "result_name": name,
                    "benchmark": raw_result.get("benchmark"),
                    "mode": raw_result.get("mode"),
                    "label": label,
                    "unit": raw_result.get("unit"),
                    "lower_is_better": raw_result.get("lower_is_better"),
                    "runner": {"queue": runner_key} if runner_key else {},
                    "points": [],
                },
            )
            point = {
                "run_id": run.get("run_id"),
                "generated_at": run.get("generated_at"),
                "commit": commit.get("sha"),
                "branch": commit.get("branch"),
                "build_number": runner.get("build_number"),
                "value": value,
                "p95": stats.get("p95"),
                "p99": stats.get("p99"),
                "success_rate": raw_result.get("success_rate"),
            }
            if phase_values:
                point["phase_values"] = phase_values
            item["points"].append(point)
    return sorted(series.values(), key=lambda item: str(item.get("name")))


def export(args: argparse.Namespace) -> dict[str, object]:
    summary = load_json(args.summary)
    json_out = args.json_out or args.output_dir / "data.json"
    js_out = args.js_out or args.output_dir / "data.js"
    history_path = args.history or (json_out if json_out.exists() else None)
    history = load_history(history_path)
    runs = merge_runs(history.get("runs", []), export_run(summary, args.summary), args.max_runs)
    data = {
        "version": EXPORT_VERSION,
        "suite": "sporevm",
        "updated_at": utc_now(),
        "runs": runs,
        "series": build_series(runs),
    }
    write_json(json_out, data)
    write_js(js_out, data)
    print(f"benchmark data exported: json={json_out} js={js_out} runs={len(runs)}")
    return data


def self_test() -> None:
    summary = {
        "run_id": "run-1",
        "generated_at": "2026-06-26T00:00:00Z",
        "config": {
            "profile": "ci",
            "backend": "hvf",
            "memory": "auto",
            "image": "node@sha256:abc",
            "command": ["node", "-v"],
            "platform": "linux/arm64",
        },
        "results": [
            {
                "benchmark": "cold_tti",
                "mode": "sequential",
                "count": 4,
                "success_count": 3,
                "success_rate": 0.75,
                "samples": [121, 123, 130],
                "tti_ms": {"median": 123.0, "p95": 130.0, "p99": 131.0},
                "wall_clock_ms": 400,
                "time_to_first_ready_ms": 125,
                "composite_score": 98.0,
                "phase_metrics": {
                    "vsock_connect_ms": {"median": 5.0, "p95": 6.0, "p99": 7.0},
                    "exec_response_ms": {"median": 8.0, "p95": 9.0, "p99": 10.0},
                },
            }
        ],
    }
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        summary_path = root / "summary.json"
        write_json(summary_path, summary)
        args = argparse.Namespace(
            summary=summary_path,
            output_dir=root,
            json_out=root / "data.json",
            js_out=root / "data.js",
            history=None,
            max_runs=10,
        )
        data = export(args)
        assert len(data["runs"]) == 1
        assert data["runs"][0]["host"]["os"]
        assert data["runs"][0]["results"][0]["samples"] == [121, 123, 130]
        assert data["runs"][0]["results"][0]["count"] == 3
        assert data["runs"][0]["results"][0]["success_rate"] == 0.75
        assert data["runs"][0]["results"][0]["phase_metrics"]["vsock_connect_ms"]["median"] == 5.0
        assert data["series"][0]["points"][0]["value"] == 123.0
        assert data["series"][0]["points"][0]["p95"] == 130.0
        assert data["series"][0]["points"][0]["p99"] == 131.0
        assert data["series"][0]["points"][0]["phase_values"]["exec_response_ms"] == 8.0
        partitioned = build_series([
            {"run_id": "mac", "generated_at": "2026-06-26T00:00:00Z", "runner": {"queue": "cleanroom-mac"}, "results": data["runs"][0]["results"]},
            {"run_id": "linux", "generated_at": "2026-06-26T00:01:00Z", "runner": {"queue": "cleanroom-linux-arm64"}, "results": data["runs"][0]["results"]},
        ])
        assert len(partitioned) == 2
        assert {item["label"] for item in partitioned} == {"Cold TTI / sequential / macOS", "Cold TTI / sequential / Linux ARM64"}
        summary["results"][0]["tti_ms"]["median"] = 111.0
        write_json(summary_path, summary)
        data = export(args)
        assert len(data["runs"]) == 1
        assert data["series"][0]["points"][0]["value"] == 111.0
        js = (root / "data.js").read_text(encoding="utf-8")
        assert js.startswith(f"{JS_GLOBAL} = ")
    print("self-test ok")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path, nargs="?", help="SporeVM benchmark summary JSON")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--history", type=Path, help="Existing exported data.json to append to")
    parser.add_argument("--json-out", type=Path, help="Output data.json path")
    parser.add_argument("--js-out", type=Path, help="Output data.js path")
    parser.add_argument("--max-runs", type=int, default=DEFAULT_MAX_RUNS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    if args.summary is None:
        die("summary is required unless --self-test is set")
    if args.max_runs <= 0:
        die("--max-runs must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
    else:
        export(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
