#!/usr/bin/env python3
"""Measure image-gateway object transport without adding a product protocol."""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import errno
import gzip
import hashlib
import hmac
import http.client
import io
import json
import os
import platform as host_platform
from pathlib import Path
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tarfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import quote, unquote, urlparse


SCHEMA = "spore-image-gateway-transport-benchmark-v1"
BATCH_MAGIC = b"spore-bench-batch-v1\n"
MAX_BATCH_OBJECTS = 1024
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_CHUNK_BYTES = 64 * 1024
CONTROL_NAMES = ("index", "manifest", "config", "rootfs-index")
PROFILE_RE = re.compile(r"spore rootfs profile: phase=(?P<phase>\S+)(?P<tail>.*)")
PROFILE_FIELD_RE = re.compile(r"(?P<name>[a-z0-9_]+)=(?P<value>\d+)")
METADATA_RE = re.compile(r"^(?:  Metadata|metadata): (?P<path>.+)$", re.MULTILINE)


class BenchmarkError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def command_output(argv: list[str], cwd: Path) -> str | None:
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout.strip()


def provenance() -> dict[str, Any]:
    repo = Path(__file__).resolve().parents[2]
    status = command_output(["git", "status", "--porcelain"], repo)
    return {
        "host": {
            "machine": host_platform.machine(),
            "release": host_platform.release(),
            "system": host_platform.system(),
        },
        "repo_head": command_output(["git", "rev-parse", "HEAD"], repo),
        "repo_dirty": None if status is None else bool(status),
    }


def file_descriptor(path: Path, relative_to: Path) -> dict[str, Any]:
    data = read_bounded(path)
    return {
        "path": str(path.relative_to(relative_to)),
        "bytes": len(data),
        "sha256": sha256(data),
    }


def parse_profile(path: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PROFILE_RE.fullmatch(line)
        if match is None:
            continue
        phase = match.group("phase")
        fields = {
            field.group("name"): int(field.group("value"))
            for field in PROFILE_FIELD_RE.finditer(match.group("tail"))
        }
        if "ms" not in fields:
            continue
        count_key = f"{phase}_count"
        result[count_key] = result.get(count_key, 0) + 1
        for name, value in fields.items():
            if name == "layer":
                continue
            key = f"{phase}_{name}"
            result[key] = result.get(key, 0) + value
    return result


def median_profiles(rows: list[dict[str, Any]]) -> tuple[dict[str, float], dict[str, int]]:
    names = sorted({name for row in rows for name in row["profile"]})
    return (
        {
            name: statistics.median(
                row["profile"][name] for row in rows if name in row["profile"]
            )
            for name in names
        },
        {name: sum(name in row["profile"] for row in rows) for name in names},
    )


def read_bounded(path: Path) -> bytes:
    size = path.stat().st_size
    if size > MAX_FILE_BYTES:
        raise BenchmarkError(f"file exceeds {MAX_FILE_BYTES} bytes: {path}")
    return path.read_bytes()


def parse_object(data: bytes, source: Path) -> dict[str, Any]:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BenchmarkError(f"invalid JSON in {source}: {error}") from error
    if not isinstance(value, dict):
        raise BenchmarkError(f"expected JSON object in {source}")
    return value


def only_named(root: Path, name: str) -> Path:
    matches = sorted(path for path in root.rglob(name) if path.is_file())
    if len(matches) != 1:
        raise BenchmarkError(f"expected exactly one {name!r} below {root}, found {len(matches)}")
    return matches[0]


@dataclasses.dataclass(frozen=True)
class ObjectInfo:
    digest: str
    path: Path
    size: int
    transport_digest: str


@dataclasses.dataclass(frozen=True)
class Closure:
    root: Path
    controls: dict[str, bytes]
    objects: dict[str, ObjectInfo]
    platform: str
    image_digest: str
    rootfs_index_digest: str
    logical_size: int
    source: str | None

    @classmethod
    def load(cls, root: Path) -> "Closure":
        root = root.resolve()
        if not root.is_dir():
            raise BenchmarkError(f"fixture directory does not exist: {root}")
        paths = {name: only_named(root, name) for name in CONTROL_NAMES}
        controls = {str(path.relative_to(root)): read_bounded(path) for path in paths.values()}
        manifest = parse_object(read_bounded(paths["manifest"]), paths["manifest"])
        rootfs_index = parse_object(read_bounded(paths["rootfs-index"]), paths["rootfs-index"])
        image = manifest.get("image")
        descriptor = manifest.get("rootfs_index")
        if not isinstance(image, dict) or not isinstance(descriptor, dict):
            raise BenchmarkError("fixture manifest is missing image or rootfs_index")
        platform = image.get("platform")
        storage = image.get("rootfs_storage")
        if not isinstance(platform, dict) or not isinstance(storage, dict):
            raise BenchmarkError("fixture manifest is missing platform or rootfs storage")
        os_name = platform.get("os")
        arch = platform.get("arch")
        logical_size = rootfs_index.get("logical_size")
        chunk_size = rootfs_index.get("chunk_size")
        chunks = rootfs_index.get("chunks")
        if (
            os_name != "linux"
            or arch not in ("arm64", "amd64")
            or type(logical_size) is not int
            or type(chunk_size) is not int
            or logical_size <= 0
            or chunk_size <= 0
            or chunk_size > MAX_CHUNK_BYTES
            or not isinstance(chunks, list)
        ):
            raise BenchmarkError("fixture rootfs geometry or platform is invalid")

        object_root = paths["manifest"].parent / "objects"
        objects: dict[str, ObjectInfo] = {}
        logical_chunks: set[int] = set()
        for chunk in chunks:
            if not isinstance(chunk, dict) or set(chunk) != {"digest", "logical_chunk"}:
                raise BenchmarkError("fixture rootfs index contains a malformed chunk")
            digest = chunk["digest"]
            logical_chunk = chunk["logical_chunk"]
            if (
                not isinstance(digest, str)
                or not digest.startswith("blake3:")
                or len(digest) != 71
                or any(byte not in "0123456789abcdef" for byte in digest[7:])
                or type(logical_chunk) is not int
                or logical_chunk < 0
                or logical_chunk in logical_chunks
            ):
                raise BenchmarkError("fixture rootfs index contains invalid chunk fields")
            logical_chunks.add(logical_chunk)
            offset = logical_chunk * chunk_size
            if offset >= logical_size:
                raise BenchmarkError("fixture rootfs chunk lies outside logical size")
            size = min(chunk_size, logical_size - offset)
            if digest in objects:
                if objects[digest].size != size:
                    raise BenchmarkError(f"object {digest} is referenced with inconsistent sizes")
                continue
            path = object_root / digest
            data = read_bounded(path)
            if len(data) != size:
                raise BenchmarkError(f"fixture object {digest} has the wrong size")
            objects[digest] = ObjectInfo(digest, path, size, sha256(data))

        entries = list(object_root.iterdir())
        if any(not entry.is_file() for entry in entries) or {entry.name for entry in entries} != set(objects):
            raise BenchmarkError("fixture object directory disagrees with the rootfs closure")
        if descriptor.get("object_count") != len(objects) or descriptor.get("object_bytes") != sum(
            item.size for item in objects.values()
        ):
            raise BenchmarkError("fixture manifest object summary disagrees with the closure")
        image_digest = image.get("digest")
        rootfs_digest = descriptor.get("digest")
        if not isinstance(image_digest, str) or not isinstance(rootfs_digest, str):
            raise BenchmarkError("fixture manifest is missing immutable identities")
        source_value = manifest.get("source")
        source = source_value.get("requested_ref") if isinstance(source_value, dict) else None
        return cls(
            root=root,
            controls=controls,
            objects=objects,
            platform=f"linux/{arch}",
            image_digest=image_digest,
            rootfs_index_digest=rootfs_digest,
            logical_size=logical_size,
            source=source if isinstance(source, str) else None,
        )


class ObjectBackend:
    kind = "local"

    def read(self, relative: str, expected_size: int) -> bytes:
        size, stream = self.open(relative, expected_size)
        try:
            data = stream.read(expected_size + 1)
        finally:
            stream.close()
        if size != expected_size or len(data) != expected_size:
            raise BenchmarkError(f"backend object has the wrong size: {relative}")
        return data

    def open(self, relative: str, expected_size: int) -> tuple[int, Any]:
        raise NotImplementedError

    def close(self) -> None:
        return

    def retry_count(self) -> int:
        return 0


class LocalObjectBackend(ObjectBackend):
    def __init__(self, closure: Closure, archive: Path):
        self.closure = closure
        self.archive = archive

    def path(self, relative: str) -> Path:
        if relative == "archive":
            return self.archive
        if relative.startswith("controls/"):
            control = relative.removeprefix("controls/")
            if control not in self.closure.controls:
                raise BenchmarkError(f"unknown control object: {control}")
            return self.closure.root / control
        if relative.startswith("objects/"):
            digest = relative.removeprefix("objects/")
            info = self.closure.objects.get(digest)
            if info is None:
                raise BenchmarkError(f"unknown data object: {digest}")
            return info.path
        raise BenchmarkError(f"unknown backend object: {relative}")

    def open(self, relative: str, expected_size: int) -> tuple[int, Any]:
        path = self.path(relative)
        size = path.stat().st_size
        if size != expected_size:
            raise BenchmarkError(f"backend object has the wrong size: {relative}")
        return size, path.open("rb")


def signing_key(secret: str, date: str, region: str) -> bytes:
    date_key = hmac.new(("AWS4" + secret).encode(), date.encode(), hashlib.sha256).digest()
    region_key = hmac.new(date_key, region.encode(), hashlib.sha256).digest()
    service_key = hmac.new(region_key, b"s3", hashlib.sha256).digest()
    return hmac.new(service_key, b"aws4_request", hashlib.sha256).digest()


def aws_credentials() -> tuple[str, str, str | None]:
    access = os.environ.get("AWS_ACCESS_KEY_ID")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY")
    token = os.environ.get("AWS_SESSION_TOKEN")
    if access and secret:
        return access, secret, token
    try:
        completed = subprocess.run(
            ["aws", "configure", "export-credentials", "--format", "process"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        )
        value = json.loads(completed.stdout)
        return value["AccessKeyId"], value["SecretAccessKey"], value.get("SessionToken")
    except (OSError, KeyError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        raise BenchmarkError("S3 backend could not load AWS credentials") from error


class S3ObjectBackend(ObjectBackend):
    kind = "s3"

    def __init__(self, uri: str, region: str):
        parsed = urlparse(uri)
        if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.strip("/"):
            raise BenchmarkError("--s3-uri must be s3://bucket/nonempty-prefix")
        self.bucket = parsed.netloc
        self.prefix = parsed.path.strip("/")
        self.region = region
        self.access, self.secret, self.token = aws_credentials()
        self.host = f"{self.bucket}.s3.{region}.amazonaws.com"
        self.local = threading.local()
        self.connections: list[http.client.HTTPSConnection] = []
        self.connections_lock = threading.Lock()
        self.retries = 0
        self.retries_lock = threading.Lock()

    def record_retry(self) -> None:
        with self.retries_lock:
            self.retries += 1

    def retry_count(self) -> int:
        with self.retries_lock:
            return self.retries

    def connection(self) -> http.client.HTTPSConnection:
        connection = getattr(self.local, "connection", None)
        if connection is None:
            connection = http.client.HTTPSConnection(self.host, timeout=60)
            self.local.connection = connection
            with self.connections_lock:
                self.connections.append(connection)
        return connection

    def reset_connection(self) -> None:
        connection = getattr(self.local, "connection", None)
        if connection is not None:
            connection.close()
            self.local.connection = None

    def signed_headers(self, path: str) -> dict[str, str]:
        now = datetime.now(timezone.utc)
        timestamp = now.strftime("%Y%m%dT%H%M%SZ")
        date = now.strftime("%Y%m%d")
        payload_hash = hashlib.sha256(b"").hexdigest()
        headers = {
            "host": self.host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": timestamp,
        }
        if self.token:
            headers["x-amz-security-token"] = self.token
        signed_names = ";".join(sorted(headers))
        canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in sorted(headers))
        canonical_request = "\n".join(
            ["GET", path, "", canonical_headers, signed_names, payload_hash]
        )
        scope = f"{date}/{self.region}/s3/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                timestamp,
                scope,
                hashlib.sha256(canonical_request.encode()).hexdigest(),
            ]
        )
        signature = hmac.new(
            signing_key(self.secret, date, self.region),
            string_to_sign.encode(),
            hashlib.sha256,
        ).hexdigest()
        headers["authorization"] = (
            f"AWS4-HMAC-SHA256 Credential={self.access}/{scope},"
            f"SignedHeaders={signed_names},Signature={signature}"
        )
        return headers

    def open(self, relative: str, expected_size: int) -> tuple[int, Any]:
        key = f"{self.prefix}/{relative}"
        path = "/" + quote(key, safe="/-_.~")
        response = None
        for attempt in range(3):
            try:
                connection = self.connection()
                connection.request("GET", path, headers=self.signed_headers(path))
                response = connection.getresponse()
            except (OSError, http.client.HTTPException):
                self.reset_connection()
                if attempt == 2:
                    raise
                self.record_retry()
                time.sleep(0.25 * (2**attempt))
                continue
            if response.status not in (429, 500, 502, 503, 504) or attempt == 2:
                break
            response.read()
            response.close()
            self.reset_connection()
            self.record_retry()
            time.sleep(0.25 * (2**attempt))
        assert response is not None
        if response.status != 200:
            body = response.read(4096).decode("utf-8", errors="replace")
            response.close()
            raise BenchmarkError(f"S3 backend returned HTTP {response.status} for {relative}: {body}")
        try:
            size = int(response.getheader("Content-Length", "-1"))
        except ValueError as error:
            response.close()
            raise BenchmarkError(f"S3 backend omitted a valid length for {relative}") from error
        if size != expected_size:
            response.close()
            raise BenchmarkError(f"S3 backend object has the wrong size: {relative}")
        return size, response

    def close(self) -> None:
        with self.connections_lock:
            for connection in self.connections:
                connection.close()
            self.connections.clear()


def stage_backend(closure: Closure, archive: Path, destination: Path) -> None:
    controls = destination / "controls"
    objects = destination / "objects"
    controls.mkdir(parents=True)
    objects.mkdir()
    for relative, data in closure.controls.items():
        target = controls / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    for digest, info in closure.objects.items():
        target = objects / digest
        try:
            os.link(info.path, target)
        except OSError as error:
            if error.errno != errno.EXDEV:
                raise
            shutil.copyfile(info.path, target)
    try:
        os.link(archive, destination / "archive")
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
        shutil.copyfile(archive, destination / "archive")


def upload_backend(source: Path, uri: str) -> None:
    completed = subprocess.run(
        ["aws", "s3", "sync", str(source), uri, "--only-show-errors", "--no-progress"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise BenchmarkError(f"failed to upload S3 benchmark backend: {completed.stderr.strip()}")


def write_archive(closure: Closure, path: Path, compression: str) -> None:
    if compression not in ("gzip", "none"):
        raise BenchmarkError(f"unsupported archive compression: {compression}")

    def write_tar(stream: Any) -> None:
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for digest, info in sorted(closure.objects.items()):
                member = tarfile.TarInfo(f"objects/{digest}")
                member.size = info.size
                member.mode = 0o444
                member.mtime = 0
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                with info.path.open("rb") as source:
                    archive.addfile(member, source)

    with path.open("wb") as output:
        if compression == "gzip":
            with gzip.GzipFile(
                filename="", mode="wb", fileobj=output, compresslevel=6, mtime=0
            ) as compressed:
                write_tar(compressed)
        else:
            write_tar(output)


@dataclasses.dataclass
class Counters:
    requests: int = 0
    request_bytes: int = 0
    backend_reads: int = 0
    backend_bytes: int = 0
    response_bytes: int = 0
    batch_composition_ns: int = 0

    def subtract(self, earlier: "Counters") -> "Counters":
        return Counters(
            **{
                field.name: getattr(self, field.name) - getattr(earlier, field.name)
                for field in dataclasses.fields(self)
            }
        )


class ServerState:
    def __init__(
        self, closure: Closure, archive: Path, backend: "ObjectBackend", concurrency: int
    ):
        self.closure = closure
        self.archive = archive
        self.backend = backend
        self.lock = threading.Lock()
        self.counters = Counters()
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=concurrency)

    def snapshot(self) -> Counters:
        with self.lock:
            return dataclasses.replace(self.counters)

    def record(
        self,
        *,
        reads: int,
        backend_bytes: int,
        response_bytes: int,
        request_bytes: int = 0,
        composition_ns: int = 0,
    ) -> None:
        with self.lock:
            self.counters.requests += 1
            self.counters.request_bytes += request_bytes
            self.counters.backend_reads += reads
            self.counters.backend_bytes += backend_bytes
            self.counters.response_bytes += response_bytes
            self.counters.batch_composition_ns += composition_ns


def encode_batch(
    closure: Closure,
    digests: list[str],
    backend: ObjectBackend | None = None,
    executor: concurrent.futures.Executor | None = None,
) -> bytes:
    output = io.BytesIO()
    output.write(BATCH_MAGIC)
    output.write(struct.pack(">I", len(digests)))
    def read_object(digest: str) -> bytes:
        info = closure.objects[digest]
        return (
            read_bounded(info.path)
            if backend is None
            else backend.read(f"objects/{digest}", info.size)
        )

    data_objects = (
        list(executor.map(read_object, digests))
        if executor is not None
        else [read_object(digest) for digest in digests]
    )
    for digest, data in zip(digests, data_objects, strict=True):
        encoded = digest.encode()
        output.write(struct.pack(">H", len(encoded)))
        output.write(encoded)
        output.write(struct.pack(">I", len(data)))
        output.write(data)
    return output.getvalue()


def decode_batch(data: bytes, expected: list[str]) -> dict[str, bytes]:
    stream = io.BytesIO(data)
    if stream.read(len(BATCH_MAGIC)) != BATCH_MAGIC:
        raise BenchmarkError("batch has the wrong benchmark framing")
    count_raw = stream.read(4)
    if len(count_raw) != 4 or struct.unpack(">I", count_raw)[0] != len(expected):
        raise BenchmarkError("batch object count disagrees with the request")
    result: dict[str, bytes] = {}
    for wanted in expected:
        digest_len_raw = stream.read(2)
        if len(digest_len_raw) != 2:
            raise BenchmarkError("batch is truncated before a digest")
        digest_len = struct.unpack(">H", digest_len_raw)[0]
        try:
            digest = stream.read(digest_len).decode("ascii", errors="strict")
        except UnicodeDecodeError as error:
            raise BenchmarkError("batch contains a non-ASCII digest") from error
        size_raw = stream.read(4)
        if len(size_raw) != 4:
            raise BenchmarkError("batch is truncated before an object length")
        declared_size = struct.unpack(">I", size_raw)[0]
        payload = stream.read(declared_size)
        if digest != wanted or len(payload) != declared_size or declared_size == 0 or digest in result:
            raise BenchmarkError("batch contains an unexpected, empty, or duplicate object")
        result[digest] = payload
    if stream.read(1):
        raise BenchmarkError("batch contains trailing bytes")
    return result


class BenchmarkHandler(BaseHTTPRequestHandler):
    server_version = "SporeGatewayBenchmark/1"
    protocol_version = "HTTP/1.1"

    @property
    def state(self) -> ServerState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_bytes(self, data: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_backend_file(self, relative: str, expected_size: int) -> None:
        size, stream = self.state.backend.open(relative, expected_size)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            shutil.copyfileobj(stream, self.wfile, length=1024 * 1024)
        finally:
            stream.close()

    def do_GET(self) -> None:
        if self.path == "/archive":
            size = self.state.archive.stat().st_size
            self.state.record(reads=1, backend_bytes=size, response_bytes=size)
            return self.send_backend_file("archive", size)
        if self.path.startswith("/control/"):
            relative = unquote(self.path.removeprefix("/control/"))
            expected = self.state.closure.controls.get(relative)
            if expected is None:
                return self.send_error(404)
            data = self.state.backend.read(f"controls/{relative}", len(expected))
            self.state.record(reads=1, backend_bytes=len(data), response_bytes=len(data))
            return self.send_bytes(data)
        if self.path.startswith("/objects/"):
            digest = unquote(self.path.removeprefix("/objects/"))
            info = self.state.closure.objects.get(digest)
            if info is None:
                return self.send_error(404)
            data = self.state.backend.read(f"objects/{digest}", info.size)
            self.state.record(reads=1, backend_bytes=len(data), response_bytes=len(data))
            return self.send_bytes(data)
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/batch":
            return self.send_error(404)
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            return self.send_error(400)
        if length < 0 or length > 128 * 1024:
            return self.send_error(400)
        try:
            request = json.loads(self.rfile.read(length))
            digests = request["digests"]
        except (KeyError, TypeError, json.JSONDecodeError):
            return self.send_error(400)
        if not isinstance(digests, list) or not digests or len(digests) > MAX_BATCH_OBJECTS:
            return self.send_error(404)
        if any(not isinstance(digest, str) or digest not in self.state.closure.objects for digest in digests):
            return self.send_error(404)
        if len(set(digests)) != len(digests):
            return self.send_error(404)
        started = time.perf_counter_ns()
        data = encode_batch(
            self.state.closure, digests, self.state.backend, self.state.executor
        )
        composition_ns = time.perf_counter_ns() - started
        object_bytes = sum(self.state.closure.objects[digest].size for digest in digests)
        self.state.record(
            reads=len(digests),
            backend_bytes=object_bytes,
            response_bytes=len(data),
            request_bytes=length,
            composition_ns=composition_ns,
        )
        self.send_bytes(data)


class TransportServer:
    def __init__(
        self, closure: Closure, archive: Path, backend: "ObjectBackend", concurrency: int
    ):
        self.state = ServerState(closure, archive, backend, concurrency)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), BenchmarkHandler)
        self.server.state = self.state  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "TransportServer":
        self.thread.start()
        return self

    def __exit__(self, *unused: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.state.executor.shutdown()
        self.state.backend.close()


class TransportClient:
    def __init__(self, server: TransportServer):
        self.connection = http.client.HTTPConnection("127.0.0.1", server.server.server_port, timeout=30)

    def close(self) -> None:
        self.connection.close()

    def bytes(self, path: str, *, body: bytes | None = None) -> bytes:
        headers = {"Content-Type": "application/json"} if body is not None else {}
        self.connection.request("POST" if body is not None else "GET", path, body=body, headers=headers)
        response = self.connection.getresponse()
        data = response.read()
        if response.status != 200:
            raise BenchmarkError(f"benchmark server returned HTTP {response.status}")
        return data

    def file(self, path: str, destination: Path) -> None:
        self.connection.request("GET", path)
        response = self.connection.getresponse()
        if response.status != 200:
            response.read()
            raise BenchmarkError(f"benchmark server returned HTTP {response.status}")
        with destination.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)


def verify_object(info: ObjectInfo, data: bytes) -> None:
    if len(data) != info.size or sha256(data) != info.transport_digest:
        raise BenchmarkError(f"transport changed object bytes for {info.digest}")


def extract_archive(
    closure: Closure, path: Path, stage: Path, compression: str
) -> dict[str, Path]:
    result: dict[str, Path] = {}
    mode = "r:gz" if compression == "gzip" else "r:"
    with tarfile.open(path, mode=mode) as archive:
        for member in archive:
            if not member.isfile() or not member.name.startswith("objects/"):
                raise BenchmarkError("archive contains a non-object entry")
            digest = member.name.removeprefix("objects/")
            extracted = archive.extractfile(member)
            if (
                extracted is None
                or digest not in closure.objects
                or digest in result
                or member.size != closure.objects[digest].size
            ):
                raise BenchmarkError("archive contains a duplicate or unreadable object")
            destination = stage / digest
            with destination.open("wb") as output:
                shutil.copyfileobj(extracted, output, length=1024 * 1024)
            if destination.stat().st_size != member.size:
                raise BenchmarkError("archive object length disagrees with its header")
            result[digest] = destination
    return result


def prefill_digests(closure: Closure, overlap: Closure | None) -> tuple[list[str], str]:
    ordered = sorted(closure.objects)
    if overlap is not None:
        return [digest for digest in ordered if digest in overlap.objects], "overlap-fixture"
    if len(ordered) <= 1:
        return [], "synthetic-half"
    return ordered[: max(1, len(ordered) // 2)], "synthetic-half"


def run_trial(
    server: TransportServer,
    closure: Closure,
    mode: str,
    cache_state: str,
    iteration: int,
    output: Path,
    compression: str,
    overlap: Closure | None,
    batch_size: int,
    concurrency: int,
    trial_order: int,
) -> dict[str, Any]:
    cache = output / "work" / f"{mode}-{cache_state}-{iteration}"
    cache.mkdir(parents=True)
    reused, reuse_source = prefill_digests(closure, overlap) if cache_state == "partial" else ([], "empty")
    for digest in reused:
        shutil.copyfile(closure.objects[digest].path, cache / digest)
    missing = [digest for digest in sorted(closure.objects) if digest not in reused]
    stage = cache / "stage"
    stage.mkdir()
    before = server.state.snapshot()
    retries_before = server.state.backend.retry_count()
    started = time.perf_counter_ns()
    client = TransportClient(server)
    try:
        control_started = time.perf_counter_ns()
        control_bytes = 0
        for relative, expected in sorted(closure.controls.items()):
            data = client.bytes(f"/control/{quote(relative, safe='')}")
            if data != expected:
                raise BenchmarkError(f"control file changed in transport: {relative}")
            control_bytes += len(data)
        control_ns = time.perf_counter_ns() - control_started

        transfer_started = time.perf_counter_ns()
        received_paths: dict[str, Path] = {}
        if mode == "archive":
            archive_path = cache / "transport.archive"
            client.file("/archive", archive_path)
            received_paths = extract_archive(closure, archive_path, stage, compression)
            archive_path.unlink()
        elif mode == "batch":
            for offset in range(0, len(missing), batch_size):
                requested = missing[offset : offset + batch_size]
                body = json.dumps({"digests": requested}, separators=(",", ":")).encode()
                decoded = decode_batch(client.bytes("/batch", body=body), requested)
                for digest, data in decoded.items():
                    path = stage / digest
                    path.write_bytes(data)
                    received_paths[digest] = path
        elif mode == "objects":
            def fetch_object(digest: str) -> tuple[str, Path]:
                path = stage / digest
                object_client = TransportClient(server)
                try:
                    object_client.file(f"/objects/{quote(digest, safe='')}", path)
                finally:
                    object_client.close()
                return digest, path

            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
                fetched = executor.map(fetch_object, missing)
                for digest, path in fetched:
                    received_paths[digest] = path
        else:
            raise BenchmarkError(f"unsupported transport mode: {mode}")
        transfer_ns = time.perf_counter_ns() - transfer_started
    finally:
        client.close()

    expected_received = set(closure.objects) if mode == "archive" else set(missing)
    actual_received = set(received_paths)
    if actual_received != expected_received:
        raise BenchmarkError(f"{mode} returned the wrong object set")
    verification_started = time.perf_counter_ns()
    for digest, path in received_paths.items():
        verify_object(closure.objects[digest], read_bounded(path))
    verification_ns = time.perf_counter_ns() - verification_started

    cache_write_started = time.perf_counter_ns()
    for digest in missing:
        shutil.copyfile(received_paths[digest], cache / digest)
    cache_write_ns = time.perf_counter_ns() - cache_write_started
    elapsed_ns = time.perf_counter_ns() - started
    selfcheck_started = time.perf_counter_ns()
    for digest, info in closure.objects.items():
        verify_object(info, read_bounded(cache / digest))
    selfcheck_ns = time.perf_counter_ns() - selfcheck_started
    counters = server.state.snapshot().subtract(before)
    row = {
        "schema": SCHEMA,
        "kind": "transport-trial",
        "mode": mode,
        "cache_state": cache_state,
        "reuse_source": reuse_source,
        "iteration": iteration,
        "trial_order": trial_order,
        "platform": closure.platform,
        "image_digest": closure.image_digest,
        "rootfs_index_digest": closure.rootfs_index_digest,
        "logical_bytes": closure.logical_size,
        "object_count": len(closure.objects),
        "object_bytes": sum(info.size for info in closure.objects.values()),
        "objects_reused": len(reused),
        "bytes_reused": sum(closure.objects[digest].size for digest in reused),
        "objects_transferred": len(actual_received),
        "control_bytes": control_bytes,
        "request_count": counters.requests,
        "control_request_count": len(closure.controls),
        "data_request_count": counters.requests - len(closure.controls),
        "backend_reads": counters.backend_reads,
        "backend_retries": server.state.backend.retry_count() - retries_before,
        "backend_bytes": counters.backend_bytes,
        "request_bytes": counters.request_bytes,
        "response_bytes": counters.response_bytes,
        "batch_composition_ms": counters.batch_composition_ns / 1_000_000,
        "control_ms": control_ns / 1_000_000,
        "transfer_ms": transfer_ns / 1_000_000,
        "verification_ms": verification_ns / 1_000_000,
        "cache_write_ms": cache_write_ns / 1_000_000,
        "selfcheck_ms": selfcheck_ns / 1_000_000,
        "elapsed_ms": elapsed_ns / 1_000_000,
    }
    shutil.rmtree(cache)
    return row


def summarize(
    closure: Closure,
    overlap: Closure | None,
    rows: list[dict[str, Any]],
    compression: str,
    batch_size: int,
    concurrency: int,
    archive_bytes: int,
    archive_build_ms: float,
    backend_kind: str,
    backend_region: str | None,
) -> dict[str, Any]:
    cases = []
    for mode in ("objects", "archive", "batch"):
        for cache_state in ("cold", "partial"):
            selected = [row for row in rows if row["mode"] == mode and row["cache_state"] == cache_state]
            cases.append(
                {
                    "mode": mode,
                    "cache_state": cache_state,
                    "samples": len(selected),
                    "median_elapsed_ms": statistics.median(row["elapsed_ms"] for row in selected),
                    "median_control_ms": statistics.median(row["control_ms"] for row in selected),
                    "median_transfer_ms": statistics.median(row["transfer_ms"] for row in selected),
                    "median_verification_ms": statistics.median(
                        row["verification_ms"] for row in selected
                    ),
                    "median_cache_write_ms": statistics.median(
                        row["cache_write_ms"] for row in selected
                    ),
                    "median_selfcheck_ms": statistics.median(
                        row["selfcheck_ms"] for row in selected
                    ),
                    "median_response_bytes": statistics.median(row["response_bytes"] for row in selected),
                    "median_request_bytes": statistics.median(row["request_bytes"] for row in selected),
                    "median_backend_bytes": statistics.median(row["backend_bytes"] for row in selected),
                    "median_request_count": statistics.median(row["request_count"] for row in selected),
                    "median_control_request_count": statistics.median(
                        row["control_request_count"] for row in selected
                    ),
                    "median_data_request_count": statistics.median(
                        row["data_request_count"] for row in selected
                    ),
                    "median_backend_reads": statistics.median(row["backend_reads"] for row in selected),
                    "median_backend_retries": statistics.median(
                        row["backend_retries"] for row in selected
                    ),
                    "median_objects_reused": statistics.median(
                        row["objects_reused"] for row in selected
                    ),
                    "median_bytes_reused": statistics.median(row["bytes_reused"] for row in selected),
                    "median_objects_transferred": statistics.median(
                        row["objects_transferred"] for row in selected
                    ),
                    "median_batch_composition_ms": statistics.median(
                        row["batch_composition_ms"] for row in selected
                    ),
                }
            )
    return {
        "schema": SCHEMA,
        "kind": "transport-summary",
        "provenance": provenance(),
        "fixture": {
            "platform": closure.platform,
            "image_digest": closure.image_digest,
            "rootfs_index_digest": closure.rootfs_index_digest,
            "logical_bytes": closure.logical_size,
            "object_count": len(closure.objects),
            "object_bytes": sum(info.size for info in closure.objects.values()),
            "source": closure.source,
        },
        "transport": {
            "backend": backend_kind,
            "backend_region": backend_region,
            "archive": f"tar+{compression}" if compression != "none" else "tar",
            "archive_bytes": archive_bytes,
            "archive_build_ms": archive_build_ms,
            "batch_framing": "benchmark-only-v1",
            "batch_size": batch_size,
            "concurrency": concurrency,
            "connection_reuse": True,
            "byte_accounting": "http-body-only",
            "gateway_execution": "serial-cacheless",
            "s3_transient_retry_count": 2 if backend_kind == "s3" else 0,
        },
        "overlap_fixture": (
            {
                "platform": overlap.platform,
                "image_digest": overlap.image_digest,
                "rootfs_index_digest": overlap.rootfs_index_digest,
                "shared_object_count": len(set(closure.objects) & set(overlap.objects)),
                "shared_object_bytes": sum(
                    closure.objects[digest].size
                    for digest in set(closure.objects) & set(overlap.objects)
                ),
            }
            if overlap is not None
            else None
        ),
        "cases": cases,
    }


def run_benchmark(args: argparse.Namespace) -> None:
    concurrency = getattr(args, "concurrency", 16)
    if (
        args.iterations < 1
        or args.batch_size < 1
        or args.batch_size > MAX_BATCH_OBJECTS
        or concurrency < 1
        or concurrency > 64
    ):
        raise BenchmarkError("iterations, batch size, or concurrency are outside supported bounds")
    output = args.output.resolve()
    if output.exists():
        raise BenchmarkError(f"output already exists: {output}")
    closure = Closure.load(args.fixture)
    overlap = Closure.load(args.overlap_fixture) if args.overlap_fixture else None
    if overlap is not None and overlap.platform != closure.platform:
        raise BenchmarkError("overlap fixture platform differs from the target fixture")
    if overlap is not None and not (set(closure.objects) & set(overlap.objects)):
        raise BenchmarkError("overlap fixture shares no rootfs objects with the target fixture")
    output.mkdir(parents=True)
    archive = output / (
        "transport.tar.gz" if args.archive_compression == "gzip" else "transport.tar"
    )
    archive_started = time.perf_counter_ns()
    write_archive(closure, archive, args.archive_compression)
    archive_build_ms = (time.perf_counter_ns() - archive_started) / 1_000_000
    s3_uri = getattr(args, "s3_uri", None)
    s3_region = getattr(args, "s3_region", None)
    if s3_uri:
        if not s3_region:
            raise BenchmarkError("--s3-region is required with --s3-uri")
        backend_stage = output / "backend-stage"
        stage_backend(closure, archive, backend_stage)
        upload_backend(backend_stage, s3_uri)
        shutil.rmtree(backend_stage)
        backend: ObjectBackend = S3ObjectBackend(s3_uri, s3_region)
    else:
        backend = LocalObjectBackend(closure, archive)
    rows: list[dict[str, Any]] = []
    with TransportServer(closure, archive, backend, concurrency) as server, (output / "results.jsonl").open(
        "w", encoding="utf-8"
    ) as results:
        trial_order = 0
        for iteration in range(1, args.iterations + 1):
            modes = ("objects", "archive", "batch")
            offset = (iteration - 1) % len(modes)
            for mode in modes[offset:] + modes[:offset]:
                for cache_state in ("cold", "partial"):
                    trial_order += 1
                    row = run_trial(
                        server,
                        closure,
                        mode,
                        cache_state,
                        iteration,
                        output,
                        args.archive_compression,
                        overlap,
                        args.batch_size,
                        concurrency,
                        trial_order,
                    )
                    rows.append(row)
                    results.write(json.dumps(row, sort_keys=True) + "\n")
                    results.flush()
    (output / "summary.json").write_bytes(
        canonical_json(
            summarize(
                closure,
                overlap,
                rows,
                args.archive_compression,
                args.batch_size,
                concurrency,
                archive.stat().st_size,
                archive_build_ms,
                backend.kind,
                s3_region,
            )
        )
    )
    shutil.rmtree(output / "work")
    archive.unlink()
    print(f"image-gateway transport benchmark passed: {output / 'summary.json'}")


def run_command(argv: list[str], env: dict[str, str], cwd: Path, stdout: Path, stderr: Path, timeout: int) -> int:
    started = time.perf_counter_ns()
    with stdout.open("wb") as out, stderr.open("wb") as err:
        completed = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=err, timeout=timeout)
    if completed.returncode != 0:
        raise BenchmarkError(
            f"command failed ({completed.returncode}): {' '.join(argv)}; stderr: {stderr}"
        )
    return (time.perf_counter_ns() - started) // 1_000_000


def redact_log(path: Path, replacements: dict[str, str]) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    for original, replacement in replacements.items():
        text = text.replace(original, replacement)
    path.write_text(text, encoding="utf-8")


def prepare_fixture(args: argparse.Namespace) -> None:
    if args.iterations < 1 or args.timeout < 1:
        raise BenchmarkError("iterations and timeout must be positive")
    output = args.output.resolve()
    spore = args.spore_bin.resolve()
    if output.exists():
        raise BenchmarkError(f"output already exists: {output}")
    if not spore.is_file() or not os.access(spore, os.X_OK):
        raise BenchmarkError(f"spore binary is not executable: {spore}")
    output.mkdir(parents=True)
    requested_source = args.source
    effective_source = requested_source
    rows = []
    for iteration in range(1, args.iterations + 1):
        trial = output / "direct-oci" / str(iteration)
        trial.mkdir(parents=True)
        cache = trial / "cache"
        rootfs = trial / "rootfs.ext4"
        metadata = trial / "metadata.json"
        env = os.environ.copy()
        for name in list(env):
            if name.startswith("SPOREVM_"):
                del env[name]
        env["SPOREVM_EXT4_WRITER"] = "native"
        env["SPOREVM_ROOTFS_BUILD_PROFILE"] = "1"
        env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache)
        trial_source = effective_source
        command = [
            str(spore),
            "rootfs",
            "build",
            trial_source,
            "--platform",
            args.platform,
            "--output",
            str(rootfs),
            "--metadata",
            str(metadata),
        ]
        stdout_log = trial / "stdout.log"
        stderr_log = trial / "stderr.log"
        elapsed_ms = run_command(
            command,
            env,
            Path(__file__).resolve().parents[2],
            stdout_log,
            stderr_log,
            args.timeout,
        )
        value = parse_object(read_bounded(metadata), metadata)
        if value.get("ext4_writer") != "native" or value.get("platform") != {
            "os": "linux",
            "arch": args.platform.removeprefix("linux/"),
        }:
            raise BenchmarkError("direct OCI conversion used the wrong contract or platform")
        resolved = value.get("resolved_image_ref")
        if not isinstance(resolved, str) or "@sha256:" not in resolved:
            raise BenchmarkError("direct OCI conversion did not record a digest-pinned source")
        effective_source = resolved
        storage = value.get("rootfs_storage")
        if not isinstance(storage, dict):
            raise BenchmarkError("direct OCI conversion omitted rootfs storage metadata")
        profile = parse_profile(stderr_log)
        if not profile:
            raise BenchmarkError("direct OCI conversion emitted no rootfs profile phases")
        redactions = {
            str(spore): "spore",
            str(rootfs): "$TRIAL/rootfs.ext4",
            str(metadata): "$TRIAL/metadata.json",
        }
        redact_log(stdout_log, redactions)
        redact_log(stderr_log, redactions)
        rows.append(
            {
                "iteration": iteration,
                "source": trial_source,
                "platform": args.platform,
                "command": [redactions.get(part, part) for part in command],
                "elapsed_ms": elapsed_ms,
                "profile": profile,
                "logs": {
                    "stdout": file_descriptor(stdout_log, output),
                    "stderr": file_descriptor(stderr_log, output),
                },
                "rootfs_builder": value.get("builder_version"),
                "ext4_writer": value.get("ext4_writer"),
                "selected_manifest_digest": value.get("image_manifest_digest"),
                "rootfs_index_digest": storage.get("index_digest"),
            }
        )
        if iteration == 1:
            run_command(
                [
                    str(spore),
                    "image",
                    "export-fixture",
                    requested_source,
                    "--repository",
                    args.repository,
                    "--metadata",
                    str(metadata),
                    "--out",
                    str(output / "fixture"),
                ],
                env,
                Path(__file__).resolve().parents[2],
                trial / "export.stdout.log",
                trial / "export.stderr.log",
                args.timeout,
            )
        rootfs.unlink()
        shutil.rmtree(cache)
    closure = Closure.load(output / "fixture")
    if len({row["selected_manifest_digest"] for row in rows}) != 1 or len(
        {row["rootfs_index_digest"] for row in rows}
    ) != 1:
        raise BenchmarkError("direct OCI trials produced different immutable identities")
    if rows[0]["rootfs_index_digest"] != closure.rootfs_index_digest:
        raise BenchmarkError("exported fixture differs from the direct OCI trials")
    profile_medians, profile_samples = median_profiles(rows)
    result = {
        "schema": SCHEMA,
        "kind": "direct-oci-baseline",
        "provenance": provenance(),
        "requested_source": requested_source,
        "resolved_source": effective_source,
        "platform": args.platform,
        "spore_bin": spore.name,
        "spore_sha256": sha256(spore.read_bytes()),
        "fixture_image_digest": closure.image_digest,
        "fixture_rootfs_index_digest": closure.rootfs_index_digest,
        "samples": rows,
        "median_elapsed_ms": statistics.median(row["elapsed_ms"] for row in rows),
        "median_profile": profile_medians,
        "median_profile_samples": profile_samples,
    }
    (output / "direct-oci.json").write_bytes(canonical_json(result))
    print(f"image-gateway direct OCI baseline passed: {output / 'direct-oci.json'}")


def prepare_layout_fixture(args: argparse.Namespace) -> None:
    if args.iterations < 1 or args.timeout < 1:
        raise BenchmarkError("iterations and timeout must be positive")
    output = args.output.resolve()
    spore = args.spore_bin.resolve()
    layout = args.source_layout.resolve()
    if output.exists():
        raise BenchmarkError(f"output already exists: {output}")
    if not spore.is_file() or not os.access(spore, os.X_OK):
        raise BenchmarkError(f"spore binary is not executable: {spore}")
    if not layout.is_dir() or not (layout / "index.json").is_file():
        raise BenchmarkError(f"OCI layout is missing index.json: {layout}")
    output.mkdir(parents=True)
    index_data = read_bounded(layout / "index.json")
    source = f"oci-layout@{sha256(index_data)}"
    rows = []
    fixture_metadata: Path | None = None
    fixture_env: dict[str, str] | None = None
    for iteration in range(1, args.iterations + 1):
        trial = output / "direct-oci" / str(iteration)
        trial.mkdir(parents=True)
        cache = trial / "cache"
        env = os.environ.copy()
        for name in list(env):
            if name.startswith("SPOREVM_"):
                del env[name]
        env["SPOREVM_EXT4_WRITER"] = "native"
        env["SPOREVM_ROOTFS_BUILD_PROFILE"] = "1"
        env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache)
        command = [
            str(spore),
            "rootfs",
            "import-oci",
            str(layout),
            "--ref",
            f"local/gateway-benchmark:trial-{iteration}",
            "--platform",
            args.platform,
        ]
        stdout_log = trial / "stdout.log"
        stderr_log = trial / "stderr.log"
        elapsed_ms = run_command(
            command,
            env,
            Path(__file__).resolve().parents[2],
            stdout_log,
            stderr_log,
            args.timeout,
        )
        stdout_text = stdout_log.read_text(encoding="utf-8", errors="replace")
        match = METADATA_RE.search(stdout_text)
        if match is None:
            raise BenchmarkError("OCI layout import did not report its metadata path")
        metadata = Path(match.group("path"))
        value = parse_object(read_bounded(metadata), metadata)
        if value.get("ext4_writer") != "native" or value.get("platform") != {
            "os": "linux",
            "arch": args.platform.removeprefix("linux/"),
        }:
            raise BenchmarkError("OCI layout conversion used the wrong contract or platform")
        storage = value.get("rootfs_storage")
        if not isinstance(storage, dict):
            raise BenchmarkError("OCI layout conversion omitted rootfs storage metadata")
        profile = parse_profile(stderr_log)
        if not profile:
            raise BenchmarkError("OCI layout conversion emitted no rootfs profile phases")
        redactions = {
            str(spore): "spore",
            str(layout): "$OCI_LAYOUT",
            str(metadata): "$TRIAL/metadata.json",
            str(cache): "$TRIAL/cache",
        }
        redact_log(stdout_log, redactions)
        redact_log(stderr_log, redactions)
        rows.append(
            {
                "iteration": iteration,
                "source": source,
                "platform": args.platform,
                "command": [redactions.get(part, part) for part in command],
                "elapsed_ms": elapsed_ms,
                "profile": profile,
                "logs": {
                    "stdout": file_descriptor(stdout_log, output),
                    "stderr": file_descriptor(stderr_log, output),
                },
                "rootfs_builder": value.get("builder_version"),
                "ext4_writer": value.get("ext4_writer"),
                "selected_manifest_digest": value.get("image_manifest_digest"),
                "rootfs_index_digest": storage.get("index_digest"),
            }
        )
        if iteration == 1:
            fixture_metadata = metadata
            fixture_env = env
        else:
            shutil.rmtree(cache)
    if fixture_metadata is None or fixture_env is None:
        raise BenchmarkError("OCI layout conversion produced no fixture metadata")
    run_command(
        [
            str(spore),
            "image",
            "export-fixture",
            source,
            "--repository",
            args.repository,
            "--metadata",
            str(fixture_metadata),
            "--out",
            str(output / "fixture"),
        ],
        fixture_env,
        Path(__file__).resolve().parents[2],
        output / "export.stdout.log",
        output / "export.stderr.log",
        args.timeout,
    )
    shutil.rmtree(output / "direct-oci" / "1" / "cache")
    closure = Closure.load(output / "fixture")
    profile_medians, profile_samples = median_profiles(rows)
    result = {
        "schema": SCHEMA,
        "kind": "direct-oci-baseline",
        "input": "oci-layout",
        "provenance": provenance(),
        "requested_source": source,
        "resolved_source": source,
        "source_layout_index": file_descriptor(layout / "index.json", layout),
        "platform": args.platform,
        "spore_bin": spore.name,
        "spore_sha256": sha256(spore.read_bytes()),
        "fixture_image_digest": closure.image_digest,
        "fixture_rootfs_index_digest": closure.rootfs_index_digest,
        "samples": rows,
        "median_elapsed_ms": statistics.median(row["elapsed_ms"] for row in rows),
        "median_profile": profile_medians,
        "median_profile_samples": profile_samples,
    }
    (output / "direct-oci.json").write_bytes(canonical_json(result))
    print(f"image-gateway OCI layout baseline passed: {output / 'direct-oci.json'}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="record direct OCI conversion and export a fixture")
    prepare_source = prepare.add_mutually_exclusive_group(required=True)
    prepare_source.add_argument("--source")
    prepare_source.add_argument("--source-layout", type=Path)
    prepare.add_argument("--platform", choices=("linux/arm64", "linux/amd64"), required=True)
    prepare.add_argument("--repository", default="benchmark")
    prepare.add_argument("--spore-bin", type=Path, default=Path("zig-out/bin/spore"))
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--iterations", type=int, default=5)
    prepare.add_argument("--timeout", type=int, default=1800)
    run_parser = commands.add_parser("run", help="compare fixture transport candidates")
    run_parser.add_argument("--fixture", type=Path, required=True)
    run_parser.add_argument("--overlap-fixture", type=Path)
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument("--iterations", type=int, default=5)
    run_parser.add_argument("--batch-size", type=int, default=1024)
    run_parser.add_argument("--concurrency", type=int, default=16)
    run_parser.add_argument("--archive-compression", choices=("none", "gzip"), default="gzip")
    run_parser.add_argument("--s3-uri", help="upload and read the immutable backend from this S3 prefix")
    run_parser.add_argument("--s3-region", help="AWS region for --s3-uri")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "prepare":
            if args.source_layout is None:
                prepare_fixture(args)
            else:
                prepare_layout_fixture(args)
        else:
            run_benchmark(args)
    except (
        BenchmarkError,
        OSError,
        http.client.HTTPException,
        subprocess.SubprocessError,
    ) as error:
        print(f"image-gateway-transport: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
