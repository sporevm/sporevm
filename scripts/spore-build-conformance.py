#!/usr/bin/env python3
"""Differential Docker/Spore conformance harness for the landed build subset."""

from __future__ import annotations

import argparse
import dataclasses
import difflib
import enum
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid
from typing import Any, Iterable


PLATFORM = "linux/arm64"
BUILDKIT_IMAGE = (
    "moby/buildkit@sha256:"
    "0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f"
)
BUILDKIT_VERSION = "v0.30.0"
SCANNER = "/usr/local/bin/spore-build-conformance-scan"
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


@dataclasses.dataclass(frozen=True)
class Transition:
    name: str
    writes: dict[str, str]
    preserve_mtime: tuple[str, ...]
    expect_cache: CacheStatus
    expect_index: IndexExpectation | None
    expect_executed_steps: int
    expect_boot_count: int
    expect_resize_count: int
    compare: bool


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
    network: SporeNetwork
    transitions: tuple[Transition, ...]


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    root: pathlib.Path
    spec: CaseSpec


def parse_args() -> argparse.Namespace:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description=(
            "Build small Dockerfile fixtures with BuildKit and Spore, then "
            "compare fixture-owned filesystem metadata and normalized OCI config."
        )
    )
    parser.add_argument(
        "--spore-bin",
        default=str(repo_root / "zig-out/bin/spore"),
        help="spore binary (default: %(default)s)",
    )
    parser.add_argument(
        "--fixtures",
        type=pathlib.Path,
        default=repo_root / "test/build/conformance",
        help="fixture root (default: %(default)s)",
    )
    parser.add_argument(
        "--builder",
        help="existing docker buildx builder; otherwise create a temporary docker-container builder",
    )
    parser.add_argument(
        "--case",
        action="append",
        dest="cases",
        help="run one named case (repeatable; default: all)",
    )
    parser.add_argument("--list", action="store_true", help="list cases and exit")
    parser.add_argument(
        "--self-test-schema",
        action="store_true",
        help="validate fixture manifests and strict initial/transition parser failures",
    )
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="validate Docker, Buildx, linux/arm64, Spore, and a native hypervisor, then exit",
    )
    parser.add_argument(
        "--work-dir",
        type=pathlib.Path,
        help="write artifacts here instead of a temporary directory",
    )
    parser.add_argument(
        "--keep-work",
        action="store_true",
        help="keep a temporary work directory after a successful run",
    )
    return parser.parse_args()


def run_command(
    command: Iterable[str],
    *,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
    log_prefix: pathlib.Path | None = None,
) -> CommandResult:
    argv = tuple(str(part) for part in command)
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        if log_prefix is not None:
            log_prefix.parent.mkdir(parents=True, exist_ok=True)
            log_prefix.with_suffix(".command").write_text(shlex.join(argv) + "\n")
            log_prefix.with_suffix(".stdout").write_text("")
            log_prefix.with_suffix(".stderr").write_text(f"{error}\n")
        raise HarnessError(f"cannot execute {argv[0]!r}: {error}") from error
    result = CommandResult(argv, completed.returncode, completed.stdout, completed.stderr)
    if log_prefix is not None:
        log_prefix.parent.mkdir(parents=True, exist_ok=True)
        log_prefix.with_suffix(".command").write_text(shlex.join(argv) + "\n")
        log_prefix.with_suffix(".stdout").write_text(result.stdout)
        log_prefix.with_suffix(".stderr").write_text(result.stderr)
    return result


def command_failure(result: CommandResult) -> str:
    details = [
        f"command failed ({result.returncode}): {shlex.join(result.command)}",
    ]
    if result.stdout.strip():
        details.append("stdout:\n" + result.stdout[-4000:])
    if result.stderr.strip():
        details.append("stderr:\n" + result.stderr[-4000:])
    return "\n".join(details)


def require_success(result: CommandResult) -> CommandResult:
    if result.returncode != 0:
        raise HarnessError(command_failure(result))
    return result


def run_best_effort(command: Iterable[str]) -> None:
    try:
        run_command(command)
    except HarnessError:
        pass


def resolve_executable(raw: str) -> str:
    path = pathlib.Path(raw).expanduser()
    if path.parent != pathlib.Path(".") or "/" in raw:
        resolved = path.resolve()
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            raise HarnessError(f"spore binary is not executable: {resolved}")
        return str(resolved)
    resolved = shutil.which(raw)
    if resolved is None:
        raise HarnessError(f"spore binary not found on PATH: {raw}")
    return resolved


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


def require_string_list(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise HarnessError(f"{label} must be an array of strings")
    return tuple(require_string(item, f"{label}[{index}]") for index, item in enumerate(value))


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
    reject_unknown_fields(raw, {"docker", "spore", "spore_diagnostic"}, label)
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
    if spore is Outcome.FAILURE and diagnostic is None:
        raise HarnessError(f"{label}.spore_diagnostic is required when Spore should fail")
    if spore is Outcome.SUCCESS and diagnostic is not None:
        raise HarnessError(f"{label}.spore_diagnostic is only valid when Spore should fail")
    return BuildExpectation(docker=docker, spore=spore, spore_diagnostic=diagnostic)


def parse_transition(value: Any, label: str) -> Transition:
    raw = require_object(value, label)
    reject_unknown_fields(
        raw,
        {
            "name",
            "writes",
            "preserve_mtime",
            "expect_cache",
            "expect_index",
            "expect_executed_steps",
            "expect_boot_count",
            "expect_resize_count",
            "compare",
        },
        label,
    )
    required = {
        "name",
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
    return Transition(
        name=require_string(raw["name"], f"{label}.name"),
        writes=require_string_map(raw.get("writes", {}), f"{label}.writes"),
        preserve_mtime=require_string_list(
            raw.get("preserve_mtime", []), f"{label}.preserve_mtime"
        ),
        expect_cache=parse_cache_status(raw["expect_cache"], f"{label}.expect_cache"),
        expect_index=(
            parse_index_expectation(raw["expect_index"], f"{label}.expect_index")
            if "expect_index" in raw
            else None
        ),
        expect_executed_steps=require_nonnegative_int(
            raw["expect_executed_steps"], f"{label}.expect_executed_steps"
        ),
        expect_boot_count=require_nonnegative_int(
            raw["expect_boot_count"], f"{label}.expect_boot_count"
        ),
        expect_resize_count=require_nonnegative_int(
            raw["expect_resize_count"], f"{label}.expect_resize_count"
        ),
        compare=compare,
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
        {**valid, "initial_execution": {"expect_executed_steps": 1, "expect_boot_count": 1}},
        {**valid, "initial_execution": {"expect_executed_steps": -1, "expect_boot_count": 1, "expect_resize_count": 1}},
    ]
    for index, fixture in enumerate(invalid):
        try:
            parse_case_spec(fixture, f"self-test[{index}]")
        except HarnessError:
            continue
        raise HarnessError(f"self-test[{index}] unexpectedly accepted invalid schema")


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


def create_builder(
    requested: str | None, run_id: str, logs: pathlib.Path
) -> tuple[str, bool, str, str]:
    require_success(run_command(["docker", "info"], log_prefix=logs / "docker-info"))
    buildx_version = require_success(
        run_command(["docker", "buildx", "version"], log_prefix=logs / "buildx-version")
    ).stdout.strip()

    if requested:
        builder = requested
        owned = False
    else:
        builder = f"spore-conformance-{run_id}"
        created = run_command(
            [
                "docker",
                "buildx",
                "create",
                "--name",
                builder,
                "--driver",
                "docker-container",
                "--driver-opt",
                f"image={BUILDKIT_IMAGE}",
            ],
            log_prefix=logs / "builder-create",
        )
        require_success(created)
        owned = True

    try:
        inspected = run_command(
            ["docker", "buildx", "inspect", builder, "--bootstrap"],
            log_prefix=logs / "builder-inspect",
        )
        require_success(inspected)
        if PLATFORM not in inspected.stdout:
            raise HarnessError(
                f"buildx builder {builder!r} does not advertise {PLATFORM}\n{inspected.stdout}"
            )
    except HarnessError:
        if owned:
            run_best_effort(["docker", "buildx", "rm", "--force", builder])
        raise
    buildkit_version = "unknown"
    for line in inspected.stdout.splitlines():
        if line.strip().startswith("BuildKit version:"):
            buildkit_version = line.split(":", 1)[1].strip()
            break
    if buildkit_version != BUILDKIT_VERSION:
        if owned:
            run_best_effort(["docker", "buildx", "rm", "--force", builder])
        raise HarnessError(
            f"buildx builder {builder!r} uses BuildKit {buildkit_version!r}; "
            f"the conformance oracle requires {BUILDKIT_VERSION!r}"
        )
    return builder, owned, buildx_version, buildkit_version


def check_spore_host(spore_bin: str, logs: pathlib.Path) -> str:
    result = run_command(
        [spore_bin, "--json", "host-info"],
        log_prefix=logs / "spore-host-info",
    )
    require_success(result)
    try:
        info = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HarnessError(f"spore host-info did not return JSON: {error}") from error
    available = [backend.get("name") for backend in info.get("backends", []) if backend.get("available")]
    if not available:
        raise HarnessError("spore host-info reports no available native hypervisor")
    return ",".join(str(name) for name in available)


def safe_extract_oci(archive: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*") as handle:
        members = handle.getmembers()
        for member in members:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise HarnessError(f"unsafe path in BuildKit OCI archive: {member.name}")
        handle.extractall(destination, members=members)
    if not (destination / "oci-layout").is_file() or not (destination / "index.json").is_file():
        raise HarnessError("BuildKit base output is not an OCI image layout")


def build_base(
    builder: str,
    fixtures: pathlib.Path,
    work_dir: pathlib.Path,
    logs: pathlib.Path,
) -> pathlib.Path:
    archive = work_dir / "base-oci.tar"
    layout = work_dir / "base-oci"
    result = run_command(
        [
            "docker",
            "buildx",
            "build",
            "--builder",
            builder,
            "--platform",
            PLATFORM,
            "--provenance=false",
            "--progress=plain",
            "--output",
            f"type=oci,dest={archive}",
            str(fixtures / "base"),
        ],
        log_prefix=logs / "base-build",
    )
    require_success(result)
    safe_extract_oci(archive, layout)
    return layout


def confined_path(root: pathlib.Path, raw: str) -> pathlib.Path:
    relative = pathlib.PurePosixPath(raw)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise HarnessError(f"fixture path must be non-empty and relative: {raw!r}")
    return root.joinpath(*relative.parts)


def materialize_context(case: Case, destination: pathlib.Path) -> None:
    shutil.copytree(case.root / "context", destination, symlinks=True)
    for raw in case.spec.empty_dirs:
        confined_path(destination, raw).mkdir(parents=True, exist_ok=True)
    for raw, target in case.spec.symlinks.items():
        path = confined_path(destination, raw)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
    for raw, mode in case.spec.modes.items():
        confined_path(destination, raw).chmod(int(mode, 8))


def apply_transition(context: pathlib.Path, transition: Transition) -> None:
    preserve = set(transition.preserve_mtime)
    for raw, contents in transition.writes.items():
        path = confined_path(context, raw)
        prior = path.stat() if raw in preserve else None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        if prior is not None:
            os.utime(path, ns=(prior.st_atime_ns, prior.st_mtime_ns))


def build_args(spec: CaseSpec) -> list[str]:
    args: list[str] = []
    for key, value in sorted(spec.build_args.items()):
        args.extend(["--build-arg", f"{key}={value}"])
    return args


def oci_layout_uri(path: pathlib.Path) -> str:
    return "oci-layout://" + str(path.resolve())


def docker_build(
    builder: str,
    case: Case,
    context: pathlib.Path,
    base_layout: pathlib.Path,
    tag: str,
    log_prefix: pathlib.Path,
) -> CommandResult:
    command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        builder,
        "--platform",
        PLATFORM,
        "--provenance=false",
        "--progress=plain",
        "--build-context",
        f"base={oci_layout_uri(base_layout)}",
        "--load",
        "--tag",
        tag,
        *build_args(case.spec),
        str(context),
    ]
    return run_command(command, log_prefix=log_prefix)


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


def spore_build(
    spore_bin: str,
    spore_env: dict[str, str],
    case: Case,
    context: pathlib.Path,
    base_layout: pathlib.Path,
    tag: str,
    log_prefix: pathlib.Path,
) -> SporeBuildResult:
    command = [
        spore_bin,
        "build",
        "--tag",
        tag,
        "--platform",
        PLATFORM,
        "--build-context",
        f"base={oci_layout_uri(base_layout)}",
        "--network",
        case.spec.network.value,
        *build_args(case.spec),
        str(context),
    ]
    return parse_spore_build(run_command(command, env=spore_env, log_prefix=log_prefix))


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


def capture_filesystems(
    spore_bin: str,
    spore_env: dict[str, str],
    docker_tag: str,
    spore_tag: str,
    prefixes: list[str],
    output_dir: pathlib.Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    docker_result = run_command(
        [
            "docker",
            "run",
            "--rm",
            "--platform",
            PLATFORM,
            "--entrypoint",
            SCANNER,
            docker_tag,
            *prefixes,
        ],
        log_prefix=output_dir / "docker-scan",
    )
    require_success(docker_result)
    spore_result = run_command(
        [spore_bin, "run", "--image", spore_tag, "--", SCANNER, *prefixes],
        env=spore_env,
        log_prefix=output_dir / "spore-scan",
    )
    require_success(spore_result)
    docker_records = parse_jsonl(docker_result)
    spore_records = parse_jsonl(spore_result)
    write_json(output_dir / "docker-filesystem.json", docker_records)
    write_json(output_dir / "spore-filesystem.json", spore_records)
    return docker_records, spore_records


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


def capture_configs(
    docker_tag: str,
    spore_metadata: pathlib.Path,
    output_dir: pathlib.Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    inspected = run_command(
        ["docker", "image", "inspect", docker_tag],
        log_prefix=output_dir / "docker-inspect",
    )
    require_success(inspected)
    docker_values = json.loads(inspected.stdout)
    if not isinstance(docker_values, list) or len(docker_values) != 1:
        raise CaseError("docker image inspect returned an unexpected result")
    docker_value = docker_values[0]
    docker_config = normalized_config(
        docker_value.get("Architecture"),
        docker_value.get("Os"),
        docker_value.get("Config"),
    )

    try:
        spore_value = json.loads(spore_metadata.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CaseError(f"cannot read Spore metadata {spore_metadata}: {error}") from error
    image_config = spore_value.get("config") or {}
    spore_config = normalized_config(
        image_config.get("architecture"),
        image_config.get("os"),
        image_config.get("config"),
    )
    write_json(output_dir / "docker-config.json", docker_config)
    write_json(output_dir / "spore-config.json", spore_config)
    return docker_config, spore_config


def compare_outputs(
    spore_bin: str,
    spore_env: dict[str, str],
    case: Case,
    docker_tag: str,
    spore_tag: str,
    spore_metadata: pathlib.Path,
    output_dir: pathlib.Path,
) -> None:
    prefixes = list(case.spec.scan_prefixes)
    docker_filesystem, spore_filesystem = capture_filesystems(
        spore_bin,
        spore_env,
        docker_tag,
        spore_tag,
        prefixes,
        output_dir,
    )
    mtime_paths = set(case.spec.compare_mtime_paths)
    hardlink_paths = set(case.spec.compare_hardlink_paths)
    for records in (docker_filesystem, spore_filesystem):
        for record in records:
            path = record.get("path")
            if path not in mtime_paths:
                record.pop("mtime_ns", None)
            if path not in hardlink_paths:
                record.pop("hardlink_to", None)
    filesystem_diff = diff_json(
        docker_filesystem,
        spore_filesystem,
        "docker-filesystem.json",
        "spore-filesystem.json",
    )
    if filesystem_diff:
        (output_dir / "filesystem.diff").write_text(filesystem_diff)
        raise CaseError(f"filesystem mismatch:\n{filesystem_diff}")

    docker_config, spore_config = capture_configs(docker_tag, spore_metadata, output_dir)
    config_diff = diff_json(docker_config, spore_config, "docker-config.json", "spore-config.json")
    if config_diff:
        (output_dir / "config.diff").write_text(config_diff)
        raise CaseError(f"OCI config mismatch:\n{config_diff}")


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


def run_case(
    builder: str,
    spore_bin: str,
    spore_env: dict[str, str],
    case: Case,
    base_layout: pathlib.Path,
    work_dir: pathlib.Path,
    docker_tag: str,
    spore_tag: str,
) -> None:
    case_dir = work_dir / "cases" / case.name
    context = case_dir / "context"
    materialize_context(case, context)
    initial_dir = case_dir / "initial"

    docker = docker_build(builder, case, context, base_layout, docker_tag, initial_dir / "docker-build")
    spore = spore_build(
        spore_bin,
        spore_env,
        case,
        context,
        base_layout,
        spore_tag,
        initial_dir / "spore-build",
    )
    if not assert_expected_builds(case, docker, spore):
        return
    initial_cache = case.spec.initial_cache
    if initial_cache is not None:
        assert_cache_status(spore.cache_status, initial_cache, "initial")
    initial_execution = case.spec.initial_execution
    if initial_execution is not None:
        assert_execution_diagnostics(spore, initial_execution, "initial")
    if spore.index_digest is None or spore.metadata_path is None:
        raise CaseError("successful Spore build did not report rootfs index and metadata")
    compare_outputs(
        spore_bin,
        spore_env,
        case,
        docker_tag,
        spore_tag,
        spore.metadata_path,
        initial_dir,
    )

    prior_index = spore.index_digest
    for transition in case.spec.transitions:
        name = transition.name
        transition_dir = case_dir / name
        apply_transition(context, transition)
        transitioned = spore_build(
            spore_bin,
            spore_env,
            case,
            context,
            base_layout,
            spore_tag,
            transition_dir / "spore-build",
        )
        if transitioned.command.returncode != 0:
            raise CaseError(f"transition {name}: {command_failure(transitioned.command)}")
        assert_cache_status(transitioned.cache_status, transition.expect_cache, name)
        assert_execution_diagnostics(transitioned, transition, name)
        if transitioned.index_digest is None or transitioned.metadata_path is None:
            raise CaseError(f"transition {name}: Spore omitted index or metadata")
        expected_index = transition.expect_index
        if expected_index is IndexExpectation.SAME and transitioned.index_digest != prior_index:
            raise CaseError(f"transition {name}: expected unchanged rootfs index")
        if expected_index is IndexExpectation.CHANGED and transitioned.index_digest == prior_index:
            raise CaseError(f"transition {name}: expected changed rootfs index")
        prior_index = transitioned.index_digest

        if transition.compare:
            rebuilt = docker_build(
                builder,
                case,
                context,
                base_layout,
                docker_tag,
                transition_dir / "docker-build",
            )
            if rebuilt.returncode != 0:
                raise CaseError(f"transition {name}: {command_failure(rebuilt)}")
            compare_outputs(
                spore_bin,
                spore_env,
                case,
                docker_tag,
                spore_tag,
                transitioned.metadata_path,
                transition_dir,
            )


def main() -> int:
    args = parse_args()
    try:
        all_cases = load_cases(args.fixtures.resolve())
        if args.self_test_schema:
            self_test_schema(all_cases)
            print("spore-build-conformance schema self-test ok")
            return 0
        if args.list:
            for case in all_cases:
                print(f"{case.name}\t{case.spec.description}")
            return 0
        cases = select_cases(all_cases, args.cases)
        spore_bin = resolve_executable(args.spore_bin)
    except HarnessError as error:
        print(f"spore-build-conformance: {error}", file=sys.stderr)
        return 2

    explicit_work_dir = args.work_dir is not None
    if explicit_work_dir:
        work_dir = args.work_dir.expanduser().resolve()
        if work_dir.exists() and not work_dir.is_dir():
            print(
                f"spore-build-conformance: work path is not a directory: {work_dir}",
                file=sys.stderr,
            )
            return 2
        if work_dir.exists() and any(work_dir.iterdir()):
            print(
                f"spore-build-conformance: work directory is not empty: {work_dir}",
                file=sys.stderr,
            )
            return 2
        work_dir.mkdir(parents=True, exist_ok=True)
    else:
        work_dir = pathlib.Path(tempfile.mkdtemp(prefix="spore-build-conformance."))
    logs = work_dir / "logs"
    run_id = uuid.uuid4().hex[:12]
    builder: str | None = None
    owned_builder = False
    docker_tags: list[str] = []
    succeeded = False

    try:
        builder, owned_builder, buildx_version, buildkit_version = create_builder(
            args.builder, run_id, logs
        )
        hypervisors = check_spore_host(spore_bin, logs)
        print(
            f"preflight: {buildx_version}; BuildKit {buildkit_version}; "
            f"builder={builder}; platform={PLATFORM}; hypervisor={hypervisors}"
        )
        if args.preflight_only:
            succeeded = True
            return 0

        base_layout = build_base(builder, args.fixtures.resolve(), work_dir, logs)
        failures: list[tuple[str, str]] = []
        for case in cases:
            # Initial execution counts are cold-case contracts. Isolate both
            # authoritative cache state and transient runtime state per case,
            # while keeping the same environment for that case's warm/edit
            # transitions. Otherwise an earlier fixture can satisfy a later
            # fixture's PREPARE or identical Dockerfile-step key.
            case_state = work_dir / "cases" / case.name
            spore_cache = case_state / "spore-rootfs-cache"
            spore_runtime = case_state / "spore-runtime"
            spore_cache.mkdir(parents=True, exist_ok=True)
            spore_runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
            spore_runtime.chmod(0o700)
            spore_env = os.environ.copy()
            spore_env["SPOREVM_ROOTFS_CACHE_DIR"] = str(spore_cache)
            spore_env["SPOREVM_RUNTIME_DIR"] = str(spore_runtime)
            docker_tag = f"spore-build-conformance-{run_id}-{case.name}:docker"
            spore_tag = f"local/spore-build-conformance-{run_id}-{case.name}:dev"
            docker_tags.append(docker_tag)
            print(f"case {case.name}: {case.spec.description}")
            try:
                run_case(
                    builder,
                    spore_bin,
                    spore_env,
                    case,
                    base_layout,
                    work_dir,
                    docker_tag,
                    spore_tag,
                )
            except (HarnessError, OSError, ValueError, json.JSONDecodeError) as error:
                failures.append((case.name, str(error)))
                print(f"case {case.name}: FAIL", file=sys.stderr)
            else:
                print(f"case {case.name}: ok")

        if failures:
            for name, error in failures:
                print(f"\n[{name}]\n{error}", file=sys.stderr)
            raise HarnessError(f"{len(failures)} of {len(cases)} conformance cases failed")
        succeeded = True
        print(f"spore-build-conformance: {len(cases)} cases passed")
        return 0
    except (HarnessError, OSError, ValueError, tarfile.TarError) as error:
        print(f"spore-build-conformance: {error}", file=sys.stderr)
        return 1
    finally:
        for tag in docker_tags:
            run_best_effort(["docker", "image", "rm", "--force", tag])
        if owned_builder and builder is not None:
            run_best_effort(["docker", "buildx", "rm", "--force", builder])
        keep_work = args.keep_work or explicit_work_dir or not succeeded
        if keep_work:
            print(f"artifacts: {work_dir}", file=sys.stderr if not succeeded else sys.stdout)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
