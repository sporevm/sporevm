#!/usr/bin/env python3
"""Compare native and SporeVM guest memory-copy throughput."""

from __future__ import annotations

import argparse
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


VERSION = "1.0"
DEFAULT_IMAGE = "docker.io/library/node:22-alpine"
DEFAULT_PLATFORM = "linux/arm64"
DEFAULT_ENVIRONMENTS = ("native", "spore_run")
ALL_ENVIRONMENTS = ("native", "spore_run", "spore_exec")


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


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


def parse_csv(value: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in value.split(",") if part.strip())


def json_dump(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


def node_program(size_mib: int, copies: int, warmup_copies: int) -> str:
    return (
        f"m={size_mib},c={copies},w={warmup_copies},s=m*1048576,a=Buffer.alloc(s,90),b=Buffer.alloc(s);"
        "while(w--)a.copy(b);t=process.hrtime.bigint();x=0;"
        "for(i=0;i<c;i++){a.copy(b);x+=b[i*4096%s]}"
        "e=Number(process.hrtime.bigint()-t)/1e9;console.log(JSON.stringify([m,c,e,m*c/e,x]))"
    )


def run_command(
    argv: list[str],
    *,
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    timeout_s: int,
) -> tuple[int, float, str | None]:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
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
        return completed.returncode, time.perf_counter() - started, None
    except OSError as err:
        return 127, time.perf_counter() - started, str(err)
    except subprocess.TimeoutExpired:
        return 124, time.perf_counter() - started, f"timed out after {timeout_s}s"


def parse_benchmark_output(path: Path) -> dict[str, object] | None:
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                return None
            if isinstance(value, dict) and value.get("schema") == "spore.memory_throughput.v1":
                return value
            if isinstance(value, list) and len(value) >= 5:
                size_mib, copies, copy_s, copy_mib_s, checksum = value[:5]
                if all(isinstance(item, (int, float)) for item in (size_mib, copies, copy_s, copy_mib_s, checksum)):
                    return {
                        "schema": "spore.memory_throughput.v1",
                        "size_mib": size_mib,
                        "copies": copies,
                        "copied_mib": size_mib * copies,
                        "copy_s": copy_s,
                        "copy_mib_s": copy_mib_s,
                        "checksum": checksum,
                    }
            return None
    return None


def stat(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "max": None, "mean": None, "median": None}
    ordered = sorted(values)
    return {
        "count": len(values),
        "min": ordered[0],
        "max": ordered[-1],
        "mean": statistics.fmean(ordered),
        "median": statistics.median(ordered),
    }


def emit_row(raw_path: Path, rows: list[dict[str, object]], row: dict[str, object]) -> None:
    enriched = {"version": VERSION, "created_at": utc_now(), **row}
    append_jsonl(raw_path, enriched)
    rows.append(enriched)


def timed_row(
    *,
    run_id: str,
    environment: str,
    iteration: int,
    status: int,
    wall_s: float,
    error: str | None,
    stdout: Path,
    stderr: Path,
) -> dict[str, object]:
    parsed = parse_benchmark_output(stdout)
    copy_s = parsed.get("copy_s") if parsed else None
    copy_mib_s = parsed.get("copy_mib_s") if parsed else None
    success = status == 0 and isinstance(copy_s, (int, float)) and isinstance(copy_mib_s, (int, float))
    return {
        "run_id": run_id,
        "row_type": "measurement",
        "environment": environment,
        "iteration": iteration,
        "success": success,
        "status": status,
        "error": error,
        "wall_s": wall_s,
        "copy_s": copy_s,
        "copy_mib_s": copy_mib_s,
        "overhead_s": wall_s - float(copy_s) if isinstance(copy_s, (int, float)) and wall_s >= float(copy_s) else None,
        "result": parsed,
        "stdout_path": str(stdout),
        "stderr_path": str(stderr),
    }


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.root = repo_root()
        self.run_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
        self.output_dir = Path(args.output_dir).resolve()
        self.run_dir = self.output_dir / self.run_id
        self.log_dir = self.run_dir / "logs"
        self.raw_path = self.run_dir / "results.jsonl"
        self.summary_path = self.run_dir / "summary.json"
        self.rootfs_cache_dir = Path(args.rootfs_cache_dir).resolve() if args.rootfs_cache_dir else self.run_dir / "rootfs-cache"
        self.runtime_dir = self.run_dir / "runtime"
        self.spore_bin = Path(args.spore_bin).resolve()
        self.env = os.environ.copy()
        self.env["SPOREVM_ROOTFS_CACHE_DIR"] = str(self.rootfs_cache_dir)
        self.env["SPOREVM_RUNTIME_DIR"] = str(self.runtime_dir)
        self.effective_image = args.image
        self.program = node_program(args.size_mib, args.copies, args.warmup_copies)
        self.rows: list[dict[str, object]] = []

    def setup(self) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.rootfs_cache_dir.mkdir(parents=True, exist_ok=True)
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.runtime_dir, 0o700)
        if any(env.startswith("spore") for env in self.args.environments):
            if self.args.build:
                self.build()
            if not self.spore_bin.is_file() or not os.access(self.spore_bin, os.X_OK):
                die(f"spore binary not executable: {self.spore_bin}")
            self.resolve_image()
            if self.args.prewarm_rootfs:
                self.prewarm_rootfs()
        if "native" in self.args.environments and shutil.which(self.args.node_bin) is None:
            die(f"native node binary not found: {self.args.node_bin}")

    def build(self) -> None:
        cmd = ["mise", "run", "build"] if shutil.which("mise") else ["zig", "build"]
        stdout = self.log_dir / "build.stdout"
        stderr = self.log_dir / "build.stderr"
        status, wall_s, error = run_command(cmd, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=600)
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "build",
            "success": status == 0,
            "status": status,
            "wall_s": wall_s,
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
        status, wall_s, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        resolved = stdout.read_text(encoding="utf-8").strip() if stdout.exists() else ""
        success = status == 0 and "@sha256:" in resolved
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "rootfs_resolve",
            "success": success,
            "status": status,
            "wall_s": wall_s,
            "error": error,
            "requested_image": self.args.image,
            "image": resolved,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if not success:
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
            self.args.memory,
            "--",
            "/bin/true",
        ]
        status, wall_s, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "rootfs_prewarm",
            "success": status == 0,
            "status": status,
            "wall_s": wall_s,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"rootfs prewarm failed status={status} stderr={stderr}")

    def run_native_iteration(self, iteration: int) -> None:
        prefix = self.log_dir / "native" / f"{iteration:06d}"
        stdout = prefix.with_suffix(".stdout")
        stderr = prefix.with_suffix(".stderr")
        status, wall_s, error = run_command(
            [self.args.node_bin, "-e", self.program],
            env=self.env,
            stdout_path=stdout,
            stderr_path=stderr,
            timeout_s=self.args.timeout_s,
        )
        emit_row(self.raw_path, self.rows, timed_row(
            run_id=self.run_id,
            environment="native",
            iteration=iteration,
            status=status,
            wall_s=wall_s,
            error=error,
            stdout=stdout,
            stderr=stderr,
        ))

    def run_native(self) -> None:
        for iteration in range(1, self.args.iterations + 1):
            self.run_native_iteration(iteration)

    def run_spore_run_iteration(self, iteration: int) -> None:
        prefix = self.log_dir / "spore_run" / f"{iteration:06d}"
        stdout = prefix.with_suffix(".stdout")
        stderr = prefix.with_suffix(".stderr")
        argv = [
            str(self.spore_bin),
            "run",
            "--backend",
            self.args.backend,
            "--image",
            self.effective_image,
            "--memory",
            self.args.memory,
            "--",
            self.args.spore_node_bin,
            "-e",
            self.program,
        ]
        status, wall_s, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        emit_row(self.raw_path, self.rows, timed_row(
            run_id=self.run_id,
            environment="spore_run",
            iteration=iteration,
            status=status,
            wall_s=wall_s,
            error=error,
            stdout=stdout,
            stderr=stderr,
        ))

    def run_spore_run(self) -> None:
        for iteration in range(1, self.args.iterations + 1):
            self.run_spore_run_iteration(iteration)

    def run_spore_exec(self) -> None:
        vm_name = f"spore-mem-{self.run_id}"
        create_stdout = self.log_dir / "spore_exec" / "create.stdout"
        create_stderr = self.log_dir / "spore_exec" / "create.stderr"
        console_log = self.log_dir / "spore_exec" / "console.log"
        create_argv = [
            str(self.spore_bin),
            "create",
            "--backend",
            self.args.backend,
            "--image",
            self.effective_image,
            "--memory",
            self.args.memory,
            "--timeout",
            f"{self.args.timeout_s}s",
            vm_name,
            "--console-log",
            str(console_log),
        ]
        status, wall_s, error = run_command(create_argv, env=self.env, stdout_path=create_stdout, stderr_path=create_stderr, timeout_s=self.args.timeout_s)
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "spore_exec_create",
            "success": status == 0,
            "status": status,
            "wall_s": wall_s,
            "error": error,
            "stdout_path": str(create_stdout),
            "stderr_path": str(create_stderr),
            "console_log": str(console_log),
        })
        if status != 0:
            die(f"spore create failed status={status} stderr={create_stderr}")
        try:
            self.exec_ready_probe(vm_name)
            for iteration in range(1, self.args.iterations + 1):
                prefix = self.log_dir / "spore_exec" / f"{iteration:06d}"
                stdout = prefix.with_suffix(".stdout")
                stderr = prefix.with_suffix(".stderr")
                argv = [str(self.spore_bin), "exec", vm_name, "--", self.args.spore_node_bin, "-e", self.program]
                status, wall_s, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
                emit_row(self.raw_path, self.rows, timed_row(
                    run_id=self.run_id,
                    environment="spore_exec",
                    iteration=iteration,
                    status=status,
                    wall_s=wall_s,
                    error=error,
                    stdout=stdout,
                    stderr=stderr,
                ))
        finally:
            self.rm_vm(vm_name)

    def exec_ready_probe(self, vm_name: str) -> None:
        stdout = self.log_dir / "spore_exec" / "ready.stdout"
        stderr = self.log_dir / "spore_exec" / "ready.stderr"
        argv = [str(self.spore_bin), "exec", vm_name, "--", self.args.spore_node_bin, "--version"]
        status, wall_s, error = run_command(argv, env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "spore_exec_ready",
            "success": status == 0,
            "status": status,
            "wall_s": wall_s,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })
        if status != 0:
            die(f"spore exec ready probe failed status={status} stderr={stderr}")

    def rm_vm(self, vm_name: str) -> None:
        stdout = self.log_dir / "spore_exec" / "rm.stdout"
        stderr = self.log_dir / "spore_exec" / "rm.stderr"
        status, wall_s, error = run_command([str(self.spore_bin), "rm", vm_name], env=self.env, stdout_path=stdout, stderr_path=stderr, timeout_s=self.args.timeout_s)
        emit_row(self.raw_path, self.rows, {
            "run_id": self.run_id,
            "row_type": "setup",
            "phase": "spore_exec_rm",
            "success": status == 0,
            "status": status,
            "wall_s": wall_s,
            "error": error,
            "stdout_path": str(stdout),
            "stderr_path": str(stderr),
        })

    def run(self) -> None:
        self.setup()
        if "spore_exec" not in self.args.environments:
            for iteration in range(1, self.args.iterations + 1):
                if "native" in self.args.environments:
                    self.run_native_iteration(iteration)
                if "spore_run" in self.args.environments:
                    self.run_spore_run_iteration(iteration)
        else:
            if "native" in self.args.environments:
                self.run_native()
            if "spore_run" in self.args.environments:
                self.run_spore_run()
        if "spore_exec" in self.args.environments:
            self.run_spore_exec()
        summary = self.summary()
        json_dump(self.summary_path, summary)
        json_dump(self.output_dir / "latest-summary.json", summary)
        print(f"memory throughput benchmark ok: results={self.raw_path} summary={self.summary_path}")

    def summary(self) -> dict[str, object]:
        measurements = [row for row in self.rows if row.get("row_type") == "measurement" and row.get("success")]
        by_env: dict[str, list[dict[str, object]]] = {}
        for row in measurements:
            by_env.setdefault(str(row["environment"]), []).append(row)
        results: dict[str, object] = {}
        for env, rows in sorted(by_env.items()):
            results[env] = {
                "copy_mib_s": stat([float(row["copy_mib_s"]) for row in rows]),
                "copy_s": stat([float(row["copy_s"]) for row in rows]),
                "wall_s": stat([float(row["wall_s"]) for row in rows]),
                "overhead_s": stat([float(row["overhead_s"]) for row in rows if isinstance(row.get("overhead_s"), (int, float))]),
            }
        comparisons: dict[str, object] = {}
        native = results.get("native")
        native_copy_mib_s = nested_median(native, "copy_mib_s")
        native_copy_s = nested_median(native, "copy_s")
        if native_copy_mib_s and native_copy_s:
            for env, result in results.items():
                if env == "native":
                    continue
                env_copy_mib_s = nested_median(result, "copy_mib_s")
                env_copy_s = nested_median(result, "copy_s")
                if env_copy_mib_s and env_copy_s:
                    comparisons[f"{env}_vs_native"] = {
                        "copy_throughput_gap_pct": (native_copy_mib_s - env_copy_mib_s) / native_copy_mib_s * 100.0,
                        "copy_time_slowdown_pct": (env_copy_s / native_copy_s - 1.0) * 100.0,
                        "wall_overhead_s": nested_median(result, "overhead_s"),
                    }
        return {
            "version": VERSION,
            "run_id": self.run_id,
            "generated_at": utc_now(),
            "config": {
                "environments": self.args.environments,
                "iterations": self.args.iterations,
                "size_mib": self.args.size_mib,
                "copies": self.args.copies,
                "warmup_copies": self.args.warmup_copies,
                "backend": self.args.backend,
                "memory": self.args.memory,
                "requested_image": self.args.image,
                "image": self.effective_image,
                "platform": self.args.platform,
                "prewarm_rootfs": self.args.prewarm_rootfs,
                "spore_bin": str(self.spore_bin),
                "rootfs_cache_dir": str(self.rootfs_cache_dir),
                "runtime_dir": str(self.runtime_dir),
            },
            "results": results,
            "comparisons": comparisons,
            "raw_results": str(self.raw_path),
        }


def nested_median(value: object, field: str) -> float | None:
    if not isinstance(value, dict):
        return None
    nested = value.get(field)
    if not isinstance(nested, dict):
        return None
    median = nested.get("median")
    return float(median) if isinstance(median, (int, float)) and math.isfinite(float(median)) else None


def self_test() -> None:
    program = node_program(4096, 48, 4)
    paths = [
        write_temp_output({"schema": "spore.memory_throughput.v1", "copy_s": 1, "copy_mib_s": 2}),
        write_temp_output([64, 48, 0.1, 30720, 4320]),
    ]
    try:
        parsed = parse_benchmark_output(paths[0])
        compact = parse_benchmark_output(paths[1])
        assert parsed and parsed["copy_mib_s"] == 2
        assert compact and compact["copied_mib"] == 3072
        assert stat([3, 1, 2])["median"] == 2
        assert nested_median({"x": {"median": 4}}, "x") == 4
        assert "s=m*1048576" in program
        assert "<<20" not in program
        assert len(program) <= 255
    finally:
        for path in paths:
            path.unlink(missing_ok=True)


def write_temp_output(value: object) -> Path:
    path = Path(os.environ.get("TMPDIR", "/tmp")) / f"sporevm-memory-throughput-self-test-{os.getpid()}-{uuid.uuid4().hex}.json"
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    return path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run parser/stat self-test and exit")
    parser.add_argument("--environments", default=",".join(DEFAULT_ENVIRONMENTS), help="Comma-separated subset: native,spore_run,spore_exec")
    parser.add_argument("-n", "--iterations", type=int, default=5)
    parser.add_argument("--size-mib", type=int, default=64)
    parser.add_argument("--copies", type=int, default=48)
    parser.add_argument("--warmup-copies", type=int, default=4)
    parser.add_argument("--output-dir", default="zig-cache/sporevm-memory-throughput")
    parser.add_argument("--rootfs-cache-dir", default="")
    parser.add_argument("--spore-bin", default=str(repo_root() / "zig-out/bin/spore"))
    parser.add_argument("--node-bin", default="node")
    parser.add_argument("--spore-node-bin", default="/usr/local/bin/node")
    parser.add_argument("--backend", default=infer_backend(), choices=("auto", "hvf", "kvm"))
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--platform", default=DEFAULT_PLATFORM)
    parser.add_argument("--memory", default="1gb")
    parser.add_argument("--timeout-s", type=int, default=120)
    parser.add_argument("--no-build", dest="build", action="store_false")
    parser.add_argument("--no-prewarm-rootfs", dest="prewarm_rootfs", action="store_false")
    parser.set_defaults(build=True, prewarm_rootfs=True)
    args = parser.parse_args(argv)
    args.environments = parse_csv(args.environments)
    for env in args.environments:
        if env not in ALL_ENVIRONMENTS:
            die(f"unknown environment: {env}")
    for name in ("iterations", "size_mib", "copies", "warmup_copies", "timeout_s"):
        if getattr(args, name) <= 0:
            die(f"--{name.replace('_', '-')} must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    Runner(args).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
