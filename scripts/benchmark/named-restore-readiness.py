#!/usr/bin/env python3
"""Benchmark and gate persistent named restore readiness."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from named_restore_readiness import (
    EVIDENCE_SCHEMA,
    MANAGED_KERNEL_PIN,
    MIN_LOCAL_SPEEDUP,
    NON_REGRESSION_ABSOLUTE_MS,
    NON_REGRESSION_RELATIVE,
    PINNED_IMAGE_RE,
    ROW_SCHEMA,
    BenchmarkError,
    BenchmarkSignal,
    CommandResult,
    CommandRunner,
    SignalState,
    active_lease_snapshot,
    binary_identity,
    bounded_public_text,
    cleanup_named,
    debug_spore_wrapper,
    file_identity,
    filesystem_info,
    git_identity,
    host_identity,
    is_nonnegative_number,
    is_number,
    lane_summary,
    managed_kernel_identities,
    make_tree_immutable,
    make_tree_writable,
    memory_mib,
    normalize_paths,
    non_regression_gates,
    parse_proof_metrics,
    parse_readiness_metrics,
    parse_restore_metrics_all,
    performance_gate,
    read_monitor_log,
    read_monitor_timing,
    release_scratch_precondition,
    require_managed_kernel_pin,
    require_single_proof_metric,
    self_test,
    sha256_file,
    verify_release_inputs,
)

def restore_name(iteration: int) -> str:
    return f"n{iteration}"


def run_lane(
    *,
    runner: CommandRunner,
    spore_dir: pathlib.Path,
    real_spore_bin: pathlib.Path,
    backend: str,
    vcpus: int,
    iterations: int,
    repeated_execs: int,
    output: pathlib.Path,
    runtime_dir: pathlib.Path,
    scenario: str,
    expected_source: str,
    expected_reason: str | None,
    expected_proof_schema: int | None,
    expected_proof_verity: str | None,
    expected_ram_mib: int,
    timeout_s: float,
    include_run_from: bool,
    base_env: dict[str, str],
    require_readiness_phases: bool = True,
    path_aliases: dict[str, str] | None = None,
) -> list[dict[str, object]]:
    runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime_dir.chmod(0o700)
    spore_bin = debug_spore_wrapper(real_spore_bin, runtime_dir)
    env = base_env.copy()
    env["SPOREVM_RUNTIME_DIR"] = str(runtime_dir)
    version_result = runner.run([str(spore_bin), "version"], env, timeout_s)
    if version_result.returncode != 0:
        raise BenchmarkError(f"{scenario}: spore version failed: {version_result.stderr.strip()}")
    version = version_result.stdout.strip()
    rows: list[dict[str, object]] = []
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as row_file:
        for iteration in range(1, iterations + 1):
            name = restore_name(iteration)
            run_from: CommandResult | None = None
            restored: CommandResult | None = None
            first: CommandResult | None = None
            repeated_results: list[CommandResult] = []
            cleanup: dict[str, object] | None = None
            restore_json: dict[str, object] = {}
            parse_error = ""
            monitor_log = ""
            monitor_timing: dict[str, object] = {}
            if include_run_from:
                run_from = runner.run(
                    [str(spore_bin), "run", "--backend", backend, "--from", str(spore_dir), "--", "/bin/true"],
                    env,
                    timeout_s,
                )
            leases_before = active_lease_snapshot(runtime_dir)
            if leases_before:
                raise BenchmarkError(f"{scenario}: task-owned runtime has active leases before named restore")
            try:
                restore_argv = [str(spore_bin), "--json", "restore", str(spore_dir), "--name", name, "--backend", backend]
                restored = runner.run(restore_argv, env, timeout_s)
                if restored.returncode == 0:
                    try:
                        parsed = json.loads(restored.stdout)
                        if not isinstance(parsed, dict):
                            raise ValueError("restore JSON is not an object")
                        restore_json = parsed
                    except (json.JSONDecodeError, ValueError) as err:
                        parse_error = f"invalid restore JSON: {err}"
                if restored.returncode == 0 and not parse_error:
                    first = runner.run([str(spore_bin), "exec", name, "--", "/bin/true"], env, timeout_s)
                    if first.returncode == 0:
                        for _ in range(repeated_execs):
                            repeated = runner.run([str(spore_bin), "exec", name, "--", "/bin/true"], env, timeout_s)
                            repeated_results.append(repeated)
                            if repeated.returncode != 0:
                                break
            finally:
                try:
                    monitor_log = read_monitor_log(runtime_dir, name)
                    monitor_timing = read_monitor_timing(runtime_dir, name)
                finally:
                    cleanup = cleanup_named(
                        runner, spore_bin, env, runtime_dir, name, leases_before, min(timeout_s, 15)
                    )

            assert restored is not None and cleanup is not None
            if runner.signals.signum is not None:
                raise BenchmarkSignal(runner.signals.signum)
            restore_metrics_rows = parse_restore_metrics_all(monitor_log)
            restore_metrics = restore_metrics_rows[0] if len(restore_metrics_rows) == 1 else {}
            readiness_metrics_rows = parse_readiness_metrics(monitor_log)
            readiness_metrics = monitor_timing if monitor_timing else (readiness_metrics_rows[0] if len(readiness_metrics_rows) == 1 else {})
            proof_metrics = parse_proof_metrics(monitor_log, "validate")
            proof_metric = proof_metrics[0] if len(proof_metrics) == 1 else {}
            proof_plan_source = proof_metric.get("source")
            proof_source = "eager_chunks" if proof_plan_source == "chunks" and restore_metrics.get("mode") == "eager_chunks" else proof_plan_source
            timing = restore_json.get("timing") if isinstance(restore_json.get("timing"), dict) else {}
            repeated_ms = [item.elapsed_ms for item in repeated_results if item.returncode == 0]
            errors = [
                parse_error,
                "" if run_from is None or run_from.returncode == 0 else run_from.stderr.strip(),
                "" if restored.returncode == 0 else restored.stderr.strip(),
                "" if first is None or first.returncode == 0 else first.stderr.strip(),
                next((item.stderr.strip() for item in repeated_results if item.returncode != 0), ""),
                "" if cleanup["status"] == 0 else "named cleanup failed",
                "" if cleanup["runtime_absent"] else "named runtime remains after cleanup",
                "" if cleanup["pid_absent"] else "named monitor remains alive after cleanup",
            ]
            row = {
                "schema": ROW_SCHEMA,
                "scenario": scenario,
                "iteration": iteration,
                "backend": restore_metrics.get("backend"),
                "requested_backend": backend,
                "vcpus": vcpus,
                "spore_version": version,
                "spore_dir_role": scenario.split("_vcpu", 1)[0],
                "expected_restore_source": expected_source,
                "expected_restore_reason": expected_reason,
                "run_from_noop_ms": run_from.elapsed_ms if run_from else None,
                "run_from_status": run_from.returncode if run_from else None,
                "restore_return_ms": restored.elapsed_ms,
                "restore_schema": restore_json.get("schema"),
                "restore_schema_version": restore_json.get("schema_version"),
                "restore_action": restore_json.get("action"),
                "requested_name": name,
                "restore_name": restore_json.get("name"),
                "restore_state": restore_json.get("state"),
                "exec_ready_source": "restore_contract" if "wait_exec_ready_ms" in timing else None,
                "restore_prepare_ms": timing.get("prepare_ms"),
                "restore_spawn_monitor_ms": timing.get("spawn_monitor_ms"),
                "exec_ready_wait_ms": timing.get("wait_exec_ready_ms"),
                "restore_total_ms": timing.get("total_ms"),
                "restore_source": restore_metrics.get("mode"),
                "restore_metric_count": len(restore_metrics_rows),
                "restore_reason": proof_metric.get("reason"),
                "restore_ram_mib": restore_metrics.get("ram_mib"),
                "backend_memory_ms": monitor_timing.get("backend_restore_memory_ms") if monitor_timing.get("backend_restore_memory_ms") is not None else restore_metrics.get("memory_ms"),
                "backend_state_ms": monitor_timing.get("backend_restore_state_ms") if monitor_timing.get("backend_restore_state_ms") is not None else restore_metrics.get("state_ms"),
                "backend_pre_run_ms": monitor_timing.get("backend_restore_pre_run_ms") if monitor_timing.get("backend_restore_pre_run_ms") is not None else restore_metrics.get("pre_run_ms"),
                "readiness_metric_count": 1 if readiness_metrics else 0,
                "readiness_attach_ms": readiness_metrics.get("readiness_attach_ms", readiness_metrics.get("attach_ms")),
                "readiness_connect_request_delivered_ms": readiness_metrics.get("readiness_connect_request_delivered_ms", readiness_metrics.get("connect_request_delivered_ms")),
                "readiness_connect_ms": readiness_metrics.get("readiness_connect_ms", readiness_metrics.get("connect_ms")),
                "readiness_request_delivered_ms": readiness_metrics.get("readiness_request_delivered_ms", readiness_metrics.get("request_delivered_ms")),
                "readiness_guest_timing_ms": readiness_metrics.get("readiness_guest_timing_ms", readiness_metrics.get("guest_timing_ms")),
                "readiness_response_ms": readiness_metrics.get("readiness_response_ms", readiness_metrics.get("response_ms")),
                "readiness_ready_ms": readiness_metrics.get("ready_after_start_ms", readiness_metrics.get("ready_ms")),
                "proof_schema_version": proof_metric.get("schema"),
                "proof_metric_count": len(proof_metrics),
                "proof_status": proof_metric.get("status"),
                "proof_source": proof_source,
                "proof_plan_source": proof_plan_source,
                "proof_verity": proof_metric.get("verity"),
                "proof_validation_us": proof_metric.get("validation_us"),
                "proof_precharge_us": proof_metric.get("precharge_us"),
                "first_noop_exec_ms": first.elapsed_ms if first else None,
                "first_exec_status": first.returncode if first else None,
                "repeated_exec_ms": repeated_ms,
                "repeated_exec_statuses": [item.returncode for item in repeated_results],
                "repeated_exec_median_ms": statistics.median(repeated_ms) if repeated_ms else None,
                "cleanup_ms": cleanup["elapsed_ms"],
                "cleanup_status": cleanup["status"],
                "cleanup_forced_pid": cleanup["forced_pid_cleanup"],
                "cleanup_lease_count_before": cleanup["lease_count_before"],
                "cleanup_lease_count_after_rm": cleanup["lease_count_after_rm"],
                "cleanup_lease_count_after": cleanup["lease_count_after"],
                "cleanup_lease_restored": cleanup["lease_restored"],
                "cleanup_forced_lease": cleanup["forced_lease_cleanup"],
                "cleanup_runtime_absent": cleanup["runtime_absent"],
                "cleanup_pid_absent": cleanup["pid_absent"],
                "restore_status": restored.returncode,
                "error": next((value for value in errors if value), ""),
                "commands": {
                    "run_from": run_from.evidence() if run_from else None,
                    "restore": restored.evidence(),
                    "first_exec": first.evidence() if first else None,
                    "repeated_exec": [item.evidence() for item in repeated_results],
                    "cleanup": cleanup["command"],
                    "monitor_log": bounded_public_text(monitor_log, path_aliases or runner.path_aliases),
                },
            }
            public_row = normalize_paths(row, path_aliases or runner.path_aliases)
            assert isinstance(public_row, dict)
            rows.append(public_row)
            row_file.write(json.dumps(public_row, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n")
            row_file.flush()
            print(
                f"{scenario} {iteration}/{iterations}: restore={restored.elapsed_ms:.3f}ms "
                f"wait={row['exec_ready_wait_ms']} source={row['restore_source']} "
                f"reason={row['restore_reason']} memory={row['backend_memory_ms']}ms",
                file=sys.stderr,
            )
    validate_rows(
        rows,
        scenario=scenario,
        iterations=iterations,
        repeated_execs=repeated_execs,
        backend=backend,
        vcpus=vcpus,
        expected_source=expected_source,
        expected_reason=expected_reason,
        expected_proof_schema=expected_proof_schema,
        expected_proof_verity=expected_proof_verity,
        expected_ram_mib=expected_ram_mib,
        include_run_from=include_run_from,
        require_readiness_phases=require_readiness_phases,
    )
    return rows


def validate_rows(
    rows: list[dict[str, object]],
    *,
    scenario: str,
    iterations: int,
    repeated_execs: int,
    backend: str,
    vcpus: int,
    expected_source: str,
    expected_reason: str | None,
    expected_proof_schema: int | None,
    expected_proof_verity: str | None,
    expected_ram_mib: int,
    include_run_from: bool,
    require_readiness_phases: bool = True,
) -> None:
    errors: list[str] = []
    if len(rows) != iterations:
        errors.append(f"expected {iterations} rows, got {len(rows)}")
    actual_iterations = [row.get("iteration") for row in rows]
    if actual_iterations != list(range(1, iterations + 1)):
        errors.append(f"iterations must be exactly 1..{iterations}, got {actual_iterations}")
    for index, row in enumerate(rows, 1):
        prefix = f"row {index}"
        exact = {
            "schema": ROW_SCHEMA,
            "scenario": scenario,
            "backend": backend,
            "requested_backend": backend,
            "vcpus": vcpus,
            "restore_schema": "spore.lifecycle.v1",
            "restore_schema_version": 1,
            "restore_action": "restored",
            "restore_state": "ready",
            "exec_ready_source": "restore_contract",
            "restore_source": expected_source,
            "restore_metric_count": 1,
            "readiness_metric_count": 1,
            "restore_ram_mib": expected_ram_mib,
            "restore_status": 0,
            "first_exec_status": 0,
            "cleanup_status": 0,
            "cleanup_forced_pid": False,
            "cleanup_lease_count_before": 0,
            "cleanup_lease_count_after_rm": 0,
            "cleanup_lease_count_after": 0,
            "cleanup_lease_restored": True,
            "cleanup_forced_lease": False,
            "cleanup_runtime_absent": True,
            "cleanup_pid_absent": True,
            "error": "",
        }
        if expected_reason is not None:
            exact["restore_reason"] = expected_reason
            exact["proof_status"] = "ok"
            exact["proof_source"] = expected_source
            exact["proof_plan_source"] = "local_backing" if expected_source == "local_backing" else "chunks"
            exact["proof_schema_version"] = expected_proof_schema
            exact["proof_verity"] = expected_proof_verity
            exact["proof_metric_count"] = 1
        if include_run_from:
            exact["run_from_status"] = 0
        for field, expected in exact.items():
            if row.get(field) != expected:
                errors.append(f"{prefix}: {field}={row.get(field)!r}, expected {expected!r}")
        if row.get("restore_name") != row.get("requested_name"):
            errors.append(f"{prefix}: restore_name does not match the requested name")
        numeric_fields = (
            "restore_return_ms",
            "restore_prepare_ms",
            "restore_spawn_monitor_ms",
            "exec_ready_wait_ms",
            "restore_total_ms",
            "backend_memory_ms",
            "backend_state_ms",
            "backend_pre_run_ms",
            "readiness_ready_ms",
            "first_noop_exec_ms",
            "repeated_exec_median_ms",
            "cleanup_ms",
        )
        if require_readiness_phases:
            numeric_fields += (
                "readiness_attach_ms",
                "readiness_connect_request_delivered_ms",
                "readiness_connect_ms",
                "readiness_request_delivered_ms",
                "readiness_guest_timing_ms",
                "readiness_response_ms",
            )
        if include_run_from:
            numeric_fields += ("run_from_noop_ms",)
        for field in numeric_fields:
            if not is_nonnegative_number(row.get(field)):
                errors.append(f"{prefix}: {field} must be a finite nonnegative number")
        phases = (row.get("restore_prepare_ms"), row.get("restore_spawn_monitor_ms"), row.get("exec_ready_wait_ms"))
        if all(is_number(item) for item in phases) and is_number(row.get("restore_total_ms")):
            if sum(float(item) for item in phases) != float(row["restore_total_ms"]):
                errors.append(f"{prefix}: restore total does not equal prepare+spawn+wait")
        samples = row.get("repeated_exec_ms")
        statuses = row.get("repeated_exec_statuses")
        if not isinstance(samples, list) or len(samples) != repeated_execs or not all(is_nonnegative_number(item) for item in samples):
            errors.append(f"{prefix}: expected {repeated_execs} repeated exec samples")
        if statuses != [0] * repeated_execs:
            errors.append(f"{prefix}: repeated exec statuses are incomplete: {statuses!r}")
        if expected_source == "local_backing":
            if row.get("backend_memory_ms") != 0:
                errors.append(f"{prefix}: local_backing memory_ms must be 0")
        elif expected_source == "eager_chunks" and not (
            isinstance(row.get("backend_memory_ms"), int)
            and not isinstance(row.get("backend_memory_ms"), bool)
            and int(row["backend_memory_ms"]) > 0
        ):
            errors.append(f"{prefix}: eager_chunks memory_ms must be a positive integer")
        if expected_reason is not None:
            for field in ("proof_validation_us", "proof_precharge_us"):
                if not is_nonnegative_number(row.get(field)):
                    errors.append(f"{prefix}: {field} is required when a planner reason is expected")
    if errors:
        raise BenchmarkError(f"{scenario}: strict row validation failed:\n  " + "\n  ".join(errors))


def self_test_historical_readiness_validation() -> None:
    row: dict[str, object] = {
        "schema": ROW_SCHEMA,
        "scenario": "historical_baseline_vcpu1",
        "iteration": 1,
        "backend": "hvf",
        "requested_backend": "hvf",
        "vcpus": 1,
        "restore_schema": "spore.lifecycle.v1",
        "restore_schema_version": 1,
        "restore_action": "restored",
        "requested_name": "n1",
        "restore_name": "n1",
        "restore_state": "ready",
        "exec_ready_source": "restore_contract",
        "restore_source": "eager_chunks",
        "restore_metric_count": 1,
        "readiness_metric_count": 1,
        "restore_ram_mib": 1024,
        "restore_status": 0,
        "first_exec_status": 0,
        "cleanup_status": 0,
        "cleanup_forced_pid": False,
        "cleanup_lease_count_before": 0,
        "cleanup_lease_count_after_rm": 0,
        "cleanup_lease_count_after": 0,
        "cleanup_lease_restored": True,
        "cleanup_forced_lease": False,
        "cleanup_runtime_absent": True,
        "cleanup_pid_absent": True,
        "error": "",
        "restore_return_ms": 10,
        "restore_prepare_ms": 1,
        "restore_spawn_monitor_ms": 2,
        "exec_ready_wait_ms": 3,
        "restore_total_ms": 6,
        "backend_memory_ms": 1,
        "backend_state_ms": 1,
        "backend_pre_run_ms": 2,
        "readiness_attach_ms": None,
        "readiness_connect_request_delivered_ms": None,
        "readiness_connect_ms": None,
        "readiness_request_delivered_ms": None,
        "readiness_guest_timing_ms": None,
        "readiness_response_ms": None,
        "readiness_ready_ms": 4,
        "first_noop_exec_ms": 1,
        "repeated_exec_median_ms": 1,
        "repeated_exec_ms": [1],
        "repeated_exec_statuses": [0],
        "cleanup_ms": 1,
    }
    arguments = {
        "scenario": "historical_baseline_vcpu1",
        "iterations": 1,
        "repeated_execs": 1,
        "backend": "hvf",
        "vcpus": 1,
        "expected_source": "eager_chunks",
        "expected_reason": None,
        "expected_proof_schema": None,
        "expected_proof_verity": None,
        "expected_ram_mib": 1024,
        "include_run_from": False,
    }
    validate_rows([row], **arguments, require_readiness_phases=False)
    try:
        validate_rows([row], **arguments, require_readiness_phases=True)
    except BenchmarkError as err:
        for field in (
            "readiness_attach_ms",
            "readiness_connect_request_delivered_ms",
            "readiness_connect_ms",
            "readiness_request_delivered_ms",
            "readiness_guest_timing_ms",
            "readiness_response_ms",
        ):
            assert field in str(err)
    else:
        raise AssertionError("current rows accepted missing readiness phase metrics")


def manifest_vcpu_count(manifest: object, requested_vcpus: int) -> int:
    if not isinstance(manifest, dict):
        raise BenchmarkError("parent manifest must be a JSON object")
    version = manifest.get("version")
    platform_manifest = manifest.get("platform")
    machine_manifest = manifest.get("machine")
    if not isinstance(version, int) or isinstance(version, bool):
        raise BenchmarkError(f"unsupported or malformed parent manifest version: {version!r}")
    if not isinstance(platform_manifest, dict) or not isinstance(machine_manifest, dict):
        raise BenchmarkError("parent manifest platform and machine must be JSON objects")
    if version == 2:
        if requested_vcpus != 1:
            raise BenchmarkError("manifest version 2 supports exactly one vCPU")
        if "vcpu_count" in platform_manifest or "vcpus" in machine_manifest:
            raise BenchmarkError("manifest version 2 contains version 3 topology fields")
        return 1
    if version == 3:
        actual_vcpus = platform_manifest.get("vcpu_count")
        machine_vcpus = machine_manifest.get("vcpus")
        if (
            not isinstance(actual_vcpus, int)
            or isinstance(actual_vcpus, bool)
            or actual_vcpus != requested_vcpus
            or not isinstance(machine_vcpus, list)
            or len(machine_vcpus) != requested_vcpus
        ):
            raise BenchmarkError(f"parent manifest topology does not match requested vCPU count {requested_vcpus}")
        return actual_vcpus
    raise BenchmarkError(f"unsupported or malformed parent manifest version: {version!r}")


def parent_identity(path: pathlib.Path, runtime_dir: pathlib.Path, capture: CommandResult, vcpus: int) -> dict[str, object]:
    manifest_path = path / "manifest.json"
    proof_path = path / "ram.backing.proof"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    actual_vcpus = manifest_vcpu_count(manifest, vcpus)
    proof = json.loads(proof_path.read_text(encoding="utf-8")) if proof_path.is_file() else None
    memory = manifest.get("memory")
    backing_spec = memory.get("backing") if isinstance(memory, dict) else None
    backing_path = path / str(backing_spec.get("path")) if isinstance(backing_spec, dict) else None
    key_path = runtime_dir / "local-ram-backing.key"
    proof_write_metrics = parse_proof_metrics(capture.stderr, "write")
    return {
        "manifest_sha256": sha256_file(manifest_path),
        "manifest": manifest,
        "vcpus": actual_vcpus,
        "proof_sha256": sha256_file(proof_path) if proof_path.is_file() else None,
        "proof": proof,
        "backing": file_identity(backing_path) if backing_path and backing_path.is_file() else None,
        "filesystem": filesystem_info(path),
        "runtime_key": {"present": key_path.is_file(), "size": key_path.stat().st_size if key_path.is_file() else None},
        "capture": capture.evidence(),
        "proof_write_metrics": proof_write_metrics,
        "proof_write_metric_count": len(proof_write_metrics),
    }


def self_test_manifest_vcpu_count() -> None:
    version_2 = {"version": 2, "platform": {}, "machine": {"pc": 0}}
    assert manifest_vcpu_count(version_2, 1) == 1

    version_3_one = {"version": 3, "platform": {"vcpu_count": 1}, "machine": {"vcpus": [{}]}}
    version_3_two = {"version": 3, "platform": {"vcpu_count": 2}, "machine": {"vcpus": [{}, {}]}}
    assert manifest_vcpu_count(version_3_one, 1) == 1
    assert manifest_vcpu_count(version_3_two, 2) == 2

    invalid = (
        (version_2, 2),
        ({"version": 2, "platform": {"vcpu_count": 1}, "machine": {"vcpus": [{}]}}, 1),
        ({"version": 3, "platform": {"vcpu_count": 2}, "machine": {"vcpus": [{}]}}, 1),
        ({"version": 3, "platform": {"vcpu_count": 1}, "machine": {"vcpus": [{}, {}]}}, 1),
        ({"version": 3, "platform": {"vcpu_count": 2}, "machine": {"vcpus": [{}]}}, 2),
        ({"version": 4, "platform": {}, "machine": {}}, 1),
        ({"version": 2.0, "platform": {}, "machine": {}}, 1),
        ({"platform": {}, "machine": {}}, 1),
        ({"version": 2, "platform": [], "machine": {}}, 1),
    )
    for manifest, requested_vcpus in invalid:
        try:
            manifest_vcpu_count(manifest, requested_vcpus)
        except BenchmarkError:
            pass
        else:
            raise AssertionError(f"invalid manifest topology was accepted: {manifest!r}")


def require_parent_proof(identity: dict[str, object], schema_version: int, label: str) -> None:
    proof = identity.get("proof")
    if not isinstance(proof, dict) or proof.get("schema_version") != schema_version:
        raise BenchmarkError(f"{label}: expected proof schema v{schema_version}")
    verity = proof.get("verity")
    if schema_version == 2:
        if not isinstance(verity, dict) or verity.get("algorithm") != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", str(verity.get("digest", ""))):
            raise BenchmarkError(f"{label}: schema-v2 proof lacks a canonical fs-verity digest")
    elif verity is not None:
        raise BenchmarkError(f"{label}: schema-v1 proof unexpectedly contains verity metadata")
    writes = identity.get("proof_write_metrics")
    if not isinstance(writes, list) or len(writes) != 1:
        raise BenchmarkError(f"{label}: expected exactly one proof write metric")
    if identity.get("proof_write_metric_count") != 1:
        raise BenchmarkError(f"{label}: proof write metric count is not authoritative")
    write = writes[0]
    expected_verity = "sha256" if schema_version == 2 else "none"
    expected_reason = "verity_enabled" if schema_version == 2 else "verity_unavailable"
    if (
        write.get("status") != "ok"
        or write.get("reason") != expected_reason
        or write.get("schema") != schema_version
        or write.get("verity") != expected_verity
        or not is_nonnegative_number(write.get("elapsed_us"))
    ):
        raise BenchmarkError(f"{label}: proof write metrics do not match schema v{schema_version}")


def self_test_parent_proof_metrics() -> None:
    for schema_version, verity, reason in (
        (2, {"algorithm": "sha256", "digest": "0" * 64}, "verity_enabled"),
        (1, None, "verity_unavailable"),
    ):
        write = {
            "status": "ok",
            "reason": reason,
            "schema": schema_version,
            "verity": "sha256" if schema_version == 2 else "none",
            "elapsed_us": 1,
        }
        identity = {
            "proof": {"schema_version": schema_version, "verity": verity},
            "proof_write_metrics": [write],
            "proof_write_metric_count": 1,
        }
        require_parent_proof(identity, schema_version, f"schema-v{schema_version}")
        duplicate = identity | {
            "proof_write_metrics": [write, write],
            "proof_write_metric_count": 2,
        }
        try:
            require_parent_proof(duplicate, schema_version, f"duplicate-schema-v{schema_version}")
        except BenchmarkError:
            pass
        else:
            raise AssertionError("duplicate parent proof-write metrics were accepted")


def capture_parent(
    runner: CommandRunner,
    spore_bin: pathlib.Path,
    env: dict[str, str],
    backend: str,
    image: str,
    memory: str,
    vcpus: int,
    output: pathlib.Path,
    timeout_s: float,
) -> CommandResult:
    if output.exists():
        raise BenchmarkError(f"capture output already exists: {output}")
    result = runner.run([
        str(spore_bin), "--debug", "run", "--backend", backend, "--vcpus", str(vcpus),
        "--image", image, "--memory", memory, "--save", str(output), "--", "/bin/true",
    ], env, timeout_s)
    if result.returncode != 0 or not (output / "manifest.json").is_file():
        raise BenchmarkError(f"parent capture failed status={result.returncode}: {result.stderr.strip()}")
    make_tree_immutable(output)
    return result


def run_from_validation(
    runner: CommandRunner,
    spore_bin: pathlib.Path,
    env: dict[str, str],
    backend: str,
    child: pathlib.Path,
    expected_schema: int,
    expected_verity: str,
    timeout_s: float,
) -> dict[str, object]:
    result = runner.run([str(spore_bin), "--debug", "run", "--backend", backend, "--from", str(child), "--", "/bin/true"], env, timeout_s)
    if result.returncode != 0:
        raise BenchmarkError(f"fan-out child validation failed for {child.name}: {result.stderr.strip()}")
    validation = require_single_proof_metric(result.stderr, "validate", f"fan-out child {child.name}")
    if (
        validation.get("status") != "ok"
        or validation.get("source") != "local_backing"
        or validation.get("reason") != "proof_valid"
        or validation.get("schema") != expected_schema
        or validation.get("verity") != expected_verity
        or not is_nonnegative_number(validation.get("validation_us"))
        or not is_nonnegative_number(validation.get("precharge_us"))
    ):
        raise BenchmarkError(f"fan-out child did not validate proof-backed RAM: {child.name}")
    return {
        "child": child.name,
        "command": result.evidence(),
        "proof_metric_count": 1,
        "validation": validation,
    }


def collect_fanout_evidence(
    runner: CommandRunner,
    spore_bin: pathlib.Path,
    env: dict[str, str],
    backend: str,
    parent: pathlib.Path,
    output: pathlib.Path,
    count: int,
    expected_schema: int,
    expected_verity: str,
    timeout_s: float,
) -> dict[str, object]:
    result = runner.run([str(spore_bin), "--debug", "fork", str(parent), "--count", str(count), "--out", str(output)], env, timeout_s)
    if result.returncode != 0:
        raise BenchmarkError(f"fan-out fork failed: {result.stderr.strip()}")
    children = [output / f"{index:06d}" for index in range(count)]
    validations = [
        run_from_validation(runner, spore_bin, env, backend, child, expected_schema, expected_verity, timeout_s)
        for child in children
    ]
    return {
        "fork": result.evidence(),
        "proof_metrics": parse_proof_metrics(result.stderr),
        "children": validations,
    }


def current_lane_key(vcpus: int, kind: str) -> str:
    return f"current_{kind}_vcpu{vcpus}"


def matrix(args: argparse.Namespace, runner: CommandRunner) -> int:
    repo = pathlib.Path(__file__).resolve().parents[2]
    output_dir = args.output_dir.resolve()
    scratch = args.scratch_dir.resolve()
    for label, path in (("output", output_dir), ("scratch", scratch)):
        if path.exists() and any(path.iterdir()):
            raise BenchmarkError(f"release benchmark {label} directory must be empty: {path}")
        path.mkdir(parents=True, exist_ok=True)
    scratch_precondition = release_scratch_precondition(scratch, args.backend)
    evidence_path = output_dir / "evidence.json"

    current_bin = args.candidate_bin.resolve()
    baseline_bin = args.baseline_bin.resolve()
    if current_bin != (repo / "zig-out/bin/spore").resolve():
        raise BenchmarkError("release benchmark candidate must be this checkout's zig-out/bin/spore")
    aliases = {
        str(current_bin): "$CANDIDATE_BIN",
        str(baseline_bin): "$BASELINE_BIN",
        str(args.baseline_archive.resolve()): "$BASELINE_ARCHIVE",
        str(args.baseline_checksums.resolve()): "$BASELINE_CHECKSUMS",
        str(args.unsupported_fs_dir.resolve()): "$UNSUPPORTED_FS",
        str(output_dir): "$OUTPUT",
        str(scratch): "$SCRATCH",
        str(repo): "$REPO",
        str(pathlib.Path.home().resolve()): "$HOME",
    }
    runner.set_path_aliases(aliases)
    expected_ram_mib = memory_mib(args.memory)
    current_proof_schema = 2 if platform.system() == "Linux" else 1
    current_proof_verity = "sha256" if current_proof_schema == 2 else "none"
    repo_identity = git_identity(repo, args.expected_commit)
    host_before = host_identity(args.backend)
    release_inputs = verify_release_inputs(
        args.baseline_archive.resolve(),
        args.baseline_checksums.resolve(),
        args.baseline_archive_sha256,
        args.baseline_checksums_sha256,
        baseline_bin,
        args.baseline_archive_member,
    )
    rootfs_cache = scratch / "rootfs-cache"
    kernel_cache = scratch / "kernel-cache"
    task_tmp = scratch / "tmp"
    base_env = {key: value for key, value in os.environ.items() if not key.startswith("SPOREVM_")}
    base_env["SPOREVM_ROOTFS_CACHE_DIR"] = str(rootfs_cache)
    base_env["SPOREVM_KERNEL_CACHE_DIR"] = str(kernel_cache)
    base_env["SPOREVM_KERNEL_REPOSITORY"] = str(MANAGED_KERNEL_PIN["repository"])
    base_env["SPOREVM_KERNEL_RELEASE"] = str(MANAGED_KERNEL_PIN["release"])
    base_env["SPOREVM_KERNEL_VERSION"] = str(MANAGED_KERNEL_PIN["linux_version"])
    base_env["TMPDIR"] = str(task_tmp)
    for path in (rootfs_cache, kernel_cache, task_tmp):
        path.mkdir(parents=True, exist_ok=True)
    current_before = binary_identity(runner, current_bin, base_env, args.timeout)
    baseline_before = binary_identity(runner, baseline_bin, base_env, args.timeout)
    if "(ReleaseSafe)" not in str(current_before["version"]):
        raise BenchmarkError("candidate binary is not a ReleaseSafe build")
    if "(ReleaseSafe)" not in str(baseline_before["version"]):
        raise BenchmarkError("baseline binary is not a ReleaseSafe build")
    pinned_image = args.image

    all_rows: list[dict[str, object]] = []
    lanes: dict[str, list[dict[str, object]]] = {}
    parents: dict[str, dict[str, object]] = {}
    parent_postconditions: list[tuple[pathlib.Path, pathlib.Path, CommandResult, int, dict[str, object]]] = []
    runtime_root = scratch / "r"
    primary_runtime = runtime_root / "p"
    primary_runtime.mkdir(parents=True, mode=0o700)
    primary_env = base_env | {"SPOREVM_RUNTIME_DIR": str(primary_runtime)}
    parent_paths: dict[int, pathlib.Path] = {}

    try:
        for vcpus in (1, 2):
            parent = scratch / f"current-parent-vcpu{vcpus}.spore"
            capture = capture_parent(runner, current_bin, primary_env, args.backend, pinned_image, args.memory, vcpus, parent, args.timeout)
            parent_paths[vcpus] = parent
            identity = parent_identity(parent, primary_runtime, capture, vcpus)
            require_parent_proof(identity, current_proof_schema, f"current vCPU {vcpus} parent")
            parents[f"current_vcpu{vcpus}"] = identity
            parent_postconditions.append((parent, primary_runtime, capture, vcpus, identity))

            local_key = current_lane_key(vcpus, "local")
            local_runtime = runtime_root / f"l{vcpus}"
            shutil.copytree(primary_runtime, local_runtime, dirs_exist_ok=True)
            lanes[local_key] = run_lane(
                runner=runner, spore_dir=parent, real_spore_bin=current_bin, backend=args.backend,
                vcpus=vcpus, iterations=args.iterations, repeated_execs=args.repeated_execs,
                output=output_dir / f"{local_key}.jsonl", runtime_dir=local_runtime, scenario=local_key,
                expected_source="local_backing", expected_reason="proof_valid",
                expected_proof_schema=current_proof_schema, expected_proof_verity=current_proof_verity,
                expected_ram_mib=expected_ram_mib,
                timeout_s=args.timeout, include_run_from=True, base_env=base_env, path_aliases=aliases,
            )
            all_rows.extend(lanes[local_key])

            eager_key = current_lane_key(vcpus, "eager")
            eager_runtime = runtime_root / f"e{vcpus}"
            lanes[eager_key] = run_lane(
                runner=runner, spore_dir=parent, real_spore_bin=current_bin, backend=args.backend,
                vcpus=vcpus, iterations=args.iterations, repeated_execs=args.repeated_execs,
                output=output_dir / f"{eager_key}.jsonl", runtime_dir=eager_runtime, scenario=eager_key,
                expected_source="eager_chunks", expected_reason="key_unavailable",
                expected_proof_schema=0, expected_proof_verity="none", expected_ram_mib=expected_ram_mib,
                timeout_s=args.timeout, include_run_from=True, base_env=base_env, path_aliases=aliases,
            )
            all_rows.extend(lanes[eager_key])

        current_kernel_inputs = managed_kernel_identities(kernel_cache)
        require_managed_kernel_pin(current_kernel_inputs)
        historical_runtime = runtime_root / "h"
        historical_runtime.mkdir(parents=True, mode=0o700)
        historical_env = base_env | {"SPOREVM_RUNTIME_DIR": str(historical_runtime)}
        historical_parent = scratch / "historical-v0.12-vcpu1.spore"
        historical_capture = capture_parent(
            runner, baseline_bin, historical_env, args.backend, pinned_image, args.memory, 1, historical_parent, args.timeout
        )
        historical_identity = parent_identity(historical_parent, historical_runtime, historical_capture, 1)
        parents["historical_vcpu1"] = historical_identity
        parent_postconditions.append((historical_parent, historical_runtime, historical_capture, 1, historical_identity))
        for key, runtime_name, binary, source, reason, require_readiness_phases in (
            ("historical_baseline_vcpu1", "hb", baseline_bin, "eager_chunks", None, False),
            ("historical_current_vcpu1", "hc", current_bin, "local_backing", "proof_valid", True),
        ):
            runtime = runtime_root / runtime_name
            shutil.copytree(historical_runtime, runtime, dirs_exist_ok=True)
            lanes[key] = run_lane(
                runner=runner, spore_dir=historical_parent, real_spore_bin=binary, backend=args.backend,
                vcpus=1, iterations=args.iterations, repeated_execs=args.repeated_execs,
                output=output_dir / f"{key}.jsonl", runtime_dir=runtime, scenario=key,
                expected_source=source, expected_reason=reason,
                expected_proof_schema=1 if reason is not None else None,
                expected_proof_verity="none" if reason is not None else None,
                expected_ram_mib=expected_ram_mib,
                timeout_s=args.timeout, include_run_from=True, base_env=base_env, path_aliases=aliases,
                require_readiness_phases=require_readiness_phases,
            )
            all_rows.extend(lanes[key])

        fanout_dir = scratch / "fanout-v2"
        expected_schema = current_proof_schema
        expected_verity = "sha256" if expected_schema == 2 else "none"
        fanout_evidence = collect_fanout_evidence(
            runner, current_bin, primary_env, args.backend, parent_paths[1], fanout_dir, 2,
            expected_schema, expected_verity, args.timeout,
        )
        fanout_metrics = fanout_evidence["proof_metrics"]
        assert isinstance(fanout_metrics, list)
        fanout_validations = [item for item in fanout_metrics if item.get("operation") == "validate"]
        fanout_writes = [item for item in fanout_metrics if item.get("operation") == "write"]
        if (
            len(fanout_validations) != 1
            or fanout_validations[0].get("status") != "ok"
            or fanout_validations[0].get("source") != "local_backing"
            or fanout_validations[0].get("reason") != "proof_valid"
            or fanout_validations[0].get("schema") != expected_schema
            or fanout_validations[0].get("verity") != expected_verity
            or not is_nonnegative_number(fanout_validations[0].get("validation_us"))
            or not is_nonnegative_number(fanout_validations[0].get("precharge_us"))
            or len(fanout_writes) != 2
            or any(
                item.get("status") != "ok"
                or item.get("schema") != expected_schema
                or item.get("verity") != expected_verity
                or not is_nonnegative_number(item.get("elapsed_us"))
                for item in fanout_writes
            )
        ):
            raise BenchmarkError("fan-out proof validation/write metrics are incomplete")
        fanout_children = fanout_evidence["children"]
        assert isinstance(fanout_children, list)

        unsupported_evidence: dict[str, object] | None = None
        if platform.system() == "Linux":
            unsupported_root = args.unsupported_fs_dir.resolve()
            unsupported_root.mkdir(parents=True, exist_ok=True)
            unsupported_work = pathlib.Path(tempfile.mkdtemp(prefix="nr-", dir=unsupported_root))
            try:
                unsupported_filesystem = filesystem_info(unsupported_work)
                if unsupported_filesystem.get("filesystem") != "tmpfs":
                    raise BenchmarkError("unsupported-filesystem control requires a tmpfs destination")
                if parent_paths[1].stat().st_dev == unsupported_work.stat().st_dev:
                    raise BenchmarkError("cross-filesystem control source and destination have the same st_dev")
                unsupported_runtime_root = unsupported_work / "r"
                unsupported_runtime = unsupported_runtime_root / "p"
                unsupported_runtime.mkdir(parents=True, mode=0o700)
                unsupported_env = base_env | {"SPOREVM_RUNTIME_DIR": str(unsupported_runtime)}
                unsupported_parent = unsupported_work / "unsupported-parent.spore"
                unsupported_capture = capture_parent(
                    runner, current_bin, unsupported_env, args.backend, pinned_image, args.memory, 1, unsupported_parent, args.timeout
                )
                unsupported_parent_identity = parent_identity(unsupported_parent, unsupported_runtime, unsupported_capture, 1)
                require_parent_proof(unsupported_parent_identity, 1, "unsupported filesystem parent")
                unsupported_local_runtime = unsupported_runtime_root / "l"
                shutil.copytree(unsupported_runtime, unsupported_local_runtime, dirs_exist_ok=True)
                unsupported_local = run_lane(
                    runner=runner, spore_dir=unsupported_parent, real_spore_bin=current_bin, backend=args.backend,
                    vcpus=1, iterations=args.iterations, repeated_execs=args.repeated_execs,
                    output=output_dir / "unsupported_v1_local.jsonl",
                    runtime_dir=unsupported_local_runtime, scenario="unsupported_v1_local", expected_source="local_backing",
                    expected_reason="proof_valid", expected_proof_schema=1, expected_proof_verity="none",
                    expected_ram_mib=expected_ram_mib, timeout_s=args.timeout,
                    include_run_from=False, base_env=base_env, path_aliases=aliases,
                )
                lanes["unsupported_v1_local"] = unsupported_local
                all_rows.extend(unsupported_local)
                unsupported_eager = run_lane(
                    runner=runner, spore_dir=unsupported_parent, real_spore_bin=current_bin, backend=args.backend,
                    vcpus=1, iterations=args.iterations, repeated_execs=args.repeated_execs,
                    output=output_dir / "unsupported_v1_missing_key_eager.jsonl",
                    runtime_dir=unsupported_runtime_root / "e", scenario="unsupported_v1_missing_key_eager", expected_source="eager_chunks",
                    expected_reason="key_unavailable", expected_proof_schema=0, expected_proof_verity="none",
                    expected_ram_mib=expected_ram_mib, timeout_s=args.timeout,
                    include_run_from=False, base_env=base_env, path_aliases=aliases,
                )
                lanes["unsupported_v1_missing_key_eager"] = unsupported_eager
                all_rows.extend(unsupported_eager)
                cross_dir = unsupported_work / "cross-filesystem"
                cross = runner.run(
                    [str(current_bin), "--debug", "fork", str(parent_paths[1]), "--count", "1", "--out", str(cross_dir)],
                    primary_env,
                    args.timeout,
                )
                if cross.returncode != 0:
                    raise BenchmarkError(f"cross-filesystem fork failed: {cross.stderr.strip()}")
                cross_manifest = json.loads((cross_dir / "000000" / "manifest.json").read_text(encoding="utf-8"))
                cross_memory = cross_manifest.get("memory") if isinstance(cross_manifest, dict) else None
                if not isinstance(cross_memory, dict) or cross_memory.get("backing") is not None:
                    raise BenchmarkError("cross-filesystem fork retained local backing metadata")
                cross_rows = run_lane(
                    runner=runner, spore_dir=cross_dir / "000000", real_spore_bin=current_bin, backend=args.backend,
                    vcpus=1, iterations=args.iterations, repeated_execs=args.repeated_execs,
                    output=output_dir / "cross_filesystem_eager.jsonl",
                    runtime_dir=unsupported_runtime_root / "x", scenario="cross_filesystem_eager",
                    expected_source="eager_chunks", expected_reason="no_backing",
                    expected_proof_schema=0, expected_proof_verity="none", expected_ram_mib=expected_ram_mib,
                    timeout_s=args.timeout, include_run_from=False, base_env=base_env, path_aliases=aliases,
                )
                lanes["cross_filesystem_eager"] = cross_rows
                all_rows.extend(cross_rows)
                unsupported_evidence = {
                    "filesystem": unsupported_filesystem,
                    "parent": unsupported_parent_identity,
                    "local_rows": unsupported_local,
                    "missing_key_fallback": {
                        "trigger": "runtime key unavailable",
                        "expected_reason": "key_unavailable",
                        "rows": unsupported_eager,
                    },
                    "cross_filesystem_devices": {
                        "source_st_dev": parent_paths[1].stat().st_dev,
                        "destination_st_dev": unsupported_work.stat().st_dev,
                    },
                    "cross_filesystem_fork": cross.evidence(),
                    "cross_filesystem_rows": cross_rows,
                }
                unsupported_after = parent_identity(
                    unsupported_parent, unsupported_runtime, unsupported_capture, 1
                )
                if unsupported_parent_identity != unsupported_after:
                    raise BenchmarkError("unsupported-filesystem parent identity changed during controls")
            finally:
                make_tree_writable(unsupported_work)
                shutil.rmtree(unsupported_work, ignore_errors=True)

        gates: list[dict[str, object]] = []
        for vcpus in (1, 2):
            gates.extend(performance_gate(
                lanes[current_lane_key(vcpus, "local")],
                lanes[current_lane_key(vcpus, "eager")],
                f"{args.backend}.vcpu{vcpus}",
            ))
        gates.extend(non_regression_gates(
            lanes["historical_current_vcpu1"], lanes["historical_baseline_vcpu1"], f"{args.backend}.historical_vcpu1"
        ))
        correctness = {
            "status": "passed",
            "scenarios": {key: len(value) for key, value in lanes.items()},
            "expected_iterations": args.iterations,
            "fanout_children": len(fanout_children),
            "unsupported_filesystem_controls": "passed" if unsupported_evidence is not None else "not_applicable",
        }
        performance = {
            "status": "passed" if all(bool(gate["passed"]) for gate in gates) else "failed",
            "gates": gates,
        }
        current_after = binary_identity(runner, current_bin, base_env, args.timeout)
        baseline_after = binary_identity(runner, baseline_bin, base_env, args.timeout)
        all_kernel_inputs = managed_kernel_identities(kernel_cache)
        require_managed_kernel_pin(all_kernel_inputs)
        host_after = host_identity(args.backend)
        if current_before != current_after or baseline_before != baseline_after:
            raise BenchmarkError("benchmark binary identity changed during the matrix")
        all_kernel_by_path = {str(item["relative_path"]): item for item in all_kernel_inputs}
        if any(all_kernel_by_path.get(str(item["relative_path"])) != item for item in current_kernel_inputs):
            raise BenchmarkError("managed kernel identity changed after current parent capture")
        repo_after = git_identity(repo, args.expected_commit)
        if repo_identity != repo_after:
            raise BenchmarkError("repository identity changed during the matrix")
        for parent, runtime, capture, vcpus, before in parent_postconditions:
            after = parent_identity(parent, runtime, capture, vcpus)
            if before != after:
                raise BenchmarkError(f"immutable parent identity changed during the matrix: vCPU {vcpus}")
        evidence = {
            "schema": EVIDENCE_SCHEMA,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "repository": repo_identity,
            "host": {"before": host_before, "after": host_after},
            "inputs": {
                "baseline_version": args.baseline_version,
                "baseline_release_url": args.baseline_release_url,
                "baseline_release": release_inputs,
                "baseline_binary": baseline_before,
                "candidate_binary": current_before,
                "requested_image": args.image,
                "resolved_image": pinned_image,
                "memory": args.memory,
                "memory_mib": expected_ram_mib,
                "backend": args.backend,
                "vcpus": [1, 2],
                "iterations": args.iterations,
                "repeated_execs": args.repeated_execs,
                "timeout_s": args.timeout,
                "product_environment": {
                    "ambient_sporevm_variables": "removed",
                    "runtime_root": "per-lane task-owned",
                    "rootfs_cache": "task-owned",
                    "kernel_cache": "task-owned",
                    "tmpdir": "task-owned",
                    "external_kernel_or_initrd": False,
                },
                "managed_kernel_cache": {
                    "pin": MANAGED_KERNEL_PIN,
                    "after_current_parent_capture": current_kernel_inputs,
                    "after_historical_parent_capture": all_kernel_inputs,
                },
                "release_scratch_precondition": scratch_precondition,
            },
            "thresholds": {
                "minimum_local_speedup": MIN_LOCAL_SPEEDUP,
                "non_regression_relative": NON_REGRESSION_RELATIVE,
                "non_regression_absolute_ms": NON_REGRESSION_ABSOLUTE_MS,
                "non_regression_requires_both": True,
                "local_memory_ms": 0,
                "eager_memory_ms": "positive for every row",
            },
            "parents": parents,
            "rows": all_rows,
            "lane_summaries": {key: lane_summary(value) for key, value in lanes.items()},
            "fanout": fanout_evidence,
            "unsupported_filesystem": unsupported_evidence,
            "correctness": correctness,
            "performance": performance,
        }
        public_evidence = normalize_paths(evidence, aliases)
        evidence_path.write_text(
            json.dumps(public_evidence, indent=2, sort_keys=True, allow_nan=False) + "\n",
            encoding="utf-8",
        )
        print(evidence_path)
        return 0 if performance["status"] == "passed" else 1
    finally:
        for parent in parent_paths.values():
            make_tree_writable(parent)


def direct(args: argparse.Namespace, runner: CommandRunner) -> int:
    repo = pathlib.Path(__file__).resolve().parents[2]
    if args.spore_dir is None:
        raise BenchmarkError("--spore-dir is required outside --matrix")
    spore_dir = args.spore_dir.resolve()
    if not (spore_dir / "manifest.json").is_file():
        raise BenchmarkError(f"missing spore manifest: {spore_dir / 'manifest.json'}")
    if not args.no_build:
        subprocess.run(["mise", "run", "build:release"], cwd=repo, check=True)
    spore_bin = (repo / args.spore_bin).resolve() if not args.spore_bin.is_absolute() else args.spore_bin.resolve()
    runtime_owner: tempfile.TemporaryDirectory[str] | None = None
    if args.runtime_dir is None:
        runtime_owner = tempfile.TemporaryDirectory(prefix="nr-", dir="/tmp")
        runtime_dir = pathlib.Path(runtime_owner.name)
    else:
        runtime_dir = args.runtime_dir.resolve()
    try:
        rows = run_lane(
            runner=runner, spore_dir=spore_dir, real_spore_bin=spore_bin, backend=args.backend,
            vcpus=args.vcpus, iterations=args.iterations, repeated_execs=args.repeated_execs,
            output=args.output.resolve(), runtime_dir=runtime_dir, scenario=args.scenario,
            expected_source=args.expected_source, expected_reason=args.expected_reason,
            expected_proof_schema=args.expected_proof_schema, expected_proof_verity=args.expected_proof_verity,
            expected_ram_mib=args.expected_ram_mib, timeout_s=args.timeout,
            include_run_from=args.include_run_from, base_env=os.environ.copy(), path_aliases={},
        )
        print(args.output.resolve())
        return 0 if rows else 1
    finally:
        if runtime_owner is not None:
            runtime_owner.cleanup()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", action="store_true", help="run the release-grade current/historical matrix")
    parser.add_argument("--spore-dir", type=pathlib.Path)
    parser.add_argument("--spore-bin", type=pathlib.Path, default=pathlib.Path("zig-out/bin/spore"))
    parser.add_argument("--candidate-bin", type=pathlib.Path)
    parser.add_argument("--baseline-bin", type=pathlib.Path)
    parser.add_argument("--baseline-version", default="v0.12.0")
    parser.add_argument("--baseline-archive", type=pathlib.Path)
    parser.add_argument("--baseline-checksums", type=pathlib.Path)
    parser.add_argument("--baseline-archive-sha256")
    parser.add_argument("--baseline-checksums-sha256")
    parser.add_argument("--baseline-archive-member")
    parser.add_argument("--baseline-release-url")
    parser.add_argument("--expected-commit")
    parser.add_argument("--backend", choices=("hvf", "kvm"), default="kvm")
    parser.add_argument(
        "--image",
        default="docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271",
    )
    parser.add_argument("--memory", default="1024mb")
    parser.add_argument("--vcpus", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--repeated-execs", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("zig-cache/named-restore-readiness.jsonl"))
    parser.add_argument("--output-dir", type=pathlib.Path, default=pathlib.Path("zig-cache/named-restore-readiness"))
    parser.add_argument("--scratch-dir", type=pathlib.Path)
    parser.add_argument("--unsupported-fs-dir", type=pathlib.Path, default=pathlib.Path("/dev/shm"))
    parser.add_argument("--runtime-dir", type=pathlib.Path)
    parser.add_argument("--scenario", default="direct")
    parser.add_argument("--expected-source", choices=("local_backing", "eager_chunks"), default="local_backing")
    parser.add_argument("--expected-reason")
    parser.add_argument("--expected-proof-schema", type=int, default=2)
    parser.add_argument("--expected-proof-verity", default="sha256")
    parser.add_argument("--expected-ram-mib", type=int, default=1024)
    parser.add_argument("--include-run-from", action="store_true")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return args
    if args.iterations < 1 or args.repeated_execs < 1 or args.timeout <= 0 or args.vcpus < 1:
        parser.error("iterations, repeated execs, timeout, and vCPUs must be positive")
    if args.matrix:
        if not PINNED_IMAGE_RE.fullmatch(args.image):
            parser.error("--matrix requires an exact digest-pinned --image")
        if args.iterations != 5:
            parser.error("--matrix requires exactly 5 iterations per lane")
        if args.repeated_execs != 5:
            parser.error("--matrix requires exactly 5 repeated exec samples per row")
        try:
            matrix_memory_mib = memory_mib(args.memory)
        except BenchmarkError as err:
            parser.error(str(err))
        if matrix_memory_mib != 1024:
            parser.error("--matrix requires 1024 MiB RAM")
        required = (
            "candidate_bin", "baseline_bin", "baseline_archive", "baseline_checksums",
            "baseline_archive_sha256", "baseline_checksums_sha256", "baseline_archive_member",
            "baseline_release_url", "expected_commit", "scratch_dir",
        )
        missing = [f"--{name.replace('_', '-')}" for name in required if getattr(args, name) is None]
        if missing:
            parser.error("--matrix requires " + ", ".join(missing))
    return args


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        self_test_manifest_vcpu_count()
        self_test_parent_proof_metrics()
        self_test_historical_readiness_validation()
        return 0
    signals = SignalState()
    signals.install()
    runner = CommandRunner(signals)
    try:
        return matrix(args, runner) if args.matrix else direct(args, runner)
    except BenchmarkSignal as err:
        print(f"interrupted by {signal.Signals(err.signum).name}; named cleanup completed", file=sys.stderr)
        return 128 + err.signum
    except KeyboardInterrupt:
        print("interrupted by SIGINT; named cleanup completed", file=sys.stderr)
        return 130
    except BenchmarkError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    finally:
        signals.restore()


if __name__ == "__main__":
    raise SystemExit(main())
