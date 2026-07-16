#!/usr/bin/env python3
"""Exercise repeated named saves under pgbench write load and verify restores."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


SCHEMA = "sporevm.pgbench-snapshot.v1"
DEFAULT_IMAGE = "docker.io/library/postgres:16-bookworm"
GUEST_HARNESS = "/var/lib/sporevm-pgbench-harness.sh"
GUEST_WORKLOAD = "/var/lib/sporevm-pgbench-workload.sql"

WORKLOAD_SQL = r"""\set aid random(1, 100000 * :scale)
\set bid random(1, 1 * :scale)
\set tid random(1, 10 * :scale)
\set delta random(-5000, 5000)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime)
  VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
UPDATE sporevm_snapshot_counters
  SET committed = committed + 1
  WHERE client_id = :client_id;
END;
"""

GUEST_SCRIPT = r"""#!/bin/sh
set -eu

root=/var/lib/sporevm-pgbench
socket_dir="$root/socket"
workload=/var/lib/sporevm-pgbench-workload.sql
db=pgbench
pgdata="${PGDATA:-/var/lib/postgresql/data}"
for postgres_bin in /usr/lib/postgresql/*/bin; do
  if [ -d "$postgres_bin" ]; then
    PATH="$postgres_bin:$PATH"
  fi
done
export PATH

die() {
  echo "pgbench harness: $*" >&2
  exit 1
}

require_tools() {
  for tool in awk gosu initdb pg_ctl pg_isready createdb psql pgbench pg_amcheck nohup; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done
}

counter() {
  gosu postgres psql -h "$socket_dir" -U postgres -d "$db" -Atqc \
    'SELECT COALESCE(sum(committed), 0) FROM sporevm_snapshot_counters'
}

health_counter() {
  [ -f "$root/pgbench.pid" ] || die "pgbench pid file is missing"
  pid="$(cat "$root/pgbench.pid")"
  if ! pid_alive "$pid"; then
    tail -50 "$root/pgbench.log" >&2 || true
    die "pgbench is no longer running"
  fi
  counter
}

pid_alive() {
  pid="$1"
  [ -r "/proc/$pid/stat" ] || return 1
  [ "$(awk '{print $3}' "/proc/$pid/stat")" != "Z" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_pid_file() {
  pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return
  fi
  pid="$(cat "$pid_file")"
  if pid_alive "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while pid_alive "$pid" && [ "$i" -lt 100 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if pid_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pid_file"
}

setup() {
  scale="$1"
  clients="$2"
  require_tools
  mkdir -p "$root" "$socket_dir"
  chown -R postgres:postgres "$root"
  if [ ! -s "$pgdata/PG_VERSION" ]; then
    rm -rf "$pgdata"
    mkdir -p "$pgdata"
    chown -R postgres:postgres "$pgdata"
    gosu postgres initdb -D "$pgdata" --encoding=UTF8 --no-locale >"$root/initdb.log"
  fi
  if ! gosu postgres pg_ctl -D "$pgdata" status >/dev/null 2>&1; then
    gosu postgres pg_ctl -D "$pgdata" -l "$root/postgres.log" \
      -o "-k $socket_dir -h '' -c fsync=on -c synchronous_commit=on -c full_page_writes=on" start
  fi
  gosu postgres pg_isready -h "$socket_dir" -U postgres -d postgres >/dev/null
  if ! gosu postgres psql -h "$socket_dir" -U postgres -d postgres -Atqc \
      "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -qx 1; then
    gosu postgres createdb -h "$socket_dir" -U postgres "$db"
  fi
  gosu postgres pgbench -h "$socket_dir" -U postgres -i -s "$scale" "$db" \
    >"$root/pgbench-init.log" 2>&1
  available_kib="$(df -Pk "$pgdata" | awk 'NR == 2 { print $4 }')"
  if [ "$scale" -ge 100 ] && [ "$available_kib" -lt 2097152 ]; then
    die "scale $scale requires at least 2 GiB free after initialization; increase --disk-size"
  fi
  gosu postgres psql -h "$socket_dir" -U postgres -d "$db" -v ON_ERROR_STOP=1 \
    -c 'DROP TABLE IF EXISTS sporevm_snapshot_counters' \
    -c 'CREATE TABLE sporevm_snapshot_counters (client_id integer PRIMARY KEY, committed bigint NOT NULL DEFAULT 0)' \
    -c "INSERT INTO sporevm_snapshot_counters (client_id) SELECT generate_series(0, $((clients - 1)))" \
    >"$root/counter-setup.log"
  printf 'ready\n' >"$root/ready"
}

start() {
  clients="$1"
  jobs="$2"
  duration="$3"
  scale="$4"
  [ -f "$root/ready" ] || die "setup has not completed"
  [ ! -f "$root/pgbench.pid" ] || die "pgbench is already running"
  : >"$root/timeline.tsv"
  nohup gosu postgres pgbench -h "$socket_dir" -U postgres -n \
    -c "$clients" -j "$jobs" -T "$duration" -P 1 \
    -s "$scale" -f "$workload" "$db" >"$root/pgbench.log" 2>&1 </dev/null &
  echo "$!" >"$root/pgbench.pid"
  nohup /bin/sh "$0" sample >"$root/sampler.log" 2>&1 </dev/null &
  echo "$!" >"$root/sampler.pid"
  sleep 0.2
  pid_alive "$(cat "$root/pgbench.pid")" || die "pgbench exited during startup; see $root/pgbench.log"
}

sample() {
  while [ -f "$root/pgbench.pid" ] && pid_alive "$(cat "$root/pgbench.pid")"; do
    now="$(date +%s%N)"
    value="$(counter)"
    printf '%s\t%s\n' "$now" "$value" >>"$root/timeline.tsv"
    sleep 1
  done
}

wait_client() {
  if [ -f "$root/pgbench.pid" ]; then
    pid="$(cat "$root/pgbench.pid")"
    while pid_alive "$pid"; do
      sleep 0.2
    done
    rm -f "$root/pgbench.pid"
  fi
  stop_pid_file "$root/sampler.pid"
  counter
}

quiesce() {
  stop_pid_file "$root/pgbench.pid"
  stop_pid_file "$root/sampler.pid"
  counter
}

validate() {
  gosu postgres pg_isready -h "$socket_dir" -U postgres -d "$db"
  gosu postgres pg_amcheck -h "$socket_dir" -U postgres -d "$db" --install-missing
}

metadata() {
  postgres --version
  pgbench --version
  printf 'pgdata=%s\n' "$pgdata"
  printf 'socket_dir=%s\n' "$socket_dir"
  df -Pk "$pgdata"
  du -sk "$pgdata"
  gosu postgres psql -h "$socket_dir" -U postgres -d "$db" -Atqc \
    "SELECT current_setting('shared_buffers'), current_setting('max_wal_size')"
}

diagnose() {
  set +e
  printf '%s\n' '== pgbench tail =='
  tail -80 "$root/pgbench.log"
  printf '%s\n' '== postgres tail =='
  tail -120 "$root/postgres.log"
  printf '%s\n' '== filesystem =='
  df -Pk "$pgdata"
  du -sk "$pgdata" "$pgdata/pg_wal"
  printf '%s\n' '== memory =='
  cat /proc/meminfo
  printf '%s\n' '== kernel tail =='
  dmesg | tail -120
}

action="${1:-}"
shift || true
case "$action" in
  setup) setup "$@" ;;
  start) start "$@" ;;
  sample) sample ;;
  counter) counter ;;
  health-counter) health_counter ;;
  wait-client) wait_client ;;
  quiesce) quiesce ;;
  validate) validate ;;
  metadata) metadata ;;
  diagnose) diagnose ;;
  *) die "unknown action: $action" ;;
esac
"""


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def infer_backend() -> str:
    if os.uname().sysname == "Darwin" and os.uname().machine == "arm64":
        return "hvf"
    if os.uname().sysname == "Linux" and os.uname().machine in ("aarch64", "arm64"):
        return "kvm"
    raise SystemExit("cannot infer a supported backend; pass --backend")


def load_metrics_parser():
    path = repo_root() / "scripts" / "benchmark" / "parse-save-metrics.py"
    spec = importlib.util.spec_from_file_location("sporevm_parse_save_metrics", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load metrics parser: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


class CommandRunner:
    def __init__(self, output_dir: Path, env: dict[str, str]) -> None:
        self.logs = output_dir / "logs"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.env = env
        self.sequence = 0

    def run(self, label: str, argv: list[str], *, check: bool = True, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
        self.sequence += 1
        stem = self.logs / f"{self.sequence:03d}-{label}"
        started_ns = time.time_ns()
        completed = subprocess.run(
            argv, env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=timeout, check=False,
        )
        stem.with_suffix(".stdout").write_text(completed.stdout, encoding="utf-8")
        stem.with_suffix(".stderr").write_text(completed.stderr, encoding="utf-8")
        stem.with_suffix(".json").write_text(
            json.dumps({
                "argv": argv,
                "duration_ms": (time.time_ns() - started_ns) // 1_000_000,
                "returncode": completed.returncode,
            }, indent=2) + "\n",
            encoding="utf-8",
        )
        if check and completed.returncode != 0:
            raise RuntimeError(
                f"{label} failed with status {completed.returncode}: "
                f"{completed.stderr[-4096:].strip()}"
            )
        return completed


def wait_seconds(seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 5.0))


def parse_counter(output: str) -> int:
    stripped = output.strip()
    if not stripped.isascii() or not stripped.isdecimal():
        raise ValueError(f"invalid transaction counter: {stripped!r}")
    return int(stripped)


def metric_line(lines: list[str], marker: str) -> str:
    matches = [line for line in lines if marker in line]
    if len(matches) != 1:
        raise ValueError(f"expected one {marker!r} metric, found {len(matches)}")
    return matches[0]


def parse_timeline(path: Path) -> list[tuple[int, int]]:
    samples: list[tuple[int, int]] = []
    if not path.exists():
        return samples
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) == 2 and all(field.isdecimal() for field in fields):
            samples.append((int(fields[0]), int(fields[1])))
    return samples


def timeline_window(samples: list[tuple[int, int]], start_ns: int, end_ns: int) -> dict[str, int] | None:
    before = [sample for sample in samples if sample[0] <= start_ns]
    after = [sample for sample in samples if sample[0] >= end_ns]
    if not before or not after:
        return None
    left = before[-1]
    right = after[0]
    return {
        "sample_gap_ms": (right[0] - left[0]) // 1_000_000,
        "transactions_during_gap": right[1] - left[1],
        "sample_before": left[1],
        "sample_after": right[1],
    }


def self_test() -> None:
    assert parse_counter("42\n") == 42
    for bad in ("", "-1", "1.0", "nope"):
        try:
            parse_counter(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted invalid counter: {bad!r}")
    samples = [(1_000_000_000, 10), (2_000_000_000, 20), (3_000_000_000, 20)]
    assert timeline_window(samples, 1_500_000_000, 2_500_000_000) == {
        "sample_gap_ms": 2000,
        "transactions_during_gap": 10,
        "sample_before": 10,
        "sample_after": 20,
    }
    assert ":client_id" in WORKLOAD_SQL
    assert "synchronous_commit=on" in GUEST_SCRIPT
    print("pgbench snapshot harness self-test ok")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spore-bin", type=Path, default=repo_root() / "zig-out/bin/spore")
    parser.add_argument("--backend", choices=("auto", "hvf", "kvm"), default="auto")
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--prepared-image", help="skip disk-growth preparation and use this local image")
    parser.add_argument("--disk-size", default="4gb")
    parser.add_argument("--memory", default="1gb")
    parser.add_argument("--vcpus", type=positive_int, default=2)
    parser.add_argument("--scale", type=positive_int, default=10)
    parser.add_argument("--clients", type=positive_int, default=8)
    parser.add_argument("--jobs", type=positive_int, default=2)
    parser.add_argument("--snapshots", type=positive_int, default=3)
    parser.add_argument("--warmup-seconds", type=positive_int, default=10)
    parser.add_argument("--cadence-seconds", type=positive_int, default=30)
    parser.add_argument("--timeout", default="10m")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--work-dir", type=Path, default=Path(os.environ.get("TMPDIR", "/tmp")))
    parser.add_argument(
        "--runtime-root", type=Path, default=Path("/tmp"),
        help="parent for the short private monitor runtime directory (default: /tmp)",
    )
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--allow-full-scan", action="store_true")
    parser.add_argument("--skip-restore-validation", action="store_true")
    parser.add_argument("--keep-checkpoints", action="store_true")
    parser.add_argument("--keep-workdir", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.jobs > args.clients:
        raise SystemExit("--jobs cannot exceed --clients")
    backend = infer_backend() if args.backend == "auto" else args.backend
    spore_bin = args.spore_bin.resolve()
    if not args.no_build:
        subprocess.run(["mise", "run", "build:release"], cwd=repo_root(), check=True)
    if not spore_bin.is_file() or not os.access(spore_bin, os.X_OK):
        raise SystemExit(f"spore binary is not executable: {spore_bin}")

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    output_dir = (args.output_dir or repo_root() / "zig-cache/sporevm-benchmarks/pgbench-snapshot" / stamp).resolve()
    output_dir.mkdir(parents=True, exist_ok=False)
    results_path = output_dir / "results.jsonl"
    work_root = Path(tempfile.mkdtemp(prefix="sporevm-pgbench-snapshot.", dir=args.work_dir.resolve()))
    runtime_dir = Path(tempfile.mkdtemp(prefix="svm-pg.", dir=args.runtime_root.resolve()))
    runtime_dir.chmod(0o700)
    cache_dir = args.cache_dir.resolve() if args.cache_dir else work_root / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    overlay_dir = work_root / "overlays"
    overlay_dir.mkdir(mode=0o700)
    env = os.environ.copy()
    env.update({
        "SPOREVM_RUNTIME_DIR": str(runtime_dir),
        "SPOREVM_ROOTFS_CACHE_DIR": str(cache_dir),
        "SPOREVM_ROOTFS_BUILD_PROFILE": "1",
        # Keep sparse runtime heads out of the process-global temporary
        # directory. This isolates host filesystem pressure between runs and
        # also gives APFS clone operations one task-owned filesystem root.
        "TMPDIR": str(overlay_dir),
    })
    runner = CommandRunner(output_dir, env)
    parser = load_metrics_parser()
    name_suffix = uuid.uuid4().hex[:8]
    source_name = f"pgbench-{name_suffix}"
    active_names: set[str] = set()
    checkpoints: list[Path] = []
    monitor_log: Path | None = None
    source_guest_dir = output_dir / "source-guest"
    success = False

    harness_path = work_root / "pgbench-harness.sh"
    workload_path = work_root / "pgbench-workload.sql"
    debug_wrapper = work_root / "spore-debug"
    harness_path.write_text(GUEST_SCRIPT, encoding="utf-8")
    harness_path.chmod(0o755)
    workload_path.write_text(WORKLOAD_SQL, encoding="utf-8")
    debug_wrapper.write_text(
        "#!/usr/bin/env bash\n"
        f'exec -a "$0" {shlex.quote(str(spore_bin))} --debug "$@"\n',
        encoding="utf-8",
    )
    debug_wrapper.chmod(0o700)

    def spore(*argv: str) -> list[str]:
        # Named lifecycle monitors re-exec argv[0]. Keep --debug in that path so
        # the existing structured save metrics land in monitor.log.
        return [str(debug_wrapper), *argv]

    def guest(vm_name: str, action: str, *values: object, label: str | None = None) -> subprocess.CompletedProcess[str]:
        return runner.run(
            label or f"guest-{action}",
            spore("exec", vm_name, "--", "/bin/sh", GUEST_HARNESS, action, *(str(value) for value in values)),
            timeout=900,
        )

    def copy_guest_logs(vm_name: str, *, required: bool) -> None:
        source_guest_dir.mkdir(exist_ok=True)
        for guest_log in (
            "timeline.tsv",
            "pgbench.log",
            "postgres.log",
            "sampler.log",
            "pgbench-init.log",
            "initdb.log",
            "counter-setup.log",
        ):
            runner.run(
                f"copy-source-{guest_log}",
                spore(
                    "copy-out", vm_name,
                    f"/var/lib/sporevm-pgbench/{guest_log}",
                    str(source_guest_dir / guest_log),
                ),
                check=required,
                timeout=120,
            )

    try:
        prepared_image = args.prepared_image
        prepare_started = time.time_ns()
        if prepared_image is None:
            prepared_image = f"local/sporevm-pgbench:{name_suffix}"
            runner.run(
                "prepare-image",
                spore(
                    "run", "--backend", backend, "--memory", args.memory,
                    "--image", args.image, "--disk-size", args.disk_size,
                    "--commit", prepared_image, "--timeout", args.timeout,
                    "--", "/bin/true",
                ),
                timeout=1800,
            )
        append_jsonl(results_path, {
            "schema": SCHEMA,
            "phase": "metadata",
            "backend": backend,
            "source_image": args.image,
            "prepared_image": prepared_image,
            "prepare_ms": (time.time_ns() - prepare_started) // 1_000_000,
            "disk_size": args.disk_size,
            "memory": args.memory,
            "vcpus": args.vcpus,
            "scale": args.scale,
            "clients": args.clients,
            "jobs": args.jobs,
            "snapshots": args.snapshots,
            "warmup_seconds": args.warmup_seconds,
            "cadence_seconds": args.cadence_seconds,
        })

        runner.run(
            "create-source",
            spore(
                "create", source_name, "--backend", backend, "--image", prepared_image,
                "--pull=never", "--memory", args.memory, "--vcpus", str(args.vcpus),
                "--timeout", args.timeout,
            ),
            timeout=900,
        )
        active_names.add(source_name)
        runner.run("copy-harness", spore("copy-in", source_name, str(harness_path), GUEST_HARNESS), timeout=120)
        runner.run("copy-workload", spore("copy-in", source_name, str(workload_path), GUEST_WORKLOAD), timeout=120)
        guest(source_name, "setup", args.scale, args.clients, label="setup-postgres")
        metadata = guest(source_name, "metadata", label="postgres-metadata").stdout.strip().splitlines()
        # Snapshot pauses count against pgbench's guest-visible deadline. Keep
        # that deadline well beyond the benchmark and stop pgbench explicitly
        # after the final checkpoint, so slow saves cannot end the workload.
        workload_duration = 3600
        guest(
            source_name, "start", args.clients, args.jobs, workload_duration, args.scale,
            label="start-pgbench",
        )
        next_snapshot_at = time.monotonic() + args.warmup_seconds

        monitor_log = runtime_dir / "vms" / source_name / "monitor.log"
        snapshot_rows: list[dict[str, object]] = []
        for iteration in range(1, args.snapshots + 1):
            wait_seconds(max(0.0, next_snapshot_at - time.monotonic()))
            before = parse_counter(
                guest(source_name, "health-counter", label=f"counter-before-{iteration}").stdout
            )
            checkpoint = work_root / f"checkpoint-{iteration}.spore"
            checkpoints.append(checkpoint)
            log_size = monitor_log.stat().st_size
            save_started_wall_ns = time.time_ns()
            save_started_monotonic_ns = time.monotonic_ns()
            next_snapshot_at = save_started_monotonic_ns / 1_000_000_000 + args.cadence_seconds
            runner.run(f"save-{iteration}", spore("save", source_name, "--out", str(checkpoint)), timeout=900)
            save_ended_monotonic_ns = time.monotonic_ns()
            save_ended_wall_ns = time.time_ns()
            after = parse_counter(
                guest(source_name, "health-counter", label=f"counter-after-{iteration}").stdout
            )
            with monitor_log.open("r", encoding="utf-8", errors="replace") as fh:
                fh.seek(log_size)
                new_lines = fh.read().splitlines()
            try:
                disk = parser.parse_metric(metric_line(new_lines, "disk snapshot metrics: "))
                snapshot = parser.parse_snapshot_metric(
                    metric_line(new_lines, f"{backend} snapshot metrics: ")
                )
                publication = parser.parse_named_publication_metric(
                    metric_line(new_lines, f"{backend} named snapshot publication metrics: ")
                )
            except (KeyError, ValueError):
                shutil.copy2(monitor_log, output_dir / f"source-monitor-save-{iteration}.log")
                raise
            if not args.allow_full_scan and disk["full_scan"]:
                raise RuntimeError(f"snapshot {iteration} performed a full disk scan")
            row: dict[str, object] = {
                "schema": SCHEMA,
                "phase": "snapshot",
                "iteration": iteration,
                "save_duration_ms": (save_ended_monotonic_ns - save_started_monotonic_ns) // 1_000_000,
                "save_started_wall_ns": save_started_wall_ns,
                "save_ended_wall_ns": save_ended_wall_ns,
                "counter_before": before,
                "counter_after": after,
                "counter_window": after - before,
                "checkpoint": str(checkpoint),
                "disk_metrics": disk,
                "snapshot_metrics": snapshot,
                "publication_metrics": publication,
            }
            snapshot_rows.append(row)
            append_jsonl(results_path, row)

        final_counter = parse_counter(guest(source_name, "quiesce", label="stop-pgbench").stdout)
        copy_guest_logs(source_name, required=True)
        shutil.copy2(monitor_log, output_dir / "source-monitor.log")
        runner.run("remove-source", spore("rm", source_name), timeout=120)
        active_names.remove(source_name)

        samples = parse_timeline(source_guest_dir / "timeline.tsv")
        for row in snapshot_rows:
            timeline = timeline_window(samples, int(row["save_started_wall_ns"]), int(row["save_ended_wall_ns"]))
            append_jsonl(results_path, {
                "schema": SCHEMA,
                "phase": "timeline",
                "iteration": row["iteration"],
                "timeline": timeline,
            })

        validation_rows: list[dict[str, object]] = []
        if not args.skip_restore_validation:
            for row, checkpoint in zip(snapshot_rows, checkpoints, strict=True):
                iteration = int(row["iteration"])
                verify_name = f"pgbench-verify-{iteration}-{name_suffix}"
                runner.run(
                    f"restore-{iteration}",
                    spore("restore", str(checkpoint), "--name", verify_name, "--backend", backend),
                    timeout=900,
                )
                active_names.add(verify_name)
                restored_counter = parse_counter(
                    guest(verify_name, "quiesce", label=f"quiesce-restored-{iteration}").stdout
                )
                validation = guest(verify_name, "validate", label=f"pg-amcheck-{iteration}")
                lower = int(row["counter_before"])
                source_after = int(row["counter_after"])
                not_older_than_pre_save = restored_counter >= lower
                validation_row = {
                    "schema": SCHEMA,
                    "phase": "restore_validation",
                    "iteration": iteration,
                    "counter_before": lower,
                    "counter_after": source_after,
                    "restored_counter": restored_counter,
                    "counter_not_older_than_pre_save": not_older_than_pre_save,
                    "restored_above_source_post_save": restored_counter > source_after,
                    "restored_progress_past_source_post_save": max(0, restored_counter - source_after),
                    "pg_amcheck_ok": validation.returncode == 0,
                }
                validation_rows.append(validation_row)
                append_jsonl(results_path, validation_row)
                runner.run(f"remove-restore-{iteration}", spore("rm", verify_name), timeout=120)
                active_names.remove(verify_name)

        source_pauses = [int(row["publication_metrics"]["source_pause_ms"]) for row in snapshot_rows]  # type: ignore[index]
        memory_times = [int(row["snapshot_metrics"]["memory_ms"]) for row in snapshot_rows]  # type: ignore[index]
        disk_times = [int(row["snapshot_metrics"]["disk_ms"]) for row in snapshot_rows]  # type: ignore[index]
        summary = {
            "schema": SCHEMA,
            "phase": "summary",
            "postgres": metadata,
            "final_counter": final_counter,
            "source_pause_ms_median": statistics.median(source_pauses),
            "source_pause_ms_max": max(source_pauses),
            "memory_ms_median": statistics.median(memory_times),
            "disk_ms_median": statistics.median(disk_times),
            "all_restores_valid": all(
                bool(row["pg_amcheck_ok"]) and bool(row["counter_not_older_than_pre_save"])
                for row in validation_rows
            ) if validation_rows else None,
        }
        append_jsonl(results_path, summary)
        (output_dir / "summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

        if not args.keep_checkpoints:
            for checkpoint in checkpoints:
                runner.run("remove-checkpoint", spore("rm", "--spore", str(checkpoint)), timeout=120)
            checkpoints.clear()
        success = True
        print(output_dir)
        return 0
    finally:
        if not success and monitor_log is not None and monitor_log.exists():
            shutil.copy2(monitor_log, output_dir / "source-monitor-failure.log")
        if not success and source_name in active_names:
            try:
                guest(source_name, "diagnose", label="failure-diagnostics")
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass
            try:
                copy_guest_logs(source_name, required=False)
            except (OSError, subprocess.SubprocessError):
                pass
        for vm_name in sorted(active_names):
            runner.run(f"cleanup-{vm_name}", spore("rm", vm_name), check=False, timeout=120)
        if not args.keep_checkpoints:
            for checkpoint in checkpoints:
                if checkpoint.exists():
                    runner.run("cleanup-checkpoint", spore("rm", "--spore", str(checkpoint)), check=False, timeout=120)
        if success and not args.keep_workdir:
            shutil.rmtree(work_root, ignore_errors=True)
            shutil.rmtree(runtime_dir, ignore_errors=True)
        else:
            print(
                f"pgbench snapshot workdir kept at {work_root}; runtime at {runtime_dir}",
                file=sys.stderr,
            )


if __name__ == "__main__":
    raise SystemExit(main())
