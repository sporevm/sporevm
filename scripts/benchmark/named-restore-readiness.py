#!/usr/bin/env python3
"""Benchmark persistent named restore readiness from an immutable spore."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import statistics
import subprocess
import sys
import tempfile
import time


RESTORE_METRICS_RE = re.compile(r"(?:kvm|hvf) restore metrics: (?P<fields>.+)")


def parse_restore_metrics(stderr: str) -> dict[str, object]:
    matches = list(RESTORE_METRICS_RE.finditer(stderr))
    if not matches:
        return {}
    fields: dict[str, object] = {}
    for item in matches[-1].group("fields").split():
        key, separator, value = item.partition("=")
        if not separator:
            continue
        try:
            fields[key] = int(value)
        except ValueError:
            fields[key] = value
    return fields


def self_test() -> None:
    metrics = parse_restore_metrics(
        "info: kvm restore metrics: mode=local_backing ram_mib=1024 chunks=16 "
        "nonzero_chunks=12 manifest_ms=1 map_ram_ms=0 memory_ms=0 state_ms=2 pre_run_ms=4"
    )
    assert metrics["mode"] == "local_backing"
    assert metrics["ram_mib"] == 1024
    assert metrics["memory_ms"] == 0
    assert metrics["state_ms"] == 2
    assert metrics["pre_run_ms"] == 4
    assert parse_restore_metrics("no restore metrics") == {}
    print("self-test ok")


def elapsed_ms(start_ns: int) -> float:
    return (time.monotonic_ns() - start_ns) / 1_000_000


def run(argv: list[str], env: dict[str, str]) -> tuple[subprocess.CompletedProcess[str], float]:
    start_ns = time.monotonic_ns()
    result = subprocess.run(argv, env=env, text=True, capture_output=True, check=False)
    return result, elapsed_ms(start_ns)


def debug_spore_wrapper(real_spore_bin: pathlib.Path, runtime_dir: pathlib.Path) -> pathlib.Path:
    wrapper = runtime_dir / "spore-with-restore-metrics"
    wrapper.write_text(
        f"#!/bin/sh\nexec {shlex.quote(str(real_spore_bin))} --debug \"$@\"\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o700)
    return wrapper


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spore-dir", type=pathlib.Path)
    parser.add_argument("--spore-bin", type=pathlib.Path, default=pathlib.Path("zig-out/bin/spore"))
    parser.add_argument("--backend", choices=("auto", "hvf", "kvm"), default="auto")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--repeated-execs", type=int, default=5)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("zig-cache/named-restore-readiness.jsonl"))
    parser.add_argument("--runtime-dir", type=pathlib.Path)
    parser.add_argument("--include-run-from", action="store_true", help="also time one-shot run --from /bin/true")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return args
    if args.spore_dir is None:
        parser.error("--spore-dir is required")
    if args.iterations < 1 or args.repeated_execs < 1:
        parser.error("--iterations and --repeated-execs must be positive")
    return args


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    repo = pathlib.Path(__file__).resolve().parents[2]
    spore_dir = args.spore_dir.resolve()
    if not (spore_dir / "manifest.json").is_file():
        raise SystemExit(f"missing spore manifest: {spore_dir / 'manifest.json'}")

    if not args.no_build:
        subprocess.run(["mise", "run", "build:release"], cwd=repo, check=True)

    real_spore_bin = (repo / args.spore_bin).resolve() if not args.spore_bin.is_absolute() else args.spore_bin
    runtime_owner: tempfile.TemporaryDirectory[str] | None = None
    if args.runtime_dir is None:
        runtime_owner = tempfile.TemporaryDirectory(prefix="sporevm-named-readiness-")
        runtime_dir = pathlib.Path(runtime_owner.name)
    else:
        runtime_dir = args.runtime_dir.resolve()
        runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        runtime_dir.chmod(0o700)
    spore_bin = debug_spore_wrapper(real_spore_bin, runtime_dir)

    output = (repo / args.output).resolve() if not args.output.is_absolute() else args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["SPOREVM_RUNTIME_DIR"] = str(runtime_dir)
    version = subprocess.run([str(spore_bin), "version"], env=env, text=True, capture_output=True, check=True).stdout.strip()

    failures = 0
    with output.open("w", encoding="utf-8") as rows:
        for iteration in range(1, args.iterations + 1):
            name = f"readiness-{os.getpid()}-{iteration}"
            run_from_ms: float | None = None
            run_from_status: int | None = None
            run_from_error = ""
            if args.include_run_from:
                run_from_argv = [str(spore_bin), "run", "--backend", args.backend, "--from", str(spore_dir), "--", "/bin/true"]
                one_shot, run_from_ms = run(run_from_argv, env)
                run_from_status = one_shot.returncode
                run_from_error = one_shot.stderr.strip()
            restore_argv = [str(spore_bin), "--json", "restore", str(spore_dir), "--name", name]
            if args.backend != "auto":
                restore_argv.extend(("--backend", args.backend))
            restored, restore_return_ms = run(restore_argv, env)
            restore_json: dict[str, object] = {}
            if restored.returncode == 0:
                try:
                    restore_json = json.loads(restored.stdout)
                except json.JSONDecodeError:
                    restored = subprocess.CompletedProcess(restored.args, 1, restored.stdout, "invalid restore JSON")

            first_exec_ms: float | None = None
            repeated_exec_ms: list[float] = []
            exec_errors: list[str] = []
            if restored.returncode == 0:
                first, first_exec_ms = run([str(spore_bin), "exec", name, "--", "/bin/true"], env)
                if first.returncode != 0:
                    exec_errors.append(first.stderr.strip())
                else:
                    for _ in range(args.repeated_execs):
                        repeated, repeated_ms = run([str(spore_bin), "exec", name, "--", "/bin/true"], env)
                        if repeated.returncode != 0:
                            exec_errors.append(repeated.stderr.strip())
                            break
                        repeated_exec_ms.append(repeated_ms)

            monitor_log_paths = list(runtime_dir.rglob(f"{name}/monitor.log"))
            monitor_log = "\n".join(
                path.read_text(encoding="utf-8", errors="replace") for path in monitor_log_paths
            )
            restore_metrics = parse_restore_metrics(f"{restored.stderr}\n{monitor_log}")
            removed, cleanup_ms = run([str(spore_bin), "rm", name], env)
            timing = restore_json.get("timing") if isinstance(restore_json.get("timing"), dict) else {}
            has_readiness_contract = isinstance(timing.get("wait_exec_ready_ms"), (int, float))
            exec_ready_ms = restore_return_ms if has_readiness_contract else (
                restore_return_ms + first_exec_ms if first_exec_ms is not None else None
            )
            ok = (run_from_status in (None, 0) and restored.returncode == 0 and not exec_errors and
                  len(repeated_exec_ms) == args.repeated_execs and removed.returncode == 0)
            failures += 0 if ok else 1
            row = {
                "schema": "spore.named-restore-readiness.v1",
                "iteration": iteration,
                "backend": args.backend,
                "spore_version": version,
                "spore_dir": str(spore_dir),
                "run_from_noop_ms": run_from_ms,
                "run_from_status": run_from_status,
                "restore_return_ms": restore_return_ms,
                "exec_ready_ms": exec_ready_ms,
                "exec_ready_source": "restore_contract" if has_readiness_contract else "first_noop_completion",
                "exec_ready_wait_ms": timing.get("wait_exec_ready_ms"),
                "restore_total_ms": timing.get("total_ms"),
                "restore_source": restore_metrics.get("mode"),
                "restore_ram_mib": restore_metrics.get("ram_mib"),
                "backend_memory_ms": restore_metrics.get("memory_ms"),
                "backend_state_ms": restore_metrics.get("state_ms"),
                "backend_pre_run_ms": restore_metrics.get("pre_run_ms"),
                "first_noop_exec_ms": first_exec_ms,
                "repeated_exec_ms": repeated_exec_ms,
                "repeated_exec_median_ms": statistics.median(repeated_exec_ms) if repeated_exec_ms else None,
                "cleanup_ms": cleanup_ms,
                "restore_status": restored.returncode,
                "cleanup_status": removed.returncode,
                "error": run_from_error or restored.stderr.strip() or "; ".join(exec_errors) or removed.stderr.strip(),
            }
            rows.write(json.dumps(row, separators=(",", ":")) + "\n")
            rows.flush()
            print(
                f"iteration {iteration}/{args.iterations}: run_from={run_from_ms}ms restore={restore_return_ms:.3f}ms "
                f"ready={row['exec_ready_wait_ms']}ms source={row['restore_source']} "
                f"memory={row['backend_memory_ms']}ms state={row['backend_state_ms']}ms "
                f"pre_run={row['backend_pre_run_ms']}ms first={first_exec_ms}ms "
                f"repeated_median={row['repeated_exec_median_ms']}ms ok={ok}",
                file=sys.stderr,
            )

    if runtime_owner is not None:
        runtime_owner.cleanup()
    print(output)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
