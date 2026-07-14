#!/usr/bin/env python3
"""Deterministic cleanup and signal tests for named-restore-readiness.py."""

from __future__ import annotations

import contextlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time


BENCHMARK = pathlib.Path(__file__).with_name("named-restore-readiness.py")
WRAPPER = pathlib.Path(__file__).parents[1] / "ci" / "buildkite-named-restore-readiness.sh"
FAKE_SPORE = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

args = sys.argv[1:]
while args and args[0] in ("--debug", "--json"):
    args.pop(0)
command = args[0]
runtime = pathlib.Path(os.environ["SPOREVM_RUNTIME_DIR"])

if command == "version":
    print("spore 0.test")
    raise SystemExit(0)

if command == "run":
    raise SystemExit(0)

if command == "restore":
    name = args[args.index("--name") + 1]
    vm_dir = runtime / "vms" / name
    vm_dir.mkdir(parents=True)
    lease_dir = runtime / "leases"
    lease_dir.mkdir(parents=True, exist_ok=True)
    (lease_dir / f"lease-{name}.json").write_text('{"schema":"fake"}\n', encoding="utf-8")
    monitor = subprocess.Popen(
        ["sleep", "300"],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    (vm_dir / "pid").write_text(str(monitor.pid), encoding="utf-8")
    proof_metric = (
        "debug: local RAM backing proof metrics: operation=validate status=ok "
        "source=local_backing reason=proof_valid schema=2 verity=sha256 "
        "validation_us=10 precharge_us=2\n"
    )
    if os.environ.get("FAKE_MISSING_PRECHARGE") == "1":
        proof_metric = proof_metric.replace(" precharge_us=2", "")
    restore_metric = (
        "info: kvm restore metrics: mode=local_backing ram_mib=1024 chunks=1 "
        "nonzero_chunks=1 manifest_ms=0 map_ram_ms=0 memory_ms=0 state_ms=1 pre_run_ms=2\n"
    )
    readiness_metric = (
        "info: monitor readiness metrics: attach_ms=0 connect_request_delivered_ms=1 "
        "connect_ms=2 request_delivered_ms=3 guest_timing_ms=4 response_ms=5 ready_ms=6\n"
    )
    metrics = proof_metric + restore_metric + readiness_metric
    if os.environ.get("FAKE_DUPLICATE_METRICS") == "1":
        metrics += proof_metric + restore_metric + readiness_metric
    (vm_dir / "monitor.log").write_text(metrics, encoding="utf-8")
    (vm_dir / "monitor-timing.json").write_text(json.dumps({
        "version": 1,
        "ready_after_start_ms": 6,
        "readiness_attach_ms": 0,
        "readiness_connect_request_delivered_ms": 1,
        "readiness_connect_ms": 2,
        "readiness_request_delivered_ms": 3,
        "readiness_guest_timing_ms": 4,
        "readiness_response_ms": 5,
        "backend_restore_memory_ms": 0,
        "backend_restore_state_ms": 1,
        "backend_restore_pre_run_ms": 2,
    }), encoding="utf-8")
    pathlib.Path(os.environ["FAKE_RESTORE_STARTED"]).touch()
    if os.environ.get("FAKE_INVALID_RESTORE_JSON") == "1":
        print("{invalid")
    else:
        print(json.dumps({
            "schema": "spore.lifecycle.v1",
            "schema_version": 1,
            "action": "restored",
            "name": name,
            "state": "ready",
            "timing": {"prepare_ms": 1, "spawn_monitor_ms": 2, "wait_exec_ready_ms": 3, "total_ms": 6},
        }))
    raise SystemExit(0)

if command == "exec":
    if os.environ.get("FAKE_BLOCK_EXEC") == "1":
        pathlib.Path(os.environ["FAKE_EXEC_STARTED"]).touch()
        time.sleep(300)
    raise SystemExit(0)

if command == "rm":
    name = args[1]
    vm_dir = runtime / "vms" / name
    if os.environ.get("FAKE_RM_FAIL") == "1":
        with open(os.environ["FAKE_CLEANUP_LOG"], "a", encoding="utf-8") as fh:
            fh.write(name + "\n")
        raise SystemExit(1)
    try:
        pid = int((vm_dir / "pid").read_text(encoding="utf-8"))
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    except (FileNotFoundError, ValueError):
        pass
    shutil.rmtree(vm_dir, ignore_errors=True)
    if os.environ.get("FAKE_LEAK_LEASE") != "1":
        try:
            (runtime / "leases" / f"lease-{name}.json").unlink()
        except FileNotFoundError:
            pass
    with open(os.environ["FAKE_CLEANUP_LOG"], "a", encoding="utf-8") as fh:
        fh.write(name + "\n")
    raise SystemExit(0)

raise SystemExit(2)
'''


def wait_for(path: pathlib.Path, proc: subprocess.Popen[str], timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists() and proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    if not path.exists():
        stdout, stderr = proc.communicate(timeout=2)
        raise AssertionError(f"marker not created; status={proc.returncode} stdout={stdout!r} stderr={stderr!r}")


def assert_clean(runtime: pathlib.Path, cleanup_log: pathlib.Path) -> None:
    active = list((runtime / "vms").iterdir()) if (runtime / "vms").is_dir() else []
    assert active == [], f"active runtime directories remain: {active}"
    leases = list((runtime / "leases").iterdir()) if (runtime / "leases").is_dir() else []
    assert leases == [], f"active lease records remain: {leases}"
    assert cleanup_log.read_text(encoding="utf-8").strip(), "cleanup command was not called"


def stop_test_processes(proc: subprocess.Popen[str], runtime: pathlib.Path | None = None) -> None:
    if proc.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.communicate(timeout=2)
    if runtime is not None:
        for pid_path in runtime.glob("vms/*/pid"):
            with contextlib.suppress(OSError, ValueError):
                os.killpg(int(pid_path.read_text(encoding="utf-8")), signal.SIGKILL)


def benchmark_argv(root: pathlib.Path, fake_spore: pathlib.Path) -> list[str]:
    parent = root / "parent.spore"
    parent.mkdir()
    (parent / "manifest.json").write_text("{}\n", encoding="utf-8")
    return [
        sys.executable,
        str(BENCHMARK),
        "--spore-dir", str(parent),
        "--spore-bin", str(fake_spore),
        "--backend", "kvm",
        "--iterations", "1",
        "--repeated-execs", "1",
        "--runtime-dir", str(root / "runtime"),
        "--output", str(root / "rows.jsonl"),
        "--scenario", "cleanup-test",
        "--expected-source", "local_backing",
        "--expected-reason", "proof_valid",
        "--expected-ram-mib", "1024",
        "--timeout", "10",
        "--no-build",
    ]


def base_env(root: pathlib.Path) -> dict[str, str]:
    return os.environ | {
        "FAKE_RESTORE_STARTED": str(root / "restore-started"),
        "FAKE_EXEC_STARTED": str(root / "exec-started"),
        "FAKE_CLEANUP_LOG": str(root / "cleanup.log"),
        "PYTHONPYCACHEPREFIX": str(root / "pycache"),
    }


def run_case(
    *,
    invalid_json: bool = False,
    interrupt: signal.Signals | None = None,
    rm_fail: bool = False,
    missing_precharge: bool = False,
    duplicate_metrics: bool = False,
    leak_lease: bool = False,
) -> None:
    with tempfile.TemporaryDirectory(prefix="nr-test-", dir="/tmp") as raw_root:
        root = pathlib.Path(raw_root)
        fake_spore = root / "fake-spore"
        fake_spore.write_text(FAKE_SPORE, encoding="utf-8")
        fake_spore.chmod(0o700)
        env = base_env(root)
        if invalid_json:
            env["FAKE_INVALID_RESTORE_JSON"] = "1"
        if interrupt is not None:
            env["FAKE_BLOCK_EXEC"] = "1"
        if rm_fail:
            env["FAKE_RM_FAIL"] = "1"
        if missing_precharge:
            env["FAKE_MISSING_PRECHARGE"] = "1"
        if duplicate_metrics:
            env["FAKE_DUPLICATE_METRICS"] = "1"
        if leak_lease:
            env["FAKE_LEAK_LEASE"] = "1"
        proc = subprocess.Popen(
            benchmark_argv(root, fake_spore),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            if interrupt is not None:
                wait_for(root / "exec-started", proc)
                proc.send_signal(interrupt)
            stdout, stderr = proc.communicate(timeout=20)
            invalid = invalid_json or rm_fail or missing_precharge or duplicate_metrics or leak_lease
            expected = 128 + int(interrupt) if interrupt is not None else (1 if invalid else 0)
            assert proc.returncode == expected, (
                f"unexpected status={proc.returncode}, expected={expected}\nstdout={stdout}\nstderr={stderr}"
            )
            assert_clean(root / "runtime", root / "cleanup.log")
            if not invalid and interrupt is None:
                row = json.loads((root / "rows.jsonl").read_text(encoding="utf-8"))
                assert row["requested_name"] == "n1"
                assert row["scenario"] == "cleanup-test"
        finally:
            stop_test_processes(proc, root / "runtime")


def run_wrapper_signal_case(interrupt: signal.Signals) -> None:
    with tempfile.TemporaryDirectory(prefix="sporevm-named-wrapper-test-") as raw_root:
        root = pathlib.Path(raw_root)
        marker_dir = root / "markers"
        marker_dir.mkdir()
        named_scratch = root / "named-scratch"
        findmnt_called = marker_dir / "findmnt-called"
        fake_bin = root / "bin"
        fake_bin.mkdir()
        (fake_bin / "uname").write_text(
            '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && echo aarch64 || echo Linux\n',
            encoding="utf-8",
        )
        (fake_bin / "findmnt").write_text(
            f'#!/usr/bin/env bash\ntouch "{findmnt_called}"\necho zfs\n',
            encoding="utf-8",
        )
        (fake_bin / "uname").chmod(0o700)
        (fake_bin / "findmnt").chmod(0o700)
        env = os.environ | {
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
            "SPOREVM_NAMED_RESTORE_SIGNAL_SELF_TEST": "1",
            "SPOREVM_NAMED_RESTORE_SIGNAL_SELF_TEST_DIR": str(marker_dir),
            "SPOREVM_NAMED_RESTORE_SIGNAL_TEST_CHILD": str(pathlib.Path(__file__).resolve()),
            "SPOREVM_BENCHMARK_SCRATCH_ROOT": str(root / "inherited-zfs"),
            "SPOREVM_NAMED_RESTORE_SCRATCH_ROOT": str(named_scratch),
            "SPOREVM_NAMED_RESTORE_OUTPUT_DIR": str(root / "output"),
        }
        proc = subprocess.Popen(
            ["bash", str(WRAPPER)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            wait_for(marker_dir / "child-started", proc)
            workdir_path = pathlib.Path((marker_dir / "wrapper-workdir").read_text(encoding="utf-8").strip())
            assert workdir_path.is_dir()
            assert workdir_path.parent == named_scratch, "inherited general benchmark scratch won"
            assert workdir_path.name.startswith("nr."), "wrapper used a long workdir prefix"
            proc.send_signal(interrupt)
            wait_for(marker_dir / "cleanup-started", proc)
            assert proc.poll() is None, "wrapper exited before its child completed cleanup"
            assert workdir_path.is_dir(), "wrapper deleted its workdir before child cleanup"
            (marker_dir / "allow-cleanup").touch()
            stdout, stderr = proc.communicate(timeout=10)
            expected = 128 + int(interrupt)
            assert proc.returncode == expected, (
                f"wrapper status={proc.returncode}, expected={expected}\nstdout={stdout}\nstderr={stderr}"
            )
            assert (marker_dir / "cleanup-complete").is_file(), "wrapper child cleanup did not finish"
            assert not findmnt_called.exists(), "signal self-test ran the product scratch preflight"
            assert not workdir_path.exists(), "wrapper workdir remains after child cleanup and exit"
        finally:
            stop_test_processes(proc)


def run_wrapper_child(marker_dir: pathlib.Path, wrapper_workdir: pathlib.Path) -> None:
    def finish(signum: int, _frame: object) -> None:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        (marker_dir / "cleanup-started").touch()
        deadline = time.monotonic() + 10
        while not (marker_dir / "allow-cleanup").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not (marker_dir / "allow-cleanup").exists():
            raise SystemExit(97)
        if not wrapper_workdir.is_dir():
            raise SystemExit(98)
        (marker_dir / "cleanup-complete").touch()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, finish)
    signal.signal(signal.SIGTERM, finish)
    (marker_dir / "child-started").touch()
    while True:
        time.sleep(1)


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "--wrapper-child":
        run_wrapper_child(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        return
    run_case()
    run_case(invalid_json=True)
    run_case(rm_fail=True)
    run_case(missing_precharge=True)
    run_case(duplicate_metrics=True)
    run_case(leak_lease=True)
    run_case(interrupt=signal.SIGINT)
    run_case(interrupt=signal.SIGTERM)
    run_case(interrupt=signal.SIGTERM, rm_fail=True)
    run_wrapper_signal_case(signal.SIGINT)
    run_wrapper_signal_case(signal.SIGTERM)
    print("cleanup/signal self-test ok")


if __name__ == "__main__":
    main()
