#!/usr/bin/env python3
"""Compare SporeVM restore-to-vsock-reply timing with Substrate snapshot data."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request
import uuid


DEFAULT_MEMORY_MIB = (2048, 4096, 8192, 16384)
SUBSTRATE_SERIES = ("substrate-mmap", "substrate-uffd", "fc-file", "chv")
RESTORE_SOURCE_RE = re.compile(r"run --from memory restore source=(?P<source>\S+) reason=(?P<reason>\S+)")
RESTORE_METRICS_RE = re.compile(r"(?:kvm|hvf) restore metrics: (?P<fields>.+)")
EXEC_PROBE_TIMING_RE = re.compile(r"run exec probe timing: (?P<fields>.+)")
GUEST_TIMING_RE = re.compile(r"vsock host stream guest timing: timing (?P<fields>.+)")


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
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin" and machine == "arm64":
        return "hvf"
    if system == "Linux" and machine in ("aarch64", "arm64"):
        return "kvm"
    return "auto"


def infer_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "amd64"
    if machine in ("aarch64", "arm64"):
        return "arm64"
    return "arm64"


def memory_arg(mib: int) -> str:
    if mib % 1024 == 0:
        return f"{mib // 1024}gb"
    return f"{mib}mb"


def parse_csv_ints(raw: str) -> tuple[int, ...]:
    values = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        value = int(part)
        if value <= 0:
            die("--memory-mib values must be positive")
        values.append(value)
    if not values:
        die("--memory-mib must include at least one value")
    return tuple(values)


def json_dump(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


def load_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


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


def fetch_substrate_data(arch: str, url_template: str) -> dict[str, object]:
    url = url_template.format(arch=arch)
    request = urllib.request.Request(url, headers={"User-Agent": "sporevm-benchmark"})
    text = urllib.request.urlopen(request, timeout=30).read().decode("utf-8")
    match = re.search(r"window\.BENCHMARK_DATA\s*=\s*(\{.*\})\s*;?\s*$", text, re.S)
    if not match:
        die(f"could not parse Substrate data.js: {url}")
    data = json.loads(match.group(1))
    entries = data.get("entries", {})
    for name, runs in entries.items():
        if "snapshot restore" in name.lower() and runs:
            latest = runs[-1]
            benches = {}
            for bench in latest.get("benches", []):
                bench_name = bench.get("name")
                if isinstance(bench_name, str) and bench_name.startswith(f"ttinteractive/{arch}/"):
                    benches[bench_name] = bench
            return {
                "url": url,
                "repo_url": data.get("repoUrl"),
                "last_update_ms": data.get("lastUpdate"),
                "entry": name,
                "commit": latest.get("commit", {}),
                "benches": benches,
            }
    die(f"Substrate data has no snapshot restore entry for {arch}")


def substrate_value(snapshot: dict[str, object], arch: str, series: str, mib: int) -> float | None:
    benches = snapshot["benches"]
    assert isinstance(benches, dict)
    bench = benches.get(f"ttinteractive/{arch}/{series}-{mib}MiB")
    if not isinstance(bench, dict):
        return None
    value = bench.get("value")
    unit = bench.get("unit")
    if not isinstance(value, (int, float)):
        return None
    if unit != "ms":
        die(f"unexpected Substrate unit for {series}-{mib}MiB: {unit}")
    return float(value)


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
        "memory_bytes": exit_event.get("memory_bytes") if exit_event else None,
        "vsock_connect_ms": timings.get("vsock_connect_ms") if isinstance(timings, dict) else None,
        "exec_response_ms": timings.get("exec_response_ms") if isinstance(timings, dict) else None,
        "probe_duration_ms": timings.get("probe_duration_ms") if isinstance(timings, dict) else None,
        "guest_stdout_bytes": stdout_bytes,
        "guest_stderr_bytes": stderr_bytes,
    }


def parse_int_field(raw: str | None) -> int | None:
    if raw is None or raw == "null":
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def parse_key_value_tail(raw: str) -> dict[str, str]:
    fields = {}
    for part in raw.split():
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = value
    return fields


def parse_restore_logs(path: Path) -> dict[str, object]:
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    result: dict[str, object] = {
        "restore_source": None,
        "restore_reason": None,
        "backend_restore_mode": None,
        "backend_map_ram_ms": None,
        "backend_memory_ms": None,
        "backend_state_ms": None,
        "backend_pre_run_ms": None,
        "probe_attach_ms": None,
        "probe_request_delivered_ms": None,
        "probe_guest_timing_ms": None,
        "guest_accept_to_exit_ms": None,
        "ram_backing_map_private": False,
    }
    for match in RESTORE_SOURCE_RE.finditer(text):
        result["restore_source"] = match.group("source")
        result["restore_reason"] = match.group("reason")
    for match in RESTORE_METRICS_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        result["backend_restore_mode"] = fields.get("mode")
        result["backend_map_ram_ms"] = parse_int_field(fields.get("map_ram_ms"))
        result["backend_memory_ms"] = parse_int_field(fields.get("memory_ms"))
        result["backend_state_ms"] = parse_int_field(fields.get("state_ms"))
        result["backend_pre_run_ms"] = parse_int_field(fields.get("pre_run_ms"))
    for match in EXEC_PROBE_TIMING_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        result["probe_attach_ms"] = parse_int_field(fields.get("attach_ms"))
        result["probe_request_delivered_ms"] = parse_int_field(fields.get("request_delivered_ms"))
        result["probe_guest_timing_ms"] = parse_int_field(fields.get("guest_timing_ms"))
    for match in GUEST_TIMING_RE.finditer(text):
        fields = parse_key_value_tail(match.group("fields"))
        accept_ms = parse_int_field(fields.get("accept"))
        exit_ms = parse_int_field(fields.get("exit"))
        if accept_ms is not None and exit_ms is not None and exit_ms >= accept_ms:
            result["guest_accept_to_exit_ms"] = exit_ms - accept_ms
    result["ram_backing_map_private"] = "mapped RAM from file backing fd" in text and "mode=MAP_PRIVATE" in text
    result["local_backing_ok"] = (
        result["restore_source"] == "local_backing"
        and result["restore_reason"] == "proof_valid"
        and result["backend_restore_mode"] == "local_backing"
        and result["ram_backing_map_private"] is True
    )
    return result


def summarize(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "max": None, "mean": None, "median": None}
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
    }


def ratio(num: float | None, den: float | None) -> float | None:
    if num is None or den in (None, 0):
        return None
    return num / den


class Runner:
    def __init__(self, args: argparse.Namespace, substrate: dict[str, object]):
        self.args = args
        self.substrate = substrate
        self.root = repo_root()
        self.run_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
        self.output_dir = Path(args.output_dir).resolve()
        self.run_dir = self.output_dir / self.run_id
        self.raw_path = self.run_dir / "results.jsonl"
        self.summary_path = self.run_dir / "summary.json"
        self.log_dir = self.run_dir / "logs"
        self.work_dir = self.run_dir / "work"
        self.spore_bin = Path(args.spore_bin).resolve()
        self.env = os.environ.copy()
        self.env["SPOREVM_ROOTFS_CACHE_DIR"] = str(self.run_dir / "rootfs-cache")
        self.rows: list[dict[str, object]] = []

    def setup(self) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        if self.args.build:
            stdout = self.log_dir / "build.stdout"
            stderr = self.log_dir / "build.stderr"
            rc, elapsed, error = run_command(["mise", "run", "build"], env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=600)
            if rc != 0:
                die(f"build failed rc={rc} elapsed_ms={elapsed} error={error or ''} stderr={stderr}")
        if not self.spore_bin.is_file() or not os.access(self.spore_bin, os.X_OK):
            die(f"spore binary not executable: {self.spore_bin}")

    def emit(self, row: dict[str, object]) -> None:
        enriched = {
            "created_at": utc_now(),
            "run_id": self.run_id,
            "benchmark": "substrate_snapshot_restore",
            "backend": self.args.backend,
            "arch": self.args.arch,
            **row,
        }
        self.rows.append(enriched)
        append_jsonl(self.raw_path, enriched)

    def run(self) -> dict[str, object]:
        self.setup()
        for mib in self.args.memory_mib:
            self.run_memory(mib)
        summary = self.summary()
        json_dump(self.summary_path, summary)
        json_dump(self.output_dir / "latest-summary.json", summary)
        print_table(summary)
        print(f"results={self.raw_path}")
        print(f"summary={self.summary_path}")
        return summary

    def run_memory(self, mib: int) -> None:
        memory = memory_arg(mib)
        base_dir = self.work_dir / f"{mib}MiB" / "base.spore"
        children_dir = self.work_dir / f"{mib}MiB" / "children"
        shutil.rmtree(base_dir, ignore_errors=True)
        shutil.rmtree(children_dir, ignore_errors=True)
        base_dir.parent.mkdir(parents=True, exist_ok=True)
        capture_stdout = self.log_dir / f"{mib}MiB" / "capture.events.jsonl"
        capture_stderr = self.log_dir / f"{mib}MiB" / "capture.stderr"
        capture_argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.args.backend,
            "--events=jsonl",
            "--memory",
            memory,
            "--capture",
            str(base_dir),
            "--",
            *self.args.capture_command,
        ]
        capture_status, capture_ms, capture_error = run_command(
            capture_argv,
            env=self.env,
            stdout_path=capture_stdout,
            stderr_path=capture_stderr,
            timeout_s=self.args.timeout_s,
        )
        capture_events = parse_run_events(capture_stdout)
        capture_ok = capture_status == 0 and base_dir.exists()
        self.emit({
            "phase": "capture",
            "memory_mib": mib,
            "memory": memory,
            "success": capture_ok,
            "status": capture_status,
            "host_wall_ms": capture_ms,
            "error": capture_error,
            "spore_dir": str(base_dir),
            "stdout_path": str(capture_stdout),
            "stderr_path": str(capture_stderr),
            **capture_events,
        })
        if not capture_ok:
            die(f"capture failed for {mib}MiB status={capture_status} stdout={capture_stdout} stderr={capture_stderr}")

        fork_stdout = self.log_dir / f"{mib}MiB" / "fork.stdout"
        fork_stderr = self.log_dir / f"{mib}MiB" / "fork.stderr"
        fork_argv = [str(self.spore_bin), "fork", str(base_dir), "--count", str(self.args.iterations), "--out", str(children_dir)]
        fork_status, fork_ms, fork_error = run_command(fork_argv, env=self.env, stdout_path=fork_stdout, stderr_path=fork_stderr, timeout_s=self.args.timeout_s)
        fork_ok = fork_status == 0 and children_dir.exists()
        self.emit({
            "phase": "fork",
            "memory_mib": mib,
            "memory": memory,
            "success": fork_ok,
            "status": fork_status,
            "host_wall_ms": fork_ms,
            "fork_count": self.args.iterations,
            "fork_ms_per_child": fork_ms / self.args.iterations,
            "error": fork_error,
            "children_dir": str(children_dir),
            "stdout_path": str(fork_stdout),
            "stderr_path": str(fork_stderr),
        })
        if not fork_ok:
            die(f"fork failed for {mib}MiB status={fork_status} stdout={fork_stdout} stderr={fork_stderr}")

        for iteration in range(self.args.iterations):
            self.run_child(mib, memory, children_dir, iteration)

    def run_child(self, mib: int, memory: str, children_dir: Path, iteration: int) -> None:
        child_name = f"{iteration:06d}"
        child_dir = children_dir / child_name
        stdout = self.log_dir / f"{mib}MiB" / f"{child_name}.events.jsonl"
        stderr = self.log_dir / f"{mib}MiB" / f"{child_name}.stderr"
        argv = [
            str(self.spore_bin),
            "--debug",
            "run",
            "--backend",
            self.args.backend,
            "--events=jsonl",
            "--from",
            str(child_dir),
            "--",
            *self.args.probe_command,
        ]
        status, host_wall_ms, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        events = parse_run_events(stdout)
        restore = parse_restore_logs(stderr)
        guest_exit = events.get("guest_exit_code")
        exec_response_ms = events.get("exec_response_ms")
        success = status == 0 and guest_exit == 0 and isinstance(exec_response_ms, (int, float))
        if self.args.require_local_backing:
            success = success and restore.get("local_backing_ok") is True
        self.emit({
            "phase": "restore",
            "memory_mib": mib,
            "memory": memory,
            "iteration": iteration,
            "child": child_name,
            "success": success,
            "status": status,
            "host_wall_ms": host_wall_ms,
            "tti_ms": exec_response_ms,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
            **events,
            **restore,
        })
        if self.args.require_local_backing and restore.get("local_backing_ok") is not True:
            die(
                "restore did not use proof-backed mmap RAM "
                f"for {mib}MiB iteration={iteration}: "
                f"source={restore.get('restore_source')} "
                f"reason={restore.get('restore_reason')} "
                f"mode={restore.get('backend_restore_mode')} "
                f"map_private={restore.get('ram_backing_map_private')} "
                f"stderr={stderr}"
            )
        state = "ok" if success else "failed"
        print(f"{mib}MiB restore iteration={iteration} {state} exec_response_ms={exec_response_ms}", file=sys.stderr)

    def summary(self) -> dict[str, object]:
        results = []
        for mib in self.args.memory_mib:
            restore_rows = [
                row for row in self.rows
                if row.get("phase") == "restore" and row.get("memory_mib") == mib
            ]
            values = [
                float(row["exec_response_ms"])
                for row in restore_rows
                if row.get("success") and isinstance(row.get("exec_response_ms"), (int, float))
            ]
            backend_restore_to_reply = [
                float(row["backend_pre_run_ms"]) + float(row["exec_response_ms"])
                for row in restore_rows
                if row.get("success")
                and isinstance(row.get("backend_pre_run_ms"), (int, float))
                and isinstance(row.get("exec_response_ms"), (int, float))
            ]
            spore = summarize(values)
            spore_backend = summarize(backend_restore_to_reply)
            sub = {series: substrate_value(self.substrate, self.args.arch, series, mib) for series in SUBSTRATE_SERIES}
            median = spore["median"] if isinstance(spore["median"], (int, float)) else None
            backend_median = spore_backend["median"] if isinstance(spore_backend["median"], (int, float)) else None
            results.append({
                "memory_mib": mib,
                "spore_exec_response_ms": spore,
                "spore_backend_restore_to_reply_ms": spore_backend,
                "spore_success_rate": len(values) / len(restore_rows) if restore_rows else 0.0,
                "substrate_ms": sub,
                "spore_vs_substrate_mmap": ratio(median, sub.get("substrate-mmap")),
                "spore_vs_substrate_uffd": ratio(median, sub.get("substrate-uffd")),
                "spore_vs_firecracker_file": ratio(median, sub.get("fc-file")),
                "spore_vs_cloud_hypervisor": ratio(median, sub.get("chv")),
                "spore_backend_vs_substrate_mmap": ratio(backend_median, sub.get("substrate-mmap")),
                "spore_backend_vs_substrate_uffd": ratio(backend_median, sub.get("substrate-uffd")),
            })
        return {
            "run_id": self.run_id,
            "generated_at": utc_now(),
            "raw_results": str(self.raw_path),
            "config": {
                "arch": self.args.arch,
                "backend": self.args.backend,
                "memory_mib": self.args.memory_mib,
                "iterations": self.args.iterations,
                "capture_command": self.args.capture_command,
                "probe_command": self.args.probe_command,
                "spore_bin": str(self.spore_bin),
                "require_local_backing": self.args.require_local_backing,
            },
            "substrate": {
                "url": self.substrate.get("url"),
                "repo_url": self.substrate.get("repo_url"),
                "entry": self.substrate.get("entry"),
                "commit": self.substrate.get("commit"),
                "last_update_ms": self.substrate.get("last_update_ms"),
            },
            "results": results,
        }


def fmt_ms(value: object) -> str:
    return "n/a" if not isinstance(value, (int, float)) else f"{value:.1f}"


def fmt_ratio(value: object) -> str:
    return "n/a" if not isinstance(value, (int, float)) else f"{value:.2f}x"


def print_table(summary: dict[str, object]) -> None:
    substrate = summary["substrate"]
    commit = substrate.get("commit", {}) if isinstance(substrate, dict) else {}
    commit_id = commit.get("id", "") if isinstance(commit, dict) else ""
    print(f"Substrate snapshot: {str(commit_id)[:7]} {substrate.get('url') if isinstance(substrate, dict) else ''}")
    print("memory  spore_reply_ms  spore_backend_ms  sub_mmap_ms  sub_uffd_ms  fc_file_ms  backend/mmap")
    for row in summary.get("results", []):
        spore = row.get("spore_exec_response_ms", {})
        median = spore.get("median") if isinstance(spore, dict) else None
        spore_backend = row.get("spore_backend_restore_to_reply_ms", {})
        backend_median = spore_backend.get("median") if isinstance(spore_backend, dict) else None
        sub = row.get("substrate_ms", {})
        print(
            f"{row.get('memory_mib'):>5}  "
            f"{fmt_ms(median):>14}  "
            f"{fmt_ms(backend_median):>16}  "
            f"{fmt_ms(sub.get('substrate-mmap') if isinstance(sub, dict) else None):>11}  "
            f"{fmt_ms(sub.get('substrate-uffd') if isinstance(sub, dict) else None):>11}  "
            f"{fmt_ms(sub.get('fc-file') if isinstance(sub, dict) else None):>10}  "
            f"{fmt_ratio(row.get('spore_backend_vs_substrate_mmap')):>12}"
        )


def print_substrate_only(args: argparse.Namespace, substrate: dict[str, object]) -> None:
    summary = {
        "substrate": {
            "url": substrate.get("url"),
            "repo_url": substrate.get("repo_url"),
            "entry": substrate.get("entry"),
            "commit": substrate.get("commit"),
        },
        "results": [
            {
                "memory_mib": mib,
                "spore_exec_response_ms": {},
                "substrate_ms": {series: substrate_value(substrate, args.arch, series, mib) for series in SUBSTRATE_SERIES},
            }
            for mib in args.memory_mib
        ],
    }
    print_table(summary)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", default=infer_arch(), choices=("amd64", "arm64"))
    parser.add_argument("--backend", default=infer_backend(), choices=("auto", "hvf", "kvm"))
    parser.add_argument("--memory-mib", default=",".join(str(v) for v in DEFAULT_MEMORY_MIB), help="Comma-separated RAM sizes matching Substrate labels")
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--capture-command", default="/bin/true")
    parser.add_argument("--probe-command", default="/bin/true")
    parser.add_argument("--output-dir", default="zig-cache/sporevm-substrate-snapshot")
    parser.add_argument("--spore-bin", default=str(repo_root() / "zig-out/bin/spore"))
    parser.add_argument("--timeout-s", type=int, default=240)
    parser.add_argument("--substrate-data-url", default="https://benchmarks.substrate.so/{arch}/data.js")
    parser.add_argument("--fetch-only", action="store_true", help="Only print the latest Substrate snapshot data")
    parser.add_argument("--no-require-local-backing", dest="require_local_backing", action="store_false", help="Allow chunk-backed restores instead of failing the warm/mmap comparison")
    parser.add_argument("--no-build", dest="build", action="store_false")
    parser.set_defaults(build=True, require_local_backing=True)
    args = parser.parse_args(argv)
    args.memory_mib = parse_csv_ints(args.memory_mib)
    args.capture_command = shlex.split(args.capture_command)
    args.probe_command = shlex.split(args.probe_command)
    if args.iterations <= 0:
        die("--iterations must be positive")
    if not args.capture_command:
        die("--capture-command must not be empty")
    if not args.probe_command:
        die("--probe-command must not be empty")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    substrate = fetch_substrate_data(args.arch, args.substrate_data_url)
    if args.fetch_only:
        print_substrate_only(args, substrate)
        return 0
    Runner(args, substrate).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
