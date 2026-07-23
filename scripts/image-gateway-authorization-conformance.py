#!/usr/bin/env python3
"""Validate the repository-bound image-gateway object-read contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from typing import Any, Optional, Tuple


KIND = "spore-image-gateway-object-authorization-conformance-v1"
MAX_FIXTURE_BYTES = 64 * 1024


class ConformanceError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, separators=(",", ": ")) + "\n").encode()


def object_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ConformanceError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def read_contract(path: pathlib.Path) -> dict[str, Any]:
    data = path.read_bytes()
    if not data or len(data) > MAX_FIXTURE_BYTES:
        raise ConformanceError(f"fixture must contain 1..{MAX_FIXTURE_BYTES} bytes")
    try:
        value = json.loads(data, object_pairs_hook=object_no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConformanceError(f"invalid JSON: {error}") from error
    if not isinstance(value, dict) or canonical_json(value) != data:
        raise ConformanceError("fixture is not canonical JSON")
    return value


def exact_fields(value: Any, fields: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ConformanceError(f"{context} has unexpected fields")
    return value


def require_digest(value: Any, prefix: str, context: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != len(prefix) + 64
        or not value.startswith(prefix)
        or any(char not in "0123456789abcdef" for char in value[len(prefix) :])
    ):
        raise ConformanceError(f"{context} is not a canonical {prefix} digest")
    return value


def read_fixture_json(repo_root: pathlib.Path, relative: str) -> tuple[bytes, dict[str, Any]]:
    path = repo_root / relative
    try:
        path.resolve().relative_to(repo_root.resolve())
    except ValueError as error:
        raise ConformanceError(f"fixture path escapes the repository: {relative}") from error
    data = path.read_bytes().removesuffix(b"\n")
    try:
        value = json.loads(data, object_pairs_hook=object_no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConformanceError(f"invalid fixture JSON in {relative}: {error}") from error
    if not isinstance(value, dict):
        raise ConformanceError(f"fixture must contain an object: {relative}")
    return data, value


def closure_from_fixtures(
    repo_root: pathlib.Path,
    manifest_fixture: str,
    index_fixture: str,
) -> tuple[str, str, list[dict[str, Any]]]:
    manifest_bytes, manifest = read_fixture_json(repo_root, manifest_fixture)
    _, index = read_fixture_json(repo_root, index_fixture)
    rootfs = manifest.get("rootfs_index")
    storage = manifest.get("image", {}).get("rootfs_storage")
    chunks = index.get("chunks")
    logical_size = index.get("logical_size")
    chunk_size = index.get("chunk_size")
    if (
        not isinstance(rootfs, dict)
        or not isinstance(storage, dict)
        or not isinstance(chunks, list)
        or type(logical_size) is not int
        or type(chunk_size) is not int
        or logical_size <= 0
        or chunk_size != 64 * 1024
    ):
        raise ConformanceError("authorization fixtures have invalid rootfs geometry")
    rootfs_digest = require_digest(rootfs.get("digest"), "blake3:", "fixture rootfs digest")
    if storage.get("index_digest") != rootfs_digest:
        raise ConformanceError("authorization fixture manifest has inconsistent rootfs digests")
    objects: dict[str, int] = {}
    for chunk in chunks:
        if not isinstance(chunk, dict) or set(chunk) != {"digest", "logical_chunk"}:
            raise ConformanceError("authorization fixture index has a malformed chunk")
        digest = require_digest(chunk["digest"], "blake3:", "fixture object digest")
        logical_chunk = chunk["logical_chunk"]
        if type(logical_chunk) is not int or logical_chunk < 0:
            raise ConformanceError("authorization fixture index has an invalid logical chunk")
        offset = logical_chunk * chunk_size
        if offset >= logical_size:
            raise ConformanceError("authorization fixture chunk lies outside logical size")
        byte_count = min(chunk_size, logical_size - offset)
        if digest in objects and objects[digest] != byte_count:
            raise ConformanceError("authorization fixture reuses an object at two lengths")
        objects[digest] = byte_count
    descriptors = [{"bytes": size, "digest": digest} for digest, size in sorted(objects.items())]
    if rootfs.get("object_count") != len(descriptors) or rootfs.get("object_bytes") != sum(
        descriptor["bytes"] for descriptor in descriptors
    ):
        raise ConformanceError("authorization fixture manifest summary disagrees with its index")
    manifest_digest = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
    return manifest_digest, rootfs_digest, descriptors


def route(path: str) -> Optional[Tuple[str, str, str]]:
    prefix = "/v1/repositories/"
    if (
        not path.startswith(prefix)
        or any(char in path for char in "?%#")
        or ".." in path
    ):
        return None
    repository, separator, remainder = path[len(prefix) :].partition("/manifests/")
    if not separator or not repository:
        return None
    manifest, separator, object_digest = remainder.partition("/objects/")
    if not separator or not manifest or not object_digest or "/" in object_digest:
        return None
    return repository, manifest, object_digest


def decision(
    repositories: list[dict[str, Any]],
    *,
    authenticated: bool,
    principal: str,
    method: str,
    path: str,
) -> Tuple[int, Optional[dict[str, Any]]]:
    if not authenticated:
        return 401, None
    parsed = route(path) if method == "GET" else None
    if parsed is None:
        return 404, None
    repository_name, manifest_digest, object_digest = parsed
    for repository in repositories:
        if repository["name"] != repository_name or principal not in repository["readers"]:
            continue
        for manifest in repository["manifests"]:
            if manifest["digest"] != manifest_digest:
                continue
            for descriptor in manifest["objects"]:
                if descriptor["digest"] == object_digest:
                    return 200, descriptor
    return 404, None


def validate_contract(value: dict[str, Any], repo_root: pathlib.Path) -> None:
    exact_fields(value, {"cases", "kind", "repositories"}, "contract")
    if value["kind"] != KIND:
        raise ConformanceError("unsupported fixture kind")
    repositories = value["repositories"]
    cases = value["cases"]
    if not isinstance(repositories, list) or not repositories:
        raise ConformanceError("fixture must contain repositories")
    if not isinstance(cases, list) or not cases:
        raise ConformanceError("fixture must contain cases")

    repository_names: set[str] = set()
    physical_objects: dict[str, int] = {}
    successful_repositories: dict[str, set[str]] = {}
    for repository_value in repositories:
        repository = exact_fields(repository_value, {"manifests", "name", "readers"}, "repository")
        name = repository["name"]
        readers = repository["readers"]
        manifests = repository["manifests"]
        if not isinstance(name, str) or not name or name in repository_names:
            raise ConformanceError("repository names must be unique and nonempty")
        if not isinstance(readers, list) or not readers or readers != sorted(set(readers)):
            raise ConformanceError(f"repository {name} readers must be sorted and unique")
        if not all(isinstance(reader, str) and reader for reader in readers):
            raise ConformanceError(f"repository {name} has an invalid reader")
        if not isinstance(manifests, list) or not manifests:
            raise ConformanceError(f"repository {name} must contain manifests")
        repository_names.add(name)
        manifest_digests: set[str] = set()
        for manifest_value in manifests:
            manifest = exact_fields(
                manifest_value,
                {"digest", "manifest_fixture", "objects", "rootfs_index_digest", "rootfs_index_fixture"},
                "manifest",
            )
            digest = require_digest(manifest["digest"], "sha256:", "manifest digest")
            require_digest(manifest["rootfs_index_digest"], "blake3:", "rootfs index digest")
            if not isinstance(manifest["manifest_fixture"], str) or not isinstance(
                manifest["rootfs_index_fixture"], str
            ):
                raise ConformanceError("manifest fixture paths must be strings")
            objects = manifest["objects"]
            if digest in manifest_digests or not isinstance(objects, list) or not objects:
                raise ConformanceError(f"repository {name} has a duplicate or empty manifest")
            manifest_digests.add(digest)
            object_digests: list[str] = []
            for descriptor_value in objects:
                descriptor = exact_fields(descriptor_value, {"bytes", "digest"}, "object")
                object_digest = require_digest(descriptor["digest"], "blake3:", "object digest")
                byte_count = descriptor["bytes"]
                if type(byte_count) is not int or byte_count <= 0 or byte_count > 64 * 1024:
                    raise ConformanceError("object byte count is outside the v1 chunk bound")
                if object_digest in physical_objects and physical_objects[object_digest] != byte_count:
                    raise ConformanceError("one physical object has inconsistent lengths")
                physical_objects[object_digest] = byte_count
                object_digests.append(object_digest)
            if object_digests != sorted(set(object_digests)):
                raise ConformanceError("manifest objects must be sorted and unique")
            expected = closure_from_fixtures(
                repo_root,
                manifest["manifest_fixture"],
                manifest["rootfs_index_fixture"],
            )
            if (digest, manifest["rootfs_index_digest"], objects) != expected:
                raise ConformanceError("authorization closure disagrees with its canonical fixtures")
    if [repository["name"] for repository in repositories] != sorted(repository_names):
        raise ConformanceError("repositories must be sorted by name")

    case_names: set[str] = set()
    observed_statuses: set[int] = set()
    for case_value in cases:
        case = exact_fields(
            case_value,
            {"authenticated", "method", "name", "path", "principal", "response", "status"},
            "case",
        )
        name = case["name"]
        if not isinstance(name, str) or not name or name in case_names:
            raise ConformanceError("case names must be unique and nonempty")
        case_names.add(name)
        if type(case["authenticated"]) is not bool or not isinstance(case["principal"], str):
            raise ConformanceError(f"case {name} has invalid authentication fields")
        if not isinstance(case["method"], str) or not isinstance(case["path"], str):
            raise ConformanceError(f"case {name} has invalid request fields")
        if case["status"] not in (200, 401, 404):
            raise ConformanceError(f"case {name} has an unsupported status")
        status, response = decision(
            repositories,
            authenticated=case["authenticated"],
            principal=case["principal"],
            method=case["method"],
            path=case["path"],
        )
        if status != case["status"] or response != case["response"]:
            raise ConformanceError(f"case {name} disagrees with the authorization contract")
        observed_statuses.add(status)
        if status == 200:
            parsed = route(case["path"])
            if parsed is None or response is None:
                raise ConformanceError(f"case {name} returned an invalid success response")
            successful_repositories.setdefault(response["digest"], set()).add(parsed[0])

    if [case["name"] for case in cases] != sorted(case_names):
        raise ConformanceError("cases must be sorted by name")
    if observed_statuses != {200, 401, 404}:
        raise ConformanceError("fixture must cover success, unauthenticated, and non-disclosing denial")
    if not any(len(names) > 1 for names in successful_repositories.values()):
        raise ConformanceError("fixture must expose one shared physical object through two authorized repositories")


def self_test() -> None:
    repositories = [{
        "name": "team/a",
        "readers": ["reader-a"],
        "manifests": [{
            "digest": "sha256:" + "a" * 64,
            "manifest_fixture": "unused",
            "rootfs_index_digest": "blake3:" + "b" * 64,
            "rootfs_index_fixture": "unused",
            "objects": [{"bytes": 1, "digest": "blake3:" + "c" * 64}],
        }],
    }]
    path = "/v1/repositories/team/a/manifests/sha256:" + "a" * 64 + "/objects/blake3:" + "c" * 64
    assert decision(repositories, authenticated=True, principal="reader-a", method="GET", path=path)[0] == 200
    assert decision(repositories, authenticated=False, principal="", method="GET", path=path)[0] == 401
    assert decision(repositories, authenticated=True, principal="reader-b", method="GET", path=path)[0] == 404
    assert decision(repositories, authenticated=True, principal="reader-a", method="HEAD", path=path)[0] == 404
    print("image-gateway authorization conformance self-test ok")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", nargs="?", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            if args.fixture is None:
                parser.error("fixture is required unless --self-test is used")
            repo_root = pathlib.Path(__file__).resolve().parent.parent
            validate_contract(read_contract(args.fixture), repo_root)
            print(f"image-gateway authorization conformance ok: {args.fixture}")
    except (ConformanceError, OSError) as error:
        print(f"image-gateway-authorization-conformance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
