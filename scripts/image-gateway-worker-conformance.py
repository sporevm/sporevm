#!/usr/bin/env python3
"""Generate and verify architecture-independent image-gateway conversion fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "spore-image-gateway-worker-conformance-v1"
TARGETS = ("amd64", "arm64")
MAX_FIXTURE_FILE_BYTES = 64 * 1024 * 1024


class ConformanceError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, separators=(",", ": ")) + "\n").encode()


def sha256_digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def require_digest(value: Any, prefix: str, name: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != len(prefix) + 64
        or not value.startswith(prefix)
        or any(byte not in "0123456789abcdef" for byte in value[len(prefix) :])
    ):
        raise ConformanceError(f"{name} is not a canonical {prefix} digest")
    return value


def write_bytes(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def write_blob(layout: pathlib.Path, data: bytes) -> dict[str, Any]:
    digest = sha256_digest(data)
    write_bytes(layout / "blobs" / "sha256" / digest.removeprefix("sha256:"), data)
    return {"digest": digest, "size": len(data)}


def build_oci_layout(layout: pathlib.Path) -> dict[str, Any]:
    layout.mkdir(parents=True)
    write_bytes(layout / "oci-layout", canonical_json({"imageLayoutVersion": "1.0.0"}))

    layer = bytes(1024)
    layer_descriptor = {
        "mediaType": "application/vnd.oci.image.layer.v1.tar",
        **write_blob(layout, layer),
    }
    manifests: dict[str, str] = {}
    index_descriptors = []
    for arch in TARGETS:
        config = canonical_json(
            {
                "architecture": arch,
                "os": "linux",
                "rootfs": {"diff_ids": [layer_descriptor["digest"]], "type": "layers"},
            }
        )
        config_descriptor = {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            **write_blob(layout, config),
        }
        manifest = canonical_json(
            {
                "config": config_descriptor,
                "layers": [layer_descriptor],
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "schemaVersion": 2,
            }
        )
        manifest_descriptor = {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            **write_blob(layout, manifest),
            "platform": {"architecture": arch, "os": "linux"},
        }
        if arch == "arm64":
            manifest_descriptor["platform"]["variant"] = "v8"
        index_descriptors.append(manifest_descriptor)
        manifests[arch] = manifest_descriptor["digest"]

    index = canonical_json(
        {
            "manifests": index_descriptors,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "schemaVersion": 2,
        }
    )
    write_bytes(layout / "index.json", index)
    return {
        "index_digest": sha256_digest(index),
        "layer_digest": layer_descriptor["digest"],
        "manifests": manifests,
    }


def run(command: list[str], *, env: dict[str, str], cwd: pathlib.Path) -> str:
    completed = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    if completed.returncode != 0:
        rendered = " ".join(command)
        raise ConformanceError(
            f"command failed ({completed.returncode}): {rendered}\n{completed.stdout}{completed.stderr}"
        )
    return completed.stdout


def output_value(stdout: str, name: str) -> str:
    prefix = name + ": "
    values = [line.removeprefix(prefix) for line in stdout.splitlines() if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise ConformanceError(f"expected exactly one {name!r} value in command output")
    return values[0]


def read_bounded(path: pathlib.Path) -> bytes:
    size = path.stat().st_size
    if size > MAX_FIXTURE_FILE_BYTES:
        raise ConformanceError(f"fixture file exceeds {MAX_FIXTURE_FILE_BYTES} bytes: {path}")
    return path.read_bytes()


def only_file(root: pathlib.Path, name: str) -> pathlib.Path:
    matches = sorted(path for path in root.rglob(name) if path.is_file())
    if len(matches) != 1:
        raise ConformanceError(f"expected exactly one {name!r} below {root}, found {len(matches)}")
    return matches[0]


def parse_object(data: bytes, source: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConformanceError(f"invalid JSON in {source}: {error}") from error
    if not isinstance(value, dict):
        raise ConformanceError(f"expected JSON object in {source}")
    return value


def expected_chunk_size(index: dict[str, Any], logical_chunk: int) -> int:
    logical_size = index.get("logical_size")
    chunk_size = index.get("chunk_size")
    if not isinstance(logical_size, int) or not isinstance(chunk_size, int) or chunk_size <= 0:
        raise ConformanceError("rootfs index has invalid geometry")
    offset = logical_chunk * chunk_size
    if logical_chunk < 0 or offset >= logical_size:
        raise ConformanceError("rootfs index chunk lies outside logical size")
    return min(chunk_size, logical_size - offset)


def normalize_target(
    output: pathlib.Path,
    arch: str,
    gateway_root: pathlib.Path,
    selected_source_manifest: str,
) -> dict[str, Any]:
    target_root = output / "targets" / f"linux-{arch}"
    source_platform_index = only_file(gateway_root, "index")
    manifest_path = only_file(gateway_root, "manifest")
    config_path = only_file(gateway_root, "config")
    rootfs_index_path = only_file(gateway_root, "rootfs-index")
    copied = {
        "config.json": read_bounded(config_path),
        "image-manifest.json": read_bounded(manifest_path),
        "platform-index.json": read_bounded(source_platform_index),
        "rootfs-index.json": read_bounded(rootfs_index_path),
    }
    for name, data in copied.items():
        write_bytes(target_root / name, data)

    manifest = parse_object(copied["image-manifest.json"], manifest_path)
    index = parse_object(copied["rootfs-index.json"], rootfs_index_path)
    config = parse_object(copied["config.json"], config_path)
    platform_index = parse_object(copied["platform-index.json"], source_platform_index)
    image = manifest.get("image")
    rootfs = manifest.get("rootfs_index")
    if not isinstance(image, dict) or not isinstance(rootfs, dict):
        raise ConformanceError("gateway manifest is missing image or rootfs_index")
    manifest_platform = image.get("platform")
    if manifest_platform != {"os": "linux", "arch": arch}:
        raise ConformanceError(f"gateway manifest selected the wrong platform for linux/{arch}")
    if config.get("os") != "linux" or config.get("architecture") != arch:
        raise ConformanceError(f"canonical config selected the wrong platform for linux/{arch}")

    native_image_digest = require_digest(image.get("digest"), "blake3:", "native image digest")
    rootfs_index_digest = require_digest(rootfs.get("digest"), "blake3:", "rootfs index digest")
    storage = image.get("rootfs_storage")
    config_blob = image.get("config_blob")
    if not isinstance(storage, dict) or storage.get("index_digest") != rootfs_index_digest:
        raise ConformanceError("gateway manifest rootfs descriptors disagree")
    if not isinstance(config_blob, dict):
        raise ConformanceError("gateway manifest is missing config_blob")
    if config_blob.get("bytes") != len(copied["config.json"]) or config_blob.get(
        "transport_digest"
    ) != sha256_digest(copied["config.json"]):
        raise ConformanceError("gateway manifest config descriptor disagrees with config bytes")

    gateway_manifest_digest = sha256_digest(copied["image-manifest.json"])
    descriptors = platform_index.get("manifests")
    if not isinstance(descriptors, list) or len(descriptors) != 1:
        raise ConformanceError("fixture platform index must contain one descriptor")
    descriptor = descriptors[0]
    if not isinstance(descriptor, dict) or descriptor != {
        "platform": {"os": "linux", "arch": arch},
        "manifest_digest": gateway_manifest_digest,
        "image_digest": native_image_digest,
    }:
        raise ConformanceError("fixture platform descriptor disagrees with selected manifest")

    chunks = index.get("chunks")
    if not isinstance(chunks, list):
        raise ConformanceError("rootfs index is missing chunks")
    logical_chunks = [chunk.get("logical_chunk") for chunk in chunks if isinstance(chunk, dict)]
    if (
        len(logical_chunks) != len(chunks)
        or any(type(logical_chunk) is not int for logical_chunk in logical_chunks)
        or logical_chunks != sorted(set(logical_chunks))
    ):
        raise ConformanceError("rootfs index logical chunks are unordered or duplicated")
    objects_root = manifest_path.parent / "objects"
    objects = []
    seen = {}
    for chunk in chunks:
        if not isinstance(chunk, dict) or set(chunk) != {"digest", "logical_chunk"}:
            raise ConformanceError("rootfs index contains a malformed chunk descriptor")
        digest = chunk["digest"]
        logical_chunk = chunk["logical_chunk"]
        if not isinstance(digest, str) or not isinstance(logical_chunk, int):
            raise ConformanceError("rootfs index contains invalid chunk fields")
        require_digest(digest, "blake3:", "rootfs object digest")
        expected_size = expected_chunk_size(index, logical_chunk)
        if digest in seen:
            if seen[digest] != expected_size:
                raise ConformanceError(f"object {digest} is referenced with inconsistent sizes")
            continue
        seen[digest] = expected_size
        object_bytes = read_bounded(objects_root / digest)
        if len(object_bytes) != expected_size:
            raise ConformanceError(f"object {digest} has the wrong size")
        objects.append(
            {"bytes": len(object_bytes), "digest": digest, "sha256": sha256_digest(object_bytes)}
        )
    objects.sort(key=lambda item: item["digest"])
    object_entries = list(objects_root.iterdir())
    if any(not entry.is_file() for entry in object_entries) or {
        entry.name for entry in object_entries
    } != set(seen):
        raise ConformanceError("exported object set disagrees with the rootfs closure")
    if (
        rootfs.get("bytes") != len(copied["rootfs-index.json"])
        or rootfs.get("object_count") != len(objects)
        or rootfs.get("object_bytes") != sum(item["bytes"] for item in objects)
    ):
        raise ConformanceError("gateway manifest object summary disagrees with the rootfs closure")

    files = {
        name: {"bytes": len(data), "sha256": sha256_digest(data)} for name, data in sorted(copied.items())
    }
    return {
        "files": files,
        "gateway_manifest_digest": gateway_manifest_digest,
        "native_image_digest": native_image_digest,
        "objects": objects,
        "platform": f"linux/{arch}",
        "rootfs_index_digest": rootfs_index_digest,
        "selected_source_manifest_digest": selected_source_manifest,
    }


def actual_worker() -> str:
    machine = platform.machine().lower()
    arch = {"aarch64": "arm64", "arm64": "arm64", "amd64": "amd64", "x86_64": "amd64"}.get(machine)
    if arch is None:
        raise ConformanceError(f"unsupported worker architecture: {machine}")
    os_name = platform.system().lower()
    return f"{os_name}/{arch}"


def compare_directories(actual: pathlib.Path, expected: pathlib.Path) -> None:
    actual_files = {path.relative_to(actual) for path in actual.rglob("*") if path.is_file()}
    expected_files = {path.relative_to(expected) for path in expected.rglob("*") if path.is_file()}
    if actual_files != expected_files:
        missing = sorted(str(path) for path in expected_files - actual_files)
        extra = sorted(str(path) for path in actual_files - expected_files)
        raise ConformanceError(f"fixture file set differs; missing={missing}, extra={extra}")
    for relative in sorted(actual_files):
        actual_bytes = read_bounded(actual / relative)
        expected_bytes = read_bounded(expected / relative)
        if actual_bytes != expected_bytes:
            raise ConformanceError(
                f"fixture differs: {relative} "
                f"(actual {sha256_digest(actual_bytes)}, expected {sha256_digest(expected_bytes)})"
            )


def produce(args: argparse.Namespace) -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    spore_bin = pathlib.Path(args.spore_bin).resolve()
    output = pathlib.Path(args.output).resolve()
    if output.exists():
        raise ConformanceError(f"output already exists: {output}")
    if not spore_bin.is_file():
        raise ConformanceError(f"spore binary does not exist: {spore_bin}")
    worker = actual_worker()
    if args.worker and args.worker != worker:
        raise ConformanceError(f"worker mismatch: requested {args.worker}, running on {worker}")

    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="image-gateway-worker-conformance.") as temporary:
        work = pathlib.Path(temporary)
        input_details = build_oci_layout(work / "oci-layout")
        source = f"registry.example.invalid/sporevm/worker-conformance@{input_details['index_digest']}"
        target_results = []
        conversion_contract = None
        for arch in TARGETS:
            cache = work / f"cache-{arch}"
            gateway = work / f"gateway-{arch}"
            env = os.environ.copy()
            for name in list(env):
                if name.startswith("SPOREVM_"):
                    del env[name]
            env["SPOREVM_EXT4_WRITER"] = "native"
            env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache)
            imported = run(
                [
                    str(spore_bin),
                    "rootfs",
                    "import-oci",
                    str(work / "oci-layout"),
                    "--ref",
                    f"local/gateway-worker-conformance:{arch}",
                    "--platform",
                    f"linux/{arch}",
                ],
                env=env,
                cwd=repo_root,
            )
            metadata = output_value(imported, "metadata")
            metadata_value = parse_object(read_bounded(pathlib.Path(metadata)), pathlib.Path(metadata))
            target_contract = {
                "ext4_writer": metadata_value.get("ext4_writer"),
                "rootfs_builder": metadata_value.get("builder_version"),
            }
            if target_contract["ext4_writer"] != "native" or not isinstance(
                target_contract["rootfs_builder"], str
            ):
                raise ConformanceError("import metadata does not name the native conversion contract")
            if conversion_contract is None:
                conversion_contract = target_contract
            elif conversion_contract != target_contract:
                raise ConformanceError("target imports used different conversion contracts")
            if metadata_value.get("image_manifest_digest") != input_details["manifests"][arch]:
                raise ConformanceError(f"import metadata selected the wrong OCI manifest for linux/{arch}")
            run(
                [
                    str(spore_bin),
                    "image",
                    "export-fixture",
                    source,
                    "--repository",
                    "worker-conformance",
                    "--metadata",
                    metadata,
                    "--out",
                    str(gateway),
                ],
                env=env,
                cwd=repo_root,
            )
            target_results.append(
                normalize_target(output, arch, gateway, input_details["manifests"][arch])
            )

    if target_results[0]["native_image_digest"] == target_results[1]["native_image_digest"]:
        raise ConformanceError("arm64 and amd64 targets unexpectedly have the same native image digest")
    bundle = {
        "input": {
            "conversion_contract": conversion_contract,
            "index_digest": input_details["index_digest"],
            "layer": {"bytes": 1024, "digest": input_details["layer_digest"], "kind": "empty-ustar-v1"},
        },
        "schema": SCHEMA,
        "targets": target_results,
    }
    write_bytes(output / "bundle.json", canonical_json(bundle))
    if args.expected:
        compare_directories(output, pathlib.Path(args.expected).resolve())
    print(f"image-gateway worker conformance passed on {worker}: {output}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="image-gateway-worker-conformance-self-test.") as temporary:
        root = pathlib.Path(temporary)
        expected = root / "expected"
        actual = root / "actual"
        write_bytes(expected / "bundle.json", b"expected\n")
        write_bytes(actual / "bundle.json", b"expected\n")
        compare_directories(actual, expected)
        write_bytes(actual / "bundle.json", b"changed\n")
        try:
            compare_directories(actual, expected)
        except ConformanceError:
            pass
        else:
            raise ConformanceError("self-test accepted changed fixture bytes")
        for value in ("blake3:ABC", "sha256:" + "0" * 63, "md5:" + "0" * 64):
            try:
                require_digest(value, "sha256:", "test digest")
            except ConformanceError:
                pass
            else:
                raise ConformanceError(f"self-test accepted malformed digest: {value}")
        index = {"chunk_size": 64, "logical_size": 65}
        if expected_chunk_size(index, 0) != 64 or expected_chunk_size(index, 1) != 1:
            raise ConformanceError("self-test computed the wrong rootfs tail chunk size")
        try:
            expected_chunk_size(index, 2)
        except ConformanceError:
            pass
        else:
            raise ConformanceError("self-test accepted a rootfs chunk outside logical size")
    print("image-gateway worker conformance self-test ok")


def check(args: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory(prefix="image-gateway-worker-conformance-check.") as temporary:
        produce(
            argparse.Namespace(
                expected=args.expected,
                output=str(pathlib.Path(temporary) / "actual"),
                spore_bin=args.spore_bin,
                worker=args.worker,
            )
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    produce_parser = subparsers.add_parser("produce")
    produce_parser.add_argument("--spore-bin", required=True)
    produce_parser.add_argument("--output", required=True)
    produce_parser.add_argument("--expected")
    produce_parser.add_argument("--worker")
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--spore-bin", required=True)
    check_parser.add_argument("--expected", required=True)
    check_parser.add_argument("--worker")
    subparsers.add_parser("self-test")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "produce":
            produce(args)
        elif args.command == "check":
            check(args)
        else:
            self_test()
    except (ConformanceError, OSError) as error:
        print(f"image-gateway-worker-conformance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
