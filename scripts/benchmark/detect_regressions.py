#!/usr/bin/env python3
"""Detect SporeVM benchmark regressions against trailing run history."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fnmatch
import json
import os
from pathlib import Path
import re
import socket
import statistics
import sys
import tempfile
from typing import Any, Union


LATENCY_WARN = 0.30
THROUGHPUT_WARN = 0.10
TIMING_ABSOLUTE_DELTA_MS = 50.0
DEFAULT_TRAILING_WINDOW = 5
MISSING_HISTORY_NOTE = (
    "scheduled benchmark guardrail requires at least one compatible prior run for this host; "
    "likely causes are artifact fetch failure, a host_id change, or a fresh pipeline. "
    "Bootstrap intentionally with SPOREVM_BENCHMARK_RESET or a commit message line like "
    "'spore-benchmark-reset: all'."
)

TIME_RE = re.compile(r"^(real|user|sys)\s+([0-9]+(?:\.[0-9]+)?)$")
ROOTFS_DIGEST_RE = re.compile(r"^blake3:[0-9a-f]{64}$")
DF_ENTRY_RE = re.compile(r"^\s*(?P<label>[^:]+):\s+(?P<count>[0-9]+)\s+entries,\s+(?P<size>[0-9]+(?:\.[0-9]+)?)\s+(?P<unit>[A-Za-z]+)$")
DF_SIZE_RE = re.compile(r"^\s*(?P<label>Known logical data):\s+(?P<size>[0-9]+(?:\.[0-9]+)?)\s+(?P<unit>[A-Za-z]+)")

TIMING_FIELDS = {
    "tti_ms",
    "elapsed_ms",
    "wall_clock_ms",
    "time_to_first_ready_ms",
    "fork_ms_per_child",
    "pull_ms",
    "resume_exec_ms",
    "vsock_connect_ms",
    "exec_response_ms",
}
IGNORED_NUMERIC_FIELDS = {
    "iteration",
    "status",
    "count",
    "success_count",
    "version",
    "schema_version",
    "exit_code",
    "vcpus",
    "memory_bytes",
    "real_ms",
    "user_ms",
    "sys_ms",
    "created_at",
}
COUNTER_PARTS = (
    "bytes",
    "chunks",
    "objects",
    "entries",
    "blocks",
    "workers",
    "count",
    "logical_data",
)
THROUGHPUT_BENCHMARKS = {
    "cold_import",
    "writable_rootfs",
}
ABSOLUTE_MAX_KEYS = ("max", "absolute_max", "ceiling")
MetricValue = Union[float, str]


@dataclass
class BenchmarkRun:
    path: Path
    run_id: str
    created_at: str
    host_id: str
    config: dict[str, Any]
    rows: list[dict[str, Any]]


@dataclass
class MetricSeries:
    metric_id: str
    metric_class: str
    values: list[MetricValue]


@dataclass
class Verdict:
    metric_id: str
    metric_class: str
    verdict: str
    current: MetricValue
    baseline: MetricValue | None
    delta: float | None
    delta_pct: float | None
    threshold: str
    history_runs: int
    note: str = ""


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"not found: {path}")
    except json.JSONDecodeError as err:
        die(f"invalid JSON {path}: {err}")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        die(f"not found: {path}")
    for line_number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as err:
            die(f"invalid JSONL {path}:{line_number}: {err}")
        if isinstance(value, dict):
            rows.append(value)
    return rows


def normalize(value: str) -> str:
    out = []
    for char in value:
        if char.isalnum():
            out.append(char.lower())
        else:
            out.append("_")
    return re.sub(r"_+", "_", "".join(out)).strip("_")


def current_hostname() -> str:
    return os.environ.get("SPOREVM_BENCHMARK_HOST_ID") or os.environ.get("BUILDKITE_AGENT_NAME") or socket.gethostname()


def run_from_results(path: Path, config_override: dict[str, Any] | None = None) -> BenchmarkRun:
    rows = load_jsonl(path)
    config_path = path.with_name("config.json")
    config = config_override if isinstance(config_override, dict) else {}
    if not config and config_path.exists():
        raw_config = load_json(config_path)
        config = raw_config if isinstance(raw_config, dict) else {}
    first = rows[0] if rows else {}
    run_id = str(config.get("run_id") or first.get("run_id") or path.parent.name)
    created_at = str(config.get("created_at") or first.get("created_at") or run_id)
    host_id = str(config.get("host_id") or first.get("host_id") or current_hostname())
    return BenchmarkRun(path=path, run_id=run_id, created_at=created_at, host_id=host_id, config=config, rows=rows)


def run_from_summary(path: Path) -> BenchmarkRun:
    summary = load_json(path)
    if not isinstance(summary, dict):
        die(f"summary must be a JSON object: {path}")
    config = summary.get("config") if isinstance(summary.get("config"), dict) else {}
    raw_results = summary.get("raw_results")
    candidates: list[Path] = []
    if isinstance(raw_results, str):
        candidates.append(Path(raw_results))
    run_id = str(summary.get("run_id") or config.get("run_id") or "")
    if run_id:
        candidates.append(path.parent / run_id / "results.jsonl")
    candidates.append(path.with_name("results.jsonl"))
    for candidate in candidates:
        if candidate.exists():
            return run_from_results(candidate, config_override=config)
    die(f"could not locate raw results for summary: {path}")


def parse_size(value: str, unit: str) -> int:
    units = {
        "B": 1,
        "KB": 1000,
        "MB": 1000**2,
        "GB": 1000**3,
        "TB": 1000**4,
        "KiB": 1024,
        "MiB": 1024**2,
        "GiB": 1024**3,
        "TiB": 1024**4,
    }
    return int(float(value) * units.get(unit, 1))


def parse_legacy_time_log(path: Path) -> dict[str, Any]:
    row: dict[str, Any] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        match = TIME_RE.match(stripped)
        if match:
            row[f"{match.group(1)}_ms"] = float(match.group(2)) * 1000.0
            continue
        if not stripped.startswith("{"):
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("event") == "exit" and isinstance(event.get("timings"), dict):
            for key, value in event["timings"].items():
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    row[str(key)] = float(value)
    if "real_ms" in row:
        row["tti_ms"] = row["real_ms"]
    return row


def parse_system_df(path: Path) -> dict[str, Any]:
    row: dict[str, Any] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        entry = DF_ENTRY_RE.match(line)
        if entry:
            label = normalize(entry.group("label"))
            row[f"rootfs_df_{label}_entries"] = int(entry.group("count"))
            row[f"rootfs_df_{label}_bytes"] = parse_size(entry.group("size"), entry.group("unit"))
            continue
        size = DF_SIZE_RE.match(line)
        if size:
            label = normalize(size.group("label"))
            row[f"rootfs_df_{label}_bytes"] = parse_size(size.group("size"), size.group("unit"))
    return row


def run_from_legacy_dir(path: Path) -> BenchmarkRun | None:
    rows: list[dict[str, Any]] = []
    warm_logs = sorted(path.glob("warm-run-true*.log"))
    for index, log in enumerate(warm_logs):
        parsed = parse_legacy_time_log(log)
        if parsed:
            rows.append({
                "benchmark": "legacy_warm_image",
                "mode": "run_image",
                "iteration": index,
                "success": True,
                "source_path": str(log),
                **parsed,
            })
    cold_log = path / "cold-run-true.log"
    if cold_log.exists():
        parsed = parse_legacy_time_log(cold_log)
        if parsed:
            rows.append({
                "benchmark": "legacy_cold_image",
                "mode": "run_image",
                "iteration": 0,
                "success": True,
                "source_path": str(cold_log),
                **parsed,
            })
    df_log = path / "system-df-rootfs.log"
    if df_log.exists():
        parsed = parse_system_df(df_log)
        if parsed:
            rows.append({
                "benchmark": "legacy_rootfs_cache",
                "mode": "system_df",
                "success": True,
                "source_path": str(df_log),
                **parsed,
            })
    if not rows:
        return None
    config = {"host_id": current_hostname(), "legacy_benchmark_dir": str(path)}
    return BenchmarkRun(path=path, run_id=path.name, created_at=path.name, host_id=current_hostname(), config=config, rows=rows)


def load_runs(path: Path, *, recursive: bool) -> list[BenchmarkRun]:
    path = path.expanduser()
    if path.is_file():
        if path.name == "results.jsonl":
            return [run_from_results(path)]
        if path.suffix == ".json":
            return [run_from_summary(path)]
        die(f"unsupported benchmark input file: {path}")
    if not path.exists():
        die(f"not found: {path}")
    direct_results = path / "results.jsonl"
    if direct_results.exists():
        return [run_from_results(direct_results)]
    legacy = run_from_legacy_dir(path)
    if legacy is not None:
        return [legacy]
    if not recursive:
        return []
    runs: list[BenchmarkRun] = []
    seen: set[Path] = set()
    for result in sorted(path.rglob("results.jsonl")):
        resolved = result.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        runs.append(run_from_results(result))
    for child in sorted(path.iterdir()):
        if child.is_dir():
            legacy_child = run_from_legacy_dir(child)
            if legacy_child is not None:
                runs.append(legacy_child)
    return runs


def number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def flatten_numbers(value: Any, prefix: str = "") -> dict[str, float]:
    if isinstance(value, dict):
        out: dict[str, float] = {}
        for key, child in value.items():
            key_part = normalize(str(key))
            child_prefix = f"{prefix}_{key_part}" if prefix else key_part
            out.update(flatten_numbers(child, child_prefix))
        return out
    raw = number(value)
    return {prefix: raw} if raw is not None else {}


def digest_metric_class(field: str, value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    if field == "rootfs_import_index_digest" and ROOTFS_DIGEST_RE.match(value):
        return "digest"
    return None


def metric_class(run: BenchmarkRun, benchmark: str, mode: str, field: str) -> str | None:
    if field in IGNORED_NUMERIC_FIELDS or field.endswith("_status"):
        return None
    if field == "success_rate":
        return "success_rate"
    metric_id = f"{benchmark}/{mode}/{field}"
    explicitly_bounded_timing = field.endswith("_ms") and metric_absolute_max(run, metric_id) is not None
    if field in TIMING_FIELDS or explicitly_bounded_timing:
        if benchmark in THROUGHPUT_BENCHMARKS or field.startswith("rootfs_profile_") or field == "wall_clock_ms":
            return "throughput"
        return "latency"
    if any(part in field for part in COUNTER_PARTS):
        return "counter"
    return None


def extract_metrics(run: BenchmarkRun) -> dict[str, MetricSeries]:
    metrics: dict[str, MetricSeries] = {}
    success_groups: dict[tuple[str, str], list[bool]] = {}
    for row in run.rows:
        success = row.get("success")
        if isinstance(success, bool):
            benchmark = str(row.get("benchmark") or "unknown")
            mode = str(row.get("mode") or "unknown")
            if not mode.endswith("_batch"):
                success_groups.setdefault((benchmark, mode), []).append(success)
        if row.get("success") is False:
            continue
        benchmark = str(row.get("benchmark") or "unknown")
        mode = str(row.get("mode") or "unknown")
        flattened: dict[str, float] = {}
        for key, value in row.items():
            if key in ("source_row", "samples"):
                continue
            if isinstance(value, dict):
                flattened.update(flatten_numbers(value, normalize(str(key))))
            else:
                raw = number(value)
                if raw is not None:
                    flattened[normalize(str(key))] = raw
                else:
                    field = normalize(str(key))
                    cls = digest_metric_class(field, value)
                    if cls is None:
                        continue
                    metric_id = f"{benchmark}/{mode}/{field}"
                    series = metrics.get(metric_id)
                    if series is None:
                        series = MetricSeries(metric_id=metric_id, metric_class=cls, values=[])
                        metrics[metric_id] = series
                    series.values.append(str(value))
        for field, value in flattened.items():
            cls = metric_class(run, benchmark, mode, field)
            if cls is None:
                continue
            metric_id = f"{benchmark}/{mode}/{field}"
            series = metrics.get(metric_id)
            if series is None:
                series = MetricSeries(metric_id=metric_id, metric_class=cls, values=[])
                metrics[metric_id] = series
            series.values.append(value)
    for (benchmark, mode), values in success_groups.items():
        if not values:
            continue
        metric_id = f"{benchmark}/{mode}/success_rate"
        metrics[metric_id] = MetricSeries(
            metric_id=metric_id,
            metric_class="success_rate",
            values=[sum(1 for value in values if value) / len(values)],
        )
    return metrics


def target_matches(target: str, metric_id: str) -> bool:
    target = target.strip()
    if target in ("", "*", "all"):
        return True
    benchmark_mode = "/".join(metric_id.split("/")[:2])
    return fnmatch.fnmatch(metric_id, target) or fnmatch.fnmatch(benchmark_mode, target)


def reset_targets(run: BenchmarkRun) -> list[str]:
    reset = run.config.get("benchmark_history_reset")
    if not isinstance(reset, dict):
        return []
    targets = reset.get("targets")
    if isinstance(targets, list):
        return [str(target) for target in targets]
    return []


def has_explicit_reset(run: BenchmarkRun, metric_id: str) -> bool:
    return any(target_matches(target, metric_id) for target in reset_targets(run))


def expectation_marker(run: BenchmarkRun, metric_id: str) -> str | None:
    expectations = run.config.get("benchmark_expectations")
    if not isinstance(expectations, dict):
        return None
    metrics = expectations.get("metrics")
    if not isinstance(metrics, dict):
        return None
    matched: list[tuple[str, Any]] = []
    for pattern, entry in metrics.items():
        if target_matches(str(pattern), metric_id):
            if isinstance(entry, dict) and "reset" in entry:
                matched.append((str(pattern), entry.get("reset")))
    if not matched:
        return None
    return json.dumps(sorted(matched, key=lambda item: item[0]), sort_keys=True, separators=(",", ":"))


def metric_absolute_max(run: BenchmarkRun, metric_id: str) -> float | None:
    expectations = run.config.get("benchmark_expectations")
    if not isinstance(expectations, dict):
        return None
    metrics = expectations.get("metrics")
    if not isinstance(metrics, dict):
        return None
    limits: list[float] = []
    for pattern, entry in metrics.items():
        if not target_matches(str(pattern), metric_id):
            continue
        if isinstance(entry, bool):
            continue
        if isinstance(entry, (int, float)):
            limits.append(float(entry))
            continue
        if not isinstance(entry, dict):
            continue
        for key in ABSOLUTE_MAX_KEYS:
            value = entry.get(key)
            if isinstance(value, bool):
                continue
            if isinstance(value, (int, float)):
                limits.append(float(value))
                break
    if not limits:
        return None
    return min(limits)


def filtered_history(
    current: BenchmarkRun,
    metric_id: str,
    history: list[tuple[BenchmarkRun, dict[str, MetricSeries]]],
    *,
    ignore_host: bool,
    trailing_window: int,
) -> list[tuple[BenchmarkRun, MetricSeries]]:
    candidates: list[tuple[BenchmarkRun, dict[str, MetricSeries]]] = []
    for run, metrics in history:
        if run.run_id == current.run_id and run.path == current.path:
            continue
        if not ignore_host and run.host_id != current.host_id:
            continue
        if metric_id not in metrics:
            continue
        candidates.append((run, metrics))

    last_reset = -1
    for index, (run, _) in enumerate(candidates):
        if has_explicit_reset(run, metric_id):
            last_reset = index
    if last_reset >= 0:
        candidates = candidates[last_reset:]

    current_marker = expectation_marker(current, metric_id)
    compatible: list[tuple[BenchmarkRun, MetricSeries]] = []
    for run, metrics in candidates:
        marker = expectation_marker(run, metric_id)
        if current_marker is not None:
            if marker != current_marker:
                continue
        elif marker is not None:
            continue
        compatible.append((run, metrics[metric_id]))
    return compatible[-trailing_window:]


def compare_counter(current: float, baseline: float) -> tuple[str, float | None, str]:
    delta = current - baseline
    if delta == 0:
        return "ok", None, "any change"
    if baseline == 0:
        return "fail", None, "any change; fail on nonzero from zero"
    ratio = current / baseline
    if current > baseline and ratio >= 2.0:
        return "fail", ((current - baseline) / baseline) * 100.0, "any change; fail at >=2x"
    return "warn", ((current - baseline) / baseline) * 100.0, "any change; fail at >=2x"


def compare_timing(current: float, baseline: float, warn_threshold: float) -> tuple[str, float | None, str]:
    fail_threshold = warn_threshold * 2.0
    threshold = (
        f"warn >{warn_threshold * 100:.0f}%, fail >{fail_threshold * 100:.0f}%, "
        f"and delta >= {TIMING_ABSOLUTE_DELTA_MS:.0f}ms"
    )
    delta = current - baseline
    if delta < TIMING_ABSOLUTE_DELTA_MS:
        if baseline > 0:
            return "ok", (delta / baseline) * 100.0, threshold
        return "ok", None, threshold
    if baseline <= 0:
        return "fail", None, threshold
    delta_pct = (delta / baseline) * 100.0
    ratio = delta / baseline
    if ratio >= fail_threshold:
        return "fail", delta_pct, threshold
    if ratio >= warn_threshold:
        return "warn", delta_pct, threshold
    return "ok", delta_pct, threshold


def compare_success_rate(current: float, baseline: float) -> tuple[str, float | None, str]:
    threshold = "fail on any decrease"
    delta_pct = (current - baseline) * 100.0
    if current >= baseline:
        return "ok", delta_pct, threshold
    return "fail", delta_pct, threshold


def compare_digest(current_values: list[MetricValue], baseline_values: list[MetricValue]) -> tuple[str, str | None, str, str]:
    threshold = "fail on any digest change"
    current_set = sorted({str(value) for value in current_values})
    baseline_set = sorted({str(value) for value in baseline_values})
    current_display = ",".join(current_set)
    baseline_display = ",".join(baseline_set) if baseline_set else None
    if current_set == baseline_set and len(current_set) == 1:
        return "ok", baseline_display, threshold, ""
    if len(current_set) != 1:
        return "fail", baseline_display, threshold, "current run produced multiple rootfs index digests"
    if len(baseline_set) != 1:
        return "fail", baseline_display, threshold, "history contains multiple rootfs index digests"
    return "fail", baseline_display, threshold, "rootfs index digest changed"


def numeric_values(values: list[MetricValue]) -> list[float]:
    return [float(value) for value in values if isinstance(value, (int, float)) and not isinstance(value, bool)]


def current_stat(series: MetricSeries) -> MetricValue:
    if series.metric_class == "digest":
        return ",".join(sorted({str(value) for value in series.values}))
    values = numeric_values(series.values)
    return float(statistics.median(values))


def history_baseline(metric_class: str, baseline_runs: list[tuple[BenchmarkRun, MetricSeries]]) -> MetricValue:
    if metric_class == "digest":
        return ",".join(sorted({str(value) for _, hist_series in baseline_runs for value in hist_series.values}))
    if metric_class == "success_rate":
        return max(max(numeric_values(hist_series.values)) for _, hist_series in baseline_runs)
    run_medians = [float(statistics.median(numeric_values(hist_series.values))) for _, hist_series in baseline_runs]
    return float(statistics.median(run_medians))


def compatible_history_runs(current: BenchmarkRun, history_runs: list[BenchmarkRun], *, ignore_host: bool) -> list[BenchmarkRun]:
    return [
        run
        for run in history_runs
        if not (run.run_id == current.run_id and run.path == current.path)
        and (ignore_host or run.host_id == current.host_id)
    ]


def evaluate(args: argparse.Namespace) -> tuple[list[Verdict], dict[str, Any]]:
    current_runs = load_runs(args.current, recursive=False)
    if len(current_runs) != 1:
        die(f"current input must resolve to exactly one run, found {len(current_runs)}: {args.current}")
    current = current_runs[0]
    current_metrics = extract_metrics(current)

    history_runs: list[BenchmarkRun] = []
    for path in args.history or []:
        history_runs.extend(load_runs(path, recursive=False))
    for path in args.history_dir or []:
        history_runs.extend(load_runs(path, recursive=True))
    history_runs = sorted(history_runs, key=lambda run: (run.created_at, run.run_id, str(run.path)))
    history = [(run, extract_metrics(run)) for run in history_runs]
    compatible_runs = compatible_history_runs(current, history_runs, ignore_host=args.ignore_host)
    required_history_missing = bool(args.require_history and not compatible_runs and not reset_targets(current))

    verdicts: list[Verdict] = []
    for metric_id, series in sorted(current_metrics.items()):
        current_value = current_stat(series)
        absolute_max = metric_absolute_max(current, metric_id)
        ceiling_failed = (
            absolute_max is not None
            and series.metric_class not in ("success_rate", "digest")
            and isinstance(current_value, (int, float))
            and current_value > absolute_max
        )
        if has_explicit_reset(current, metric_id):
            if ceiling_failed:
                verdicts.append(Verdict(
                    metric_id=metric_id,
                    metric_class=series.metric_class,
                    verdict="fail",
                    current=current_value,
                    baseline=None,
                    delta=None,
                    delta_pct=None,
                    threshold=f"absolute max <= {fmt_value(absolute_max, metric_id)}",
                    history_runs=0,
                    note="current run has an intentional history reset but exceeds the durable expectation ceiling",
                ))
                continue
            verdicts.append(Verdict(
                metric_id=metric_id,
                metric_class=series.metric_class,
                verdict="reset",
                current=current_value,
                baseline=None,
                delta=None,
                delta_pct=None,
                threshold="-",
                history_runs=0,
                note="current run carries an intentional history reset",
            ))
            continue
        baseline_runs = filtered_history(
            current,
            metric_id,
            history,
            ignore_host=args.ignore_host,
            trailing_window=args.trailing_window,
        )
        if not baseline_runs:
            if ceiling_failed:
                verdicts.append(Verdict(
                    metric_id=metric_id,
                    metric_class=series.metric_class,
                    verdict="fail",
                    current=current_value,
                    baseline=None,
                    delta=None,
                    delta_pct=None,
                    threshold=f"absolute max <= {fmt_value(absolute_max, metric_id)}",
                    history_runs=0,
                    note="current value exceeds the durable expectation ceiling",
                ))
                continue
            verdicts.append(Verdict(
                metric_id=metric_id,
                metric_class=series.metric_class,
                verdict="no_history",
                current=current_value,
                baseline=None,
                delta=None,
                delta_pct=None,
                threshold="-",
                history_runs=0,
            ))
            continue
        baseline = history_baseline(series.metric_class, baseline_runs)
        if ceiling_failed:
            verdict, delta_pct, threshold = "fail", ((current_value - baseline) / baseline) * 100.0 if baseline else None, f"absolute max <= {fmt_value(absolute_max, metric_id)}"
            note = "current value exceeds the durable expectation ceiling"
        elif series.metric_class == "digest":
            baseline_values = [value for _, hist_series in baseline_runs for value in hist_series.values]
            verdict, baseline_display, threshold, note = compare_digest(series.values, baseline_values)
            baseline = baseline_display
            delta_pct = None
        elif series.metric_class == "counter":
            assert isinstance(current_value, (int, float)) and isinstance(baseline, (int, float))
            verdict, delta_pct, threshold = compare_counter(current_value, baseline)
            note = ""
        elif series.metric_class == "success_rate":
            assert isinstance(current_value, (int, float)) and isinstance(baseline, (int, float))
            verdict, delta_pct, threshold = compare_success_rate(current_value, baseline)
            note = ""
        else:
            assert isinstance(current_value, (int, float)) and isinstance(baseline, (int, float))
            warn = THROUGHPUT_WARN if series.metric_class == "throughput" else LATENCY_WARN
            confirmed = False
            if len(baseline_runs) >= 2:
                prior_baseline = history_baseline(series.metric_class, baseline_runs[:-1])
                prior_value = current_stat(baseline_runs[-1][1])
                assert isinstance(prior_baseline, (int, float)) and isinstance(prior_value, (int, float))
                prior_verdict, _, _ = compare_timing(prior_value, prior_baseline, warn)
                if prior_verdict == "fail":
                    baseline = prior_baseline
                    confirmed = True
            verdict, delta_pct, threshold = compare_timing(current_value, baseline, warn)
            if verdict == "fail" and not confirmed:
                verdict = "warn"
                note = "first fail-tier relative breach; a second consecutive breach is required"
            else:
                note = ""
        delta = current_value - baseline if isinstance(current_value, (int, float)) and isinstance(baseline, (int, float)) else None
        verdicts.append(Verdict(
            metric_id=metric_id,
            metric_class=series.metric_class,
            verdict=verdict,
            current=current_value,
            baseline=baseline,
            delta=delta,
            delta_pct=delta_pct,
            threshold=threshold,
            history_runs=len(baseline_runs),
            note=note,
        ))

    failure_count = sum(1 for item in verdicts if item.verdict == "fail")
    if required_history_missing:
        failure_count += 1
    summary = {
        "current_run": current.run_id,
        "current_host": current.host_id,
        "history_runs_loaded": len(history_runs),
        "compatible_history_runs": len(compatible_runs),
        "metrics": len(verdicts),
        "failures": failure_count,
        "warnings": sum(1 for item in verdicts if item.verdict == "warn"),
        "resets": sum(1 for item in verdicts if item.verdict == "reset"),
        "no_history": sum(1 for item in verdicts if item.verdict == "no_history"),
        "required_history_missing": required_history_missing,
        "required_history_note": MISSING_HISTORY_NOTE if required_history_missing else "",
        "style": "error" if any(item.verdict == "fail" for item in verdicts) else "warning" if any(item.verdict == "warn" for item in verdicts) else "info",
    }
    if required_history_missing:
        summary["style"] = "error"
    return verdicts, summary


def fmt_value(value: MetricValue | None, metric_id: str) -> str:
    if value is None:
        return "-"
    if isinstance(value, str):
        if metric_id.endswith("digest") and len(value) > 40:
            return f"{value[:22]}...{value[-8:]}"
        return value
    if metric_id.endswith("/success_rate") or metric_id.endswith("_success_rate"):
        return f"{value * 100:.1f}%"
    if metric_id.endswith("_ms"):
        if abs(value) >= 1000:
            return f"{value / 1000:.2f}s"
        return f"{value:.1f}ms"
    if abs(value) >= 1024 * 1024 and ("bytes" in metric_id or metric_id.endswith("_bytes")):
        return f"{value / (1024 * 1024):.1f}MiB"
    if value == round(value):
        return str(int(value))
    return f"{value:.3f}"


def fmt_delta(verdict: Verdict) -> str:
    if verdict.delta is None:
        return "-"
    if verdict.metric_id.endswith("/success_rate") or verdict.metric_id.endswith("_success_rate"):
        return f"{verdict.delta * 100:+.1f}pp"
    if verdict.delta_pct is None:
        return fmt_value(verdict.delta, verdict.metric_id)
    return f"{fmt_value(verdict.delta, verdict.metric_id)} ({verdict.delta_pct:+.1f}%)"


def render_markdown(verdicts: list[Verdict], summary: dict[str, Any]) -> str:
    lines = [
        "# SporeVM benchmark regression report",
        "",
        f"- Current run: `{summary['current_run']}`",
        f"- Host: `{summary['current_host']}`",
        f"- History runs loaded: {summary['history_runs_loaded']}",
        f"- Compatible same-host history runs: {summary['compatible_history_runs']}",
        f"- Verdicts: {summary['failures']} fail, {summary['warnings']} warn, {summary['resets']} reset, {summary['no_history']} without comparable history",
        "",
    ]
    if summary.get("required_history_missing"):
        lines.extend([
            "**Scheduled history is required, but no compatible prior runs were found for this host.**",
            "",
            MISSING_HISTORY_NOTE,
            "",
        ])
    if not verdicts:
        lines.append("_No comparable benchmark metrics were found._")
        return "\n".join(lines) + "\n"

    priority = {"fail": 0, "warn": 1, "reset": 2, "no_history": 3, "ok": 4}
    rows = sorted(verdicts, key=lambda item: (priority.get(item.verdict, 9), item.metric_id))
    lines.extend([
        "| Verdict | Metric | Class | Current | Baseline | Delta | History runs | Threshold | Note |",
        "|---|---|---|---:|---:|---:|---:|---|---|",
    ])
    for item in rows:
        lines.append(
            f"| {item.verdict} | `{item.metric_id}` | {item.metric_class} | "
            f"{fmt_value(item.current, item.metric_id)} | {fmt_value(item.baseline, item.metric_id)} | "
            f"{fmt_delta(item)} | {item.history_runs} | {item.threshold} | {item.note} |"
        )
    lines.append("")
    lines.append("_Timing and counter values are run medians compared with the median of trailing run medians; success_rate uses the trailing best rate. Relative timing failures require two consecutive fail-tier breaches. Digest metrics fail on any change, and counters warn on any unexplained change._")
    return "\n".join(lines) + "\n"


def write_outputs(args: argparse.Namespace, verdicts: list[Verdict], summary: dict[str, Any]) -> None:
    markdown = render_markdown(verdicts, summary)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(markdown, encoding="utf-8")
    else:
        print(markdown, end="")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps({
                "summary": summary,
                "verdicts": [item.__dict__ for item in verdicts],
            }, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def write_fixture_run(root: Path, name: str, rows: list[dict[str, Any]], config: dict[str, Any] | None = None) -> Path:
    run_dir = root / name
    run_dir.mkdir(parents=True, exist_ok=True)
    full_config = {"run_id": name, "created_at": name, "host_id": "test-host", **(config or {})}
    (run_dir / "config.json").write_text(json.dumps(full_config, sort_keys=True) + "\n", encoding="utf-8")
    with (run_dir / "results.jsonl").open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps({"run_id": name, "host_id": "test-host", "success": True, **row}, sort_keys=True) + "\n")
    return run_dir


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp_raw:
        tmp = Path(tmp_raw)
        current = write_fixture_run(tmp, "current-empty", [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 100}])
        args = parse_args([str(current / "results.jsonl")])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0
        assert any(item.verdict == "no_history" for item in verdicts)

        hist = write_fixture_run(tmp, "hist", [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 100}])
        warn = write_fixture_run(tmp, "current-warn", [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 155}])
        args = parse_args([str(warn / "results.jsonl"), "--history", str(hist)])
        verdicts, summary = evaluate(args)
        assert summary["warnings"] == 1 and summary["failures"] == 0
        assert next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms").verdict == "warn"

        fail = write_fixture_run(tmp, "current-fail", [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 170}])
        args = parse_args([str(fail / "results.jsonl"), "--history", str(hist)])
        verdicts, summary = evaluate(args)
        fail_item = next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms")
        assert summary["failures"] == 0 and fail_item.verdict == "warn"
        assert "second consecutive breach" in fail_item.note

        confirmed_hist = write_fixture_run(
            tmp,
            "hist-fail-tier",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 170}],
        )
        confirmed = write_fixture_run(
            tmp,
            "current-confirmed-fail",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 175}],
        )
        args = parse_args([
            str(confirmed / "results.jsonl"),
            "--history", str(hist),
            "--history", str(confirmed_hist),
        ])
        verdicts, summary = evaluate(args)
        confirmed_item = next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms")
        assert summary["failures"] == 1 and confirmed_item.verdict == "fail"
        assert confirmed_item.baseline == 100.0

        small_delta = write_fixture_run(
            tmp,
            "current-small-delta",
            [{"benchmark": "distribution_tti", "mode": "sequential", "pull_ms": 1}],
        )
        zero_hist = write_fixture_run(
            tmp,
            "hist-zero",
            [{"benchmark": "distribution_tti", "mode": "sequential", "pull_ms": 0}],
        )
        args = parse_args([str(small_delta / "results.jsonl"), "--history", str(zero_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0 and summary["warnings"] == 0
        assert next(item for item in verdicts if item.metric_id.endswith("/pull_ms")).verdict == "ok"

        median_current = write_fixture_run(
            tmp,
            "current-median",
            [
                {"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 80},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 155},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 160},
            ],
        )
        args = parse_args([str(median_current / "results.jsonl"), "--history", str(hist)])
        verdicts, _ = evaluate(args)
        median_item = next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms")
        assert median_item.current == 155.0 and median_item.verdict == "warn"

        ceiling_expectations = {"version": 1, "metrics": {"warm_spore_tti/sequential/tti_ms": {"max": 120}}}
        ceiling = write_fixture_run(
            tmp,
            "current-ceiling",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 121}],
            {"benchmark_expectations": ceiling_expectations},
        )
        args = parse_args([str(ceiling / "results.jsonl")])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 1
        assert next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms").note.endswith("ceiling")

        ceiling_uses_history = write_fixture_run(
            tmp,
            "current-ceiling-uses-history",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 155}],
            {"benchmark_expectations": {"version": 1, "metrics": {"warm_spore_tti/sequential/tti_ms": {"max": 200}}}},
        )
        args = parse_args([str(ceiling_uses_history / "results.jsonl"), "--history", str(hist)])
        verdicts, summary = evaluate(args)
        ceiling_history_item = next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms")
        assert ceiling_history_item.verdict == "warn"
        assert ceiling_history_item.history_runs == 1

        args = parse_args([str(current / "results.jsonl"), "--require-history"])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 1
        assert summary["required_history_missing"] is True
        reset_no_history = write_fixture_run(
            tmp,
            "current-require-history-reset",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 100}],
            {"benchmark_history_reset": {"source": "self-test", "targets": ["all"]}},
        )
        args = parse_args([str(reset_no_history / "results.jsonl"), "--require-history"])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0
        assert summary["required_history_missing"] is False

        success_hist = write_fixture_run(
            tmp,
            "success-hist",
            [
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 0, "tti_ms": 100, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 1, "tti_ms": 101, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 2, "tti_ms": 102, "success": True},
            ],
        )
        success_fail = write_fixture_run(
            tmp,
            "success-fail",
            [
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 0, "tti_ms": 100, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 1, "tti_ms": 101, "success": False},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 2, "tti_ms": 102, "success": False},
            ],
        )
        args = parse_args([str(success_fail / "results.jsonl"), "--history", str(success_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] >= 1
        assert next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/success_rate").verdict == "fail"

        partial_success_hist = write_fixture_run(
            tmp,
            "partial-success-hist",
            [
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 0, "tti_ms": 100, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 1, "tti_ms": 101, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 2, "tti_ms": 102, "success": False},
            ],
        )
        partial_success_drop = write_fixture_run(
            tmp,
            "partial-success-drop",
            [
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 0, "tti_ms": 100, "success": True},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 1, "tti_ms": 101, "success": False},
                {"benchmark": "warm_spore_tti", "mode": "sequential", "iteration": 2, "tti_ms": 102, "success": False},
            ],
        )
        args = parse_args([str(partial_success_drop / "results.jsonl"), "--history", str(partial_success_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] >= 1
        assert next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/success_rate").verdict == "fail"

        counter = write_fixture_run(
            tmp,
            "current-counter",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_profile_rootfs_cas_inline_objects_written": 11}],
        )
        counter_hist = write_fixture_run(
            tmp,
            "counter-hist",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_profile_rootfs_cas_inline_objects_written": 10}],
        )
        args = parse_args([str(counter / "results.jsonl"), "--history", str(counter_hist)])
        verdicts, summary = evaluate(args)
        assert summary["warnings"] == 1

        digest_a = "blake3:" + ("a" * 64)
        digest_b = "blake3:" + ("b" * 64)
        digest_hist = write_fixture_run(
            tmp,
            "digest-hist",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_import_index_digest": digest_a}],
        )
        digest_same = write_fixture_run(
            tmp,
            "digest-same",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_import_index_digest": digest_a}],
        )
        args = parse_args([str(digest_same / "results.jsonl"), "--history", str(digest_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0
        assert next(item for item in verdicts if item.metric_id == "cold_import/synthetic_tar/rootfs_import_index_digest").verdict == "ok"
        digest_changed = write_fixture_run(
            tmp,
            "digest-changed",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_import_index_digest": digest_b}],
        )
        args = parse_args([str(digest_changed / "results.jsonl"), "--history", str(digest_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 1
        changed_item = next(item for item in verdicts if item.metric_id == "cold_import/synthetic_tar/rootfs_import_index_digest")
        assert changed_item.verdict == "fail"
        assert changed_item.metric_class == "digest"
        digest_reset = write_fixture_run(
            tmp,
            "digest-reset",
            [{"benchmark": "cold_import", "mode": "synthetic_tar", "rootfs_import_index_digest": digest_b}],
            {"benchmark_history_reset": {"source": "self-test", "targets": ["cold_import/synthetic_tar/rootfs_import_index_digest"]}},
        )
        args = parse_args([str(digest_reset / "results.jsonl"), "--history", str(digest_hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0
        assert next(item for item in verdicts if item.metric_id == "cold_import/synthetic_tar/rootfs_import_index_digest").verdict == "reset"

        diagnostic_phase = write_fixture_run(
            tmp,
            "current-diagnostic-phase",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "guest_listen_ms": 5000}],
        )
        diagnostic_phase_hist = write_fixture_run(
            tmp,
            "diagnostic-phase-hist",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "guest_listen_ms": 1}],
        )
        args = parse_args([str(diagnostic_phase / "results.jsonl"), "--history", str(diagnostic_phase_hist)])
        verdicts, summary = evaluate(args)
        assert summary["metrics"] == 1
        assert all(not item.metric_id.endswith("/guest_listen_ms") for item in verdicts)

        explicitly_bounded_phase = write_fixture_run(
            tmp,
            "current-explicitly-bounded-phase",
            [{"benchmark": "writable_rootfs", "mode": "package:sealed-layer-append", "rootfs_profile_native_ext4_emit_ms": 122}],
            {
                "benchmark_expectations": {
                    "version": 1,
                    "metrics": {
                        "writable_rootfs/package:sealed-layer-append/rootfs_profile_native_ext4_emit_ms": {"max": 120}
                    },
                }
            },
        )
        args = parse_args([str(explicitly_bounded_phase / "results.jsonl")])
        verdicts, summary = evaluate(args)
        bounded_item = next(item for item in verdicts if item.metric_id.endswith("/rootfs_profile_native_ext4_emit_ms"))
        assert summary["failures"] == 1
        assert bounded_item.metric_class == "throughput" and bounded_item.verdict == "fail"

        expectations = {"version": 1, "metrics": {"warm_spore_tti/sequential/tti_ms": {"reset": "fixture-reset"}}}
        reset = write_fixture_run(
            tmp,
            "current-reset",
            [{"benchmark": "warm_spore_tti", "mode": "sequential", "tti_ms": 300}],
            {"benchmark_expectations": expectations},
        )
        args = parse_args([str(reset / "results.jsonl"), "--history", str(hist)])
        verdicts, summary = evaluate(args)
        assert summary["failures"] == 0 and summary["warnings"] == 0
        assert next(item for item in verdicts if item.metric_id == "warm_spore_tti/sequential/tti_ms").verdict == "no_history"
    print("self-test ok")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path, nargs="?", help="Current benchmark summary JSON, results JSONL, or run directory")
    parser.add_argument("--history", type=Path, action="append", help="Prior run summary JSON, results JSONL, or run directory")
    parser.add_argument("--history-dir", type=Path, action="append", help="Directory to recursively scan for prior benchmark runs")
    parser.add_argument("--trailing-window", type=int, default=DEFAULT_TRAILING_WINDOW)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--ignore-host", action="store_true", help="Compare history from any host")
    parser.add_argument("--require-history", action="store_true", help="Fail when no compatible same-host history run is available")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    if args.current is None:
        die("current benchmark input is required")
    if args.trailing_window <= 0:
        die("--trailing-window must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    verdicts, summary = evaluate(args)
    write_outputs(args, verdicts, summary)
    return 1 if summary["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
