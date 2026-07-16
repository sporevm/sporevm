#!/usr/bin/env python3
"""Differential Docker/Spore conformance harness for the landed build subset."""

from __future__ import annotations

import argparse
import hashlib
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

from spore_build_conformance_contract import (
    BUILDKIT_IMAGE,
    BUILDKIT_VERSION,
    PLATFORM,
    SCANNER,
    SCANNER_PYTHON,
    CacheStatus,
    Case,
    CaseError,
    CaseSpec,
    CommandResult,
    HarnessError,
    IndexExpectation,
    Outcome,
    SporeBuildResult,
    Transition,
    assert_cache_status,
    assert_execution_diagnostics,
    assert_expected_builds,
    command_failure,
    diff_json,
    exact_spore_diagnostic,
    load_cases,
    normalize_filesystem_records,
    normalized_config,
    parse_jsonl,
    parse_spore_build,
    select_cases,
    self_test_schema,
    write_json,
)


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


def blob_path(layout: pathlib.Path, digest: str) -> pathlib.Path:
    algorithm, separator, encoded = digest.partition(":")
    if separator != ":" or algorithm != "sha256" or len(encoded) != 64:
        raise HarnessError(f"unsupported OCI descriptor digest: {digest!r}")
    return layout / "blobs" / algorithm / encoded


def write_oci_blob(layout: pathlib.Path, payload: bytes) -> tuple[str, int]:
    digest = "sha256:" + hashlib.sha256(payload).hexdigest()
    path = blob_path(layout, digest)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return digest, len(payload)


def base_layout_for_case(base_layout: pathlib.Path, case: Case, case_dir: pathlib.Path) -> pathlib.Path:
    if case.spec.base_env is None:
        return base_layout

    layout = case_dir / "base-oci"
    shutil.copytree(base_layout, layout)
    index_path = layout / "index.json"
    index = json.loads(index_path.read_text())
    manifests = index.get("manifests")
    if not isinstance(manifests, list) or len(manifests) != 1:
        raise HarnessError("base OCI layout must contain exactly one manifest")
    descriptor = manifests[0]
    manifest = json.loads(blob_path(layout, descriptor["digest"]).read_text())
    config_descriptor = manifest.get("config")
    if not isinstance(config_descriptor, dict):
        raise HarnessError("base OCI manifest has no config descriptor")
    config = json.loads(blob_path(layout, config_descriptor["digest"]).read_text())
    runtime_config = config.setdefault("config", {})
    if not isinstance(runtime_config, dict):
        raise HarnessError("base OCI image config.config is not an object")
    runtime_config["Env"] = list(case.spec.base_env)

    config_payload = json.dumps(config, separators=(",", ":"), ensure_ascii=False).encode()
    config_descriptor["digest"], config_descriptor["size"] = write_oci_blob(layout, config_payload)
    manifest_payload = json.dumps(manifest, separators=(",", ":"), ensure_ascii=False).encode()
    descriptor["digest"], descriptor["size"] = write_oci_blob(layout, manifest_payload)
    index_path.write_text(json.dumps(index, separators=(",", ":")))
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


def build_publication_snapshot(spore_env: dict[str, str]) -> dict[str, str]:
    root = pathlib.Path(spore_env["SPOREVM_ROOTFS_CACHE_DIR"])
    paths = list((root / "build" / "steps").glob("*.json"))
    paths.extend((root / "refs").rglob("*.json"))
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(paths)
    }


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


def spore_build(
    spore_bin: str,
    spore_env: dict[str, str],
    case: Case,
    context: pathlib.Path,
    base_layout: pathlib.Path,
    tag: str,
    log_prefix: pathlib.Path,
    *,
    no_cache: bool = False,
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
        *(["--no-cache"] if no_cache else []),
        *build_args(case.spec),
        str(context),
    ]
    return parse_spore_build(run_command(command, env=spore_env, log_prefix=log_prefix))


def capture_filesystems(
    spore_bin: str,
    spore_env: dict[str, str],
    docker_tag: str,
    spore_tag: str,
    prefixes: list[str],
    scanner: list[str],
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
            scanner[0],
            docker_tag,
            *scanner[1:],
            *prefixes,
        ],
        log_prefix=output_dir / "docker-scan",
    )
    require_success(docker_result)
    spore_result = run_command(
        [spore_bin, "run", "--image", spore_tag, "--", *scanner, *prefixes],
        env=spore_env,
        log_prefix=output_dir / "spore-scan",
    )
    require_success(spore_result)
    docker_records = parse_jsonl(docker_result)
    spore_records = parse_jsonl(spore_result)
    write_json(output_dir / "docker-filesystem.json", docker_records)
    write_json(output_dir / "spore-filesystem.json", spore_records)
    return docker_records, spore_records


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
    scanner = [SCANNER_PYTHON, SCANNER] if case.spec.base_env is not None else [SCANNER]
    docker_filesystem, spore_filesystem = capture_filesystems(
        spore_bin,
        spore_env,
        docker_tag,
        spore_tag,
        prefixes,
        scanner,
        output_dir,
    )
    mtime_paths = set(case.spec.compare_mtime_paths)
    hardlink_paths = set(case.spec.compare_hardlink_paths)
    for records in (docker_filesystem, spore_filesystem):
        normalize_filesystem_records(records, mtime_paths, hardlink_paths)
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
    base_layout = base_layout_for_case(base_layout, case, case_dir)
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
        publication_before = build_publication_snapshot(spore_env)
        transitioned = spore_build(
            spore_bin,
            spore_env,
            case,
            context,
            base_layout,
            spore_tag,
            transition_dir / "spore-build",
            no_cache=transition.no_cache,
        )
        succeeded = transitioned.command.returncode == 0
        if succeeded != (transition.outcome is Outcome.SUCCESS):
            raise CaseError(
                f"transition {name}: expected {transition.outcome.value}, got exit "
                f"{transitioned.command.returncode}\n{command_failure(transitioned.command)}"
            )
        if transition.outcome is Outcome.FAILURE:
            actual_diagnostic = exact_spore_diagnostic(transitioned.command.stderr)
            if actual_diagnostic != transition.spore_diagnostic:
                raise CaseError(
                    f"transition {name}: Spore diagnostic mismatch:\n"
                    + diff_json(
                        transition.spore_diagnostic,
                        actual_diagnostic,
                        "expected",
                        "actual",
                    )
                )
            publication_after = build_publication_snapshot(spore_env)
            if publication_after != publication_before:
                raise CaseError(f"transition {name}: failed build changed step records or refs")
            continue
        assert transition.expect_cache is not None
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
