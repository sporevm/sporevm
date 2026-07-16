"""Strict contracts and comparisons for the Spore build conformance harness."""

from __future__ import annotations

import dataclasses
import difflib
import enum
import json
import pathlib
import shlex
from typing import Any


PLATFORM = "linux/arm64"
BUILDKIT_IMAGE = (
    "moby/buildkit@sha256:"
    "0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f"
)
BUILDKIT_VERSION = "v0.30.0"
SCANNER = "/usr/local/bin/spore-build-conformance-scan"
SCANNER_PYTHON = "/usr/local/bin/python3"
CONFIG_FIELDS = ("Env", "Entrypoint", "Cmd", "WorkingDir", "User")


class HarnessError(RuntimeError):
    pass


class CaseError(HarnessError):
    pass


class Outcome(str, enum.Enum):
    SUCCESS = "success"
    FAILURE = "failure"


class CacheStatus(str, enum.Enum):
    HIT = "hit"
    MISS = "miss"
    METADATA_ONLY = "metadata-only"


class IndexExpectation(str, enum.Enum):
    SAME = "same"
    CHANGED = "changed"


class SporeNetwork(str, enum.Enum):
    NONE = "none"
    SPORE = "spore"


@dataclasses.dataclass(frozen=True)
class CommandResult:
    command: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


@dataclasses.dataclass(frozen=True)
class SporeBuildResult:
    command: CommandResult
    index_digest: str | None
    metadata_path: pathlib.Path | None
    cache_status: str | None
    executed_steps: int | None
    boot_count: int | None
    resize_count: int | None


@dataclasses.dataclass(frozen=True)
class BuildExpectation:
    docker: Outcome
    spore: Outcome
    spore_diagnostic: str | None
    spore_exit_code: int | None


@dataclasses.dataclass(frozen=True)
class Transition:
    name: str
    writes: dict[str, str]
    preserve_mtime: tuple[str, ...]
    outcome: Outcome
    spore_diagnostic: str | None
    expect_cache: CacheStatus | None
    expect_index: IndexExpectation | None
    expect_executed_steps: int
    expect_boot_count: int
    expect_resize_count: int
    compare: bool
    no_cache: bool


@dataclasses.dataclass(frozen=True)
class ExecutionExpectation:
    expect_executed_steps: int
    expect_boot_count: int
    expect_resize_count: int


@dataclasses.dataclass(frozen=True)
class CaseSpec:
    description: str
    expect: BuildExpectation
    initial_cache: CacheStatus | None
    initial_execution: ExecutionExpectation | None
    scan_prefixes: tuple[str, ...]
    compare_mtime_paths: tuple[str, ...]
    compare_hardlink_paths: tuple[str, ...]
    empty_dirs: tuple[str, ...]
    symlinks: dict[str, str]
    modes: dict[str, str]
    build_args: dict[str, str]
    base_env: tuple[str, ...] | None
    network: SporeNetwork
    transitions: tuple[Transition, ...]


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    root: pathlib.Path
    spec: CaseSpec


def command_failure(result: CommandResult) -> str:
    details = [
        f"command failed ({result.returncode}): {shlex.join(result.command)}",
    ]
    if result.stdout.strip():
        details.append("stdout:\n" + result.stdout[-4000:])
    if result.stderr.strip():
        details.append("stderr:\n" + result.stderr[-4000:])
    return "\n".join(details)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HarnessError(f"{label} must be a JSON object")
    return value


def reject_unknown_fields(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise HarnessError(f"{label} has unknown field(s): {', '.join(unknown)}")


def require_string(value: Any, label: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        qualifier = "non-empty " if nonempty else ""
        raise HarnessError(f"{label} must be a {qualifier}string")
    return value


def require_string_list(value: Any, label: str, *, nonempty: bool = True) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise HarnessError(f"{label} must be an array of strings")
    return tuple(
        require_string(item, f"{label}[{index}]", nonempty=nonempty)
        for index, item in enumerate(value)
    )


def require_string_map(value: Any, label: str) -> dict[str, str]:
    raw = require_object(value, label)
    return {
        require_string(key, f"{label} key"): require_string(item, f"{label}.{key}", nonempty=False)
        for key, item in raw.items()
    }


def require_nonnegative_int(value: Any, label: str) -> int:
    if type(value) is not int or value < 0:
        raise HarnessError(f"{label} must be a non-negative integer")
    return value


def parse_outcome(value: Any, label: str) -> Outcome:
    raw = require_string(value, label)
    try:
        return Outcome(raw)
    except ValueError as error:
        raise HarnessError(f"{label} must be one of: success, failure") from error


def parse_cache_status(value: Any, label: str) -> CacheStatus:
    raw = require_string(value, label)
    try:
        return CacheStatus(raw)
    except ValueError as error:
        raise HarnessError(f"{label} must be one of: hit, miss, metadata-only") from error


def parse_index_expectation(value: Any, label: str) -> IndexExpectation:
    raw = require_string(value, label)
    try:
        return IndexExpectation(raw)
    except ValueError as error:
        raise HarnessError(f"{label} must be one of: same, changed") from error


def parse_spore_network(value: Any, label: str) -> SporeNetwork:
    raw = require_string(value, label)
    try:
        return SporeNetwork(raw)
    except ValueError as error:
        raise HarnessError(f"{label} must be one of: none, spore") from error


def parse_expectation(value: Any, label: str) -> BuildExpectation:
    raw = require_object(value, label)
    reject_unknown_fields(raw, {"docker", "spore", "spore_diagnostic", "spore_exit_code"}, label)
    if "docker" not in raw or "spore" not in raw:
        raise HarnessError(f"{label} requires docker and spore fields")
    docker = parse_outcome(raw["docker"], f"{label}.docker")
    spore = parse_outcome(raw["spore"], f"{label}.spore")
    diagnostic_value = raw.get("spore_diagnostic")
    diagnostic = (
        require_string(diagnostic_value, f"{label}.spore_diagnostic")
        if diagnostic_value is not None
        else None
    )
    exit_code_value = raw.get("spore_exit_code")
    exit_code = (
        require_nonnegative_int(exit_code_value, f"{label}.spore_exit_code")
        if exit_code_value is not None
        else None
    )
    if spore is Outcome.FAILURE and diagnostic is None:
        raise HarnessError(f"{label}.spore_diagnostic is required when Spore should fail")
    if spore is Outcome.SUCCESS and diagnostic is not None:
        raise HarnessError(f"{label}.spore_diagnostic is only valid when Spore should fail")
    if spore is Outcome.SUCCESS and exit_code is not None:
        raise HarnessError(f"{label}.spore_exit_code is only valid when Spore should fail")
    return BuildExpectation(
        docker=docker,
        spore=spore,
        spore_diagnostic=diagnostic,
        spore_exit_code=exit_code,
    )


def parse_transition(value: Any, label: str) -> Transition:
    raw = require_object(value, label)
    reject_unknown_fields(
        raw,
        {
            "name",
            "outcome",
            "spore_diagnostic",
            "writes",
            "preserve_mtime",
            "expect_cache",
            "expect_index",
            "expect_executed_steps",
            "expect_boot_count",
            "expect_resize_count",
            "compare",
            "no_cache",
        },
        label,
    )
    outcome = parse_outcome(raw.get("outcome", "success"), f"{label}.outcome")
    required = {"name"}
    if outcome is Outcome.SUCCESS:
        required |= {
            "expect_cache",
            "expect_executed_steps",
            "expect_boot_count",
            "expect_resize_count",
        }
    missing = sorted(required - set(raw))
    if missing:
        raise HarnessError(f"{label} is missing required field(s): {', '.join(missing)}")
    compare = raw.get("compare", False)
    if type(compare) is not bool:
        raise HarnessError(f"{label}.compare must be a boolean")
    no_cache = raw.get("no_cache", False)
    if type(no_cache) is not bool:
        raise HarnessError(f"{label}.no_cache must be a boolean")
    diagnostic_value = raw.get("spore_diagnostic")
    diagnostic = (
        require_string(diagnostic_value, f"{label}.spore_diagnostic")
        if diagnostic_value is not None
        else None
    )
    if outcome is Outcome.FAILURE and diagnostic is None:
        raise HarnessError(f"{label}.spore_diagnostic is required when the transition should fail")
    if outcome is Outcome.SUCCESS and diagnostic is not None:
        raise HarnessError(f"{label}.spore_diagnostic is only valid for a failed transition")
    if outcome is Outcome.FAILURE and ("expect_index" in raw or compare):
        raise HarnessError(f"{label} cannot compare or assert an index for a failed transition")
    success_only = {
        "expect_cache",
        "expect_executed_steps",
        "expect_boot_count",
        "expect_resize_count",
    }
    ignored = sorted(success_only & set(raw)) if outcome is Outcome.FAILURE else []
    if ignored:
        raise HarnessError(f"{label} has success-only field(s): {', '.join(ignored)}")
    return Transition(
        name=require_string(raw["name"], f"{label}.name"),
        outcome=outcome,
        spore_diagnostic=diagnostic,
        writes=require_string_map(raw.get("writes", {}), f"{label}.writes"),
        preserve_mtime=require_string_list(
            raw.get("preserve_mtime", []), f"{label}.preserve_mtime"
        ),
        expect_cache=(
            parse_cache_status(raw["expect_cache"], f"{label}.expect_cache")
            if "expect_cache" in raw
            else None
        ),
        expect_index=(
            parse_index_expectation(raw["expect_index"], f"{label}.expect_index")
            if "expect_index" in raw
            else None
        ),
        expect_executed_steps=require_nonnegative_int(
            raw.get("expect_executed_steps", 0), f"{label}.expect_executed_steps"
        ),
        expect_boot_count=require_nonnegative_int(
            raw.get("expect_boot_count", 0), f"{label}.expect_boot_count"
        ),
        expect_resize_count=require_nonnegative_int(
            raw.get("expect_resize_count", 0), f"{label}.expect_resize_count"
        ),
        compare=compare,
        no_cache=no_cache,
    )


def parse_execution_expectation(value: Any, label: str) -> ExecutionExpectation:
    raw = require_object(value, label)
    allowed = {"expect_executed_steps", "expect_boot_count", "expect_resize_count"}
    reject_unknown_fields(raw, allowed, label)
    missing = sorted(allowed - set(raw))
    if missing:
        raise HarnessError(f"{label} is missing required field(s): {', '.join(missing)}")
    return ExecutionExpectation(
        expect_executed_steps=require_nonnegative_int(raw["expect_executed_steps"], f"{label}.expect_executed_steps"),
        expect_boot_count=require_nonnegative_int(raw["expect_boot_count"], f"{label}.expect_boot_count"),
        expect_resize_count=require_nonnegative_int(raw["expect_resize_count"], f"{label}.expect_resize_count"),
    )


def parse_case_spec(value: Any, label: str) -> CaseSpec:
    raw = require_object(value, label)
    reject_unknown_fields(
        raw,
        {
            "description",
            "expect",
            "initial_cache",
            "initial_execution",
            "scan_prefixes",
            "compare_mtime_paths",
            "compare_hardlink_paths",
            "empty_dirs",
            "symlinks",
            "modes",
            "build_args",
            "base_env",
            "network",
            "transitions",
        },
        label,
    )
    required = {"description", "expect", "scan_prefixes"}
    missing = sorted(required - set(raw))
    if missing:
        raise HarnessError(f"{label} is missing required field(s): {', '.join(missing)}")
    expect = parse_expectation(raw["expect"], f"{label}.expect")
    initial_cache = (
        parse_cache_status(raw["initial_cache"], f"{label}.initial_cache")
        if "initial_cache" in raw
        else None
    )
    if expect.spore is Outcome.SUCCESS and initial_cache is None:
        raise HarnessError(f"{label}.initial_cache is required when Spore should succeed")
    if expect.spore is Outcome.FAILURE and initial_cache is not None:
        raise HarnessError(f"{label}.initial_cache is invalid when Spore should fail")
    initial_execution = (
        parse_execution_expectation(raw["initial_execution"], f"{label}.initial_execution")
        if "initial_execution" in raw
        else None
    )
    if expect.spore is Outcome.SUCCESS and initial_execution is None:
        raise HarnessError(f"{label}.initial_execution is required when Spore should succeed")
    if expect.spore is Outcome.FAILURE and initial_execution is not None:
        raise HarnessError(f"{label}.initial_execution is invalid when Spore should fail")
    transitions_value = raw.get("transitions", [])
    if not isinstance(transitions_value, list):
        raise HarnessError(f"{label}.transitions must be an array")
    transitions = tuple(
        parse_transition(item, f"{label}.transitions[{index}]")
        for index, item in enumerate(transitions_value)
    )
    transition_names = [transition.name for transition in transitions]
    if len(set(transition_names)) != len(transition_names):
        raise HarnessError(f"{label}.transitions contains duplicate names")
    return CaseSpec(
        description=require_string(raw["description"], f"{label}.description"),
        expect=expect,
        initial_cache=initial_cache,
        initial_execution=initial_execution,
        scan_prefixes=require_string_list(raw["scan_prefixes"], f"{label}.scan_prefixes"),
        compare_mtime_paths=require_string_list(
            raw.get("compare_mtime_paths", []), f"{label}.compare_mtime_paths"
        ),
        compare_hardlink_paths=require_string_list(
            raw.get("compare_hardlink_paths", []), f"{label}.compare_hardlink_paths"
        ),
        empty_dirs=require_string_list(raw.get("empty_dirs", []), f"{label}.empty_dirs"),
        symlinks=require_string_map(raw.get("symlinks", {}), f"{label}.symlinks"),
        modes=require_string_map(raw.get("modes", {}), f"{label}.modes"),
        build_args=require_string_map(raw.get("build_args", {}), f"{label}.build_args"),
        base_env=(
            require_string_list(raw["base_env"], f"{label}.base_env", nonempty=False)
            if "base_env" in raw
            else None
        ),
        network=parse_spore_network(raw.get("network", "none"), f"{label}.network"),
        transitions=transitions,
    )


def load_cases(fixtures: pathlib.Path) -> list[Case]:
    cases: list[Case] = []
    if not fixtures.is_dir():
        raise HarnessError(f"fixture root does not exist: {fixtures}")
    for manifest_path in sorted(fixtures.glob("*/case.json")):
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise HarnessError(f"cannot load fixture manifest {manifest_path}: {error}") from error
        spec = parse_case_spec(manifest, str(manifest_path))
        name = manifest_path.parent.name
        context = manifest_path.parent / "context"
        if not (context / "Dockerfile").is_file():
            raise HarnessError(f"case {name} has no context/Dockerfile")
        cases.append(Case(name=name, root=manifest_path.parent, spec=spec))
    if not cases:
        raise HarnessError(f"no conformance cases found below {fixtures}")
    return cases


def self_test_schema(cases: list[Case]) -> None:
    for case in cases:
        if case.spec.expect.spore is Outcome.SUCCESS and case.spec.initial_execution is None:
            raise HarnessError(f"self-test: {case.name} lacks initial execution counts")
        if not all(isinstance(item, Transition) for item in case.spec.transitions):
            raise HarnessError(f"self-test: {case.name} has a non-Transition transition")

    valid = {
        "description": "schema self-test",
        "expect": {"docker": "success", "spore": "success"},
        "initial_cache": "miss",
        "initial_execution": {
            "expect_executed_steps": 1,
            "expect_boot_count": 1,
            "expect_resize_count": 1,
        },
        "scan_prefixes": [],
    }
    invalid = [
        {**valid, "unknown": True},
        {**valid, "expect": {"docker": "success", "spore": "success", "spore_exit_code": 0}},
        {**valid, "initial_execution": {"expect_executed_steps": 1, "expect_boot_count": 1}},
        {**valid, "initial_execution": {"expect_executed_steps": -1, "expect_boot_count": 1, "expect_resize_count": 1}},
        {
            **valid,
            "transitions": [
                {
                    "name": "bad-no-cache",
                    "expect_cache": "miss",
                    "expect_executed_steps": 1,
                    "expect_boot_count": 1,
                    "expect_resize_count": 0,
                    "no_cache": "yes",
                }
            ],
        },
        {
            **valid,
            "transitions": [
                {
                    "name": "bad-failure-without-diagnostic",
                    "outcome": "failure",
                }
            ],
        },
    ]
    for index, fixture in enumerate(invalid):
        try:
            parse_case_spec(fixture, f"self-test[{index}]")
        except HarnessError:
            continue
        raise HarnessError(f"self-test[{index}] unexpectedly accepted invalid schema")

    records = [{"path": "/a", "mtime_ns": 1, "hardlink_to": "/b"}]
    normalize_filesystem_records(records, set(), set())
    if records != [{"path": "/a"}]:
        raise HarnessError("self-test: filesystem normalization changed")
    normalized = normalized_config("arm64", "linux", {"WorkingDir": None})
    if normalized["config"]["WorkingDir"] != "":
        raise HarnessError("self-test: config normalization changed")
    if diff_json(normalized, normalized, "left", "right"):
        raise HarnessError("self-test: equal normalized config produced a diff")


def select_cases(cases: list[Case], requested: list[str] | None) -> list[Case]:
    if not requested:
        return cases
    by_name = {case.name: case for case in cases}
    unknown = sorted(set(requested) - by_name.keys())
    if unknown:
        raise HarnessError(f"unknown case(s): {', '.join(unknown)}")
    selected: list[Case] = []
    seen: set[str] = set()
    for name in requested:
        if name not in seen:
            selected.append(by_name[name])
            seen.add(name)
    return selected


def parse_spore_build(result: CommandResult) -> SporeBuildResult:
    fields: dict[str, str] = {}
    executor: dict[str, int] = {}
    for line in result.stdout.splitlines():
        stripped = line.strip()
        for label, key in (
            ("Rootfs index:", "index"),
            ("Metadata:", "metadata"),
            ("Cache:", "cache"),
        ):
            if stripped.startswith(label):
                fields[key] = stripped[len(label) :].strip()
        if stripped.startswith("Executor:"):
            raw_fields = stripped[len("Executor:") :].strip().split()
            try:
                parsed = dict(field.split("=", 1) for field in raw_fields)
                if set(parsed) != {"executed_steps", "boot_count", "resize_count"}:
                    raise ValueError("unexpected executor fields")
                executor = {key: int(value) for key, value in parsed.items()}
                if any(value < 0 for value in executor.values()):
                    raise ValueError("negative executor field")
            except ValueError as error:
                raise CaseError(f"Spore emitted malformed Executor diagnostics: {stripped!r}") from error
    return SporeBuildResult(
        command=result,
        index_digest=fields.get("index"),
        metadata_path=pathlib.Path(fields["metadata"]) if "metadata" in fields else None,
        cache_status=fields.get("cache"),
        executed_steps=executor.get("executed_steps"),
        boot_count=executor.get("boot_count"),
        resize_count=executor.get("resize_count"),
    )


def exact_spore_diagnostic(stderr: str) -> str | None:
    for line in stderr.splitlines():
        if line.startswith("spore build:"):
            return line.rstrip()
    return None


def parse_jsonl(result: CommandResult) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(result.stdout.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise CaseError(f"scanner emitted invalid JSON on line {line_number}: {error}: {line!r}") from error
        if not isinstance(value, dict) or "path" not in value:
            raise CaseError(f"scanner emitted invalid record on line {line_number}: {line!r}")
        records.append(value)
    return sorted(records, key=lambda value: value["path"])


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def diff_json(expected: Any, actual: Any, expected_name: str, actual_name: str) -> str:
    expected_lines = (json.dumps(expected, indent=2, sort_keys=True) + "\n").splitlines(keepends=True)
    actual_lines = (json.dumps(actual, indent=2, sort_keys=True) + "\n").splitlines(keepends=True)
    return "".join(
        difflib.unified_diff(expected_lines, actual_lines, fromfile=expected_name, tofile=actual_name)
    )


def normalized_config(architecture: Any, operating_system: Any, runtime: dict[str, Any] | None) -> dict[str, Any]:
    runtime = runtime or {}
    normalized_runtime: dict[str, Any] = {}
    for field in CONFIG_FIELDS:
        value = runtime.get(field)
        if field in {"WorkingDir", "User"}:
            value = value or ""
        normalized_runtime[field] = value
    return {
        "architecture": architecture,
        "os": operating_system,
        "config": normalized_runtime,
    }


def normalize_filesystem_records(
    records: list[dict[str, Any]],
    mtime_paths: set[str],
    hardlink_paths: set[str],
) -> None:
    for record in records:
        path = record.get("path")
        if path not in mtime_paths:
            record.pop("mtime_ns", None)
        if path not in hardlink_paths:
            record.pop("hardlink_to", None)


def assert_expected_builds(case: Case, docker: CommandResult, spore: SporeBuildResult) -> bool:
    expected = case.spec.expect
    if (docker.returncode == 0) != (expected.docker is Outcome.SUCCESS):
        raise CaseError(
            f"Docker expected {expected.docker.value}, got exit {docker.returncode}\n"
            f"{command_failure(docker)}"
        )
    if (spore.command.returncode == 0) != (expected.spore is Outcome.SUCCESS):
        raise CaseError(
            f"Spore expected {expected.spore.value}, got exit {spore.command.returncode}\n"
            f"{command_failure(spore.command)}"
        )
    if expected.spore is Outcome.FAILURE:
        expected_diagnostic = expected.spore_diagnostic
        actual_diagnostic = exact_spore_diagnostic(spore.command.stderr)
        if expected_diagnostic != actual_diagnostic:
            raise CaseError(
                "Spore diagnostic mismatch:\n"
                + diff_json(expected_diagnostic, actual_diagnostic, "expected", "actual")
            )
        if expected.spore_exit_code is not None:
            exit_diagnostic = (
                f"spore build: executor step failed with exit code {expected.spore_exit_code}"
            )
            if exit_diagnostic not in spore.command.stderr.splitlines():
                raise CaseError(f"Spore did not emit exact exit diagnostic: {exit_diagnostic!r}")
        return False
    return True


def assert_cache_status(actual: str | None, expected: CacheStatus, phase: str) -> None:
    if actual != expected.value:
        raise CaseError(f"{phase}: expected Spore cache {expected.value!r}, got {actual!r}")


def assert_execution_diagnostics(actual: SporeBuildResult, expected: Transition | ExecutionExpectation, phase: str) -> None:
    fields = (
        ("executed_steps", actual.executed_steps, expected.expect_executed_steps),
        ("boot_count", actual.boot_count, expected.expect_boot_count),
        ("resize_count", actual.resize_count, expected.expect_resize_count),
    )
    for name, actual_value, expected_value in fields:
        if actual_value != expected_value:
            raise CaseError(
                f"{phase}: expected Spore {name}={expected_value}, got {actual_value!r}"
            )
