"""Shared process, parsing, cleanup, and gate helpers for named restore evidence."""

from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import hashlib
import json
import math
import os
import pathlib
import platform
import re
import signal
import shutil
import statistics
import struct
import subprocess
import tarfile
import tempfile
import time
from typing import Any, Iterator


ROW_SCHEMA = "spore.named-restore-readiness.v2"
EVIDENCE_SCHEMA = "spore.named-restore-readiness-evidence.v1"
RESTORE_METRICS_RE = re.compile(r"(?P<backend>kvm|hvf) restore metrics: (?P<fields>.+)")
PROOF_METRICS_RE = re.compile(r"local RAM backing proof metrics: (?P<fields>.+)")
PINNED_IMAGE_RE = re.compile(r"[^@\s]+@sha256:[0-9a-f]{64}")
MEMORY_RE = re.compile(r"^(?P<value>[1-9][0-9]*)(?P<unit>mb|mib)$", re.IGNORECASE)
NON_REGRESSION_FIELDS = ("run_from_noop_ms", "first_noop_exec_ms", "repeated_exec_median_ms")
MIN_LOCAL_SPEEDUP = 2.0
NON_REGRESSION_RELATIVE = 0.20
NON_REGRESSION_ABSOLUTE_MS = 50.0
MAX_CAPTURE_BYTES = 16 * 1024
MANAGED_KERNEL_PIN: dict[str, object] = {
    "repository": "sporevm/kernels",
    "release": "v0.6.3",
    "linux_version": "6.1.155",
    "asset": "sporevm-arm64-linux-6.1.155-Image",
    "files": {
        "sporevm-kernels/v0.6.3/sporevm-arm64-linux-6.1.155-Image": {
            "size": 7_680_008,
            "sha256": "885c819cb929ec074d4e13c92a40daaf1ffaf2c278a63ebd7de92e1d9ae9dd4d",
        },
        "sporevm-kernels/v0.6.3/sporevm-arm64-linux-6.1.155-Image.sha256": {
            "size": 100,
            "sha256": "fd694a2c9d1617a1984fa7c327e1804820c4367b51d865ed7f61eb9b38c0d65d",
        },
        "sporevm-kernels/v0.6.3/sporevm-arm64-linux-6.1.155-Image.config": {
            "size": 70_854,
            "sha256": "ef0b16575d5a616d47d2d664bafe2c061f9123338d3daf93bb2cfbe13aba6784",
        },
    },
}


class BenchmarkError(RuntimeError):
    pass


class BenchmarkSignal(BaseException):
    def __init__(self, signum: int):
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


def elapsed_ms(start_ns: int) -> float:
    return (time.monotonic_ns() - start_ns) / 1_000_000


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_text(value: str) -> dict[str, object]:
    data = value.encode("utf-8", errors="replace")
    tail = data[-MAX_CAPTURE_BYTES:]
    return {
        "bytes": len(data),
        "sha256": sha256_bytes(data),
        "tail": tail.decode("utf-8", errors="replace"),
        "truncated": len(data) > len(tail),
    }


def parse_fields(value: str) -> dict[str, object]:
    fields: dict[str, object] = {}
    for item in value.split():
        key, separator, raw = item.partition("=")
        if not separator:
            continue
        try:
            fields[key] = int(raw)
        except ValueError:
            fields[key] = raw
    return fields


def parse_restore_metrics_all(stderr: str) -> list[dict[str, object]]:
    matches = list(RESTORE_METRICS_RE.finditer(stderr))
    metrics: list[dict[str, object]] = []
    for match in matches:
        fields = parse_fields(match.group("fields"))
        fields["backend"] = match.group("backend")
        metrics.append(fields)
    return metrics


def parse_proof_metrics(stderr: str, operation: str | None = None) -> list[dict[str, object]]:
    metrics = [parse_fields(match.group("fields")) for match in PROOF_METRICS_RE.finditer(stderr)]
    if operation is None:
        return metrics
    return [item for item in metrics if item.get("operation") == operation]


def require_single_proof_metric(stderr: str, operation: str, label: str) -> dict[str, object]:
    metrics = parse_proof_metrics(stderr, operation)
    if len(metrics) != 1:
        raise BenchmarkError(f"{label}: expected exactly one {operation} proof metric, got {len(metrics)}")
    return metrics[0]


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def is_nonnegative_number(value: object) -> bool:
    return is_number(value) and float(value) >= 0


def memory_mib(value: str) -> int:
    match = MEMORY_RE.fullmatch(value)
    if not match:
        raise BenchmarkError("--memory must use a whole MiB value such as 1024mb")
    return int(match.group("value"))


@dataclasses.dataclass
class CommandResult:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    elapsed_ms: float
    timed_out: bool = False
    path_aliases: dict[str, str] = dataclasses.field(default_factory=dict, repr=False)

    def evidence(self) -> dict[str, object]:
        return {
            "argv": normalize_paths(self.argv, self.path_aliases),
            "status": self.returncode,
            "elapsed_ms": self.elapsed_ms,
            "timed_out": self.timed_out,
            "stdout": bounded_public_text(self.stdout, self.path_aliases),
            "stderr": bounded_public_text(self.stderr, self.path_aliases),
        }


class SignalState:
    def __init__(self) -> None:
        self.signum: int | None = None
        self.cleanup_depth = 0
        self.previous: dict[int, Any] = {}

    def install(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            self.previous[signum] = signal.getsignal(signum)
            signal.signal(signum, self._handle)

    def restore(self) -> None:
        for signum, handler in self.previous.items():
            signal.signal(signum, handler)
        self.previous.clear()

    def _handle(self, signum: int, _frame: object) -> None:
        self.signum = signum
        if self.cleanup_depth == 0:
            raise BenchmarkSignal(signum)

    @contextlib.contextmanager
    def cleanup(self) -> Iterator[None]:
        self.cleanup_depth += 1
        try:
            yield
        finally:
            self.cleanup_depth -= 1


class CommandRunner:
    def __init__(self, signals: SignalState):
        self.signals = signals
        self.path_aliases: dict[str, str] = {}

    def set_path_aliases(self, aliases: dict[str, str]) -> None:
        self.path_aliases = aliases.copy()

    def run(
        self,
        argv: list[str],
        env: dict[str, str],
        timeout_s: float,
    ) -> CommandResult:
        start_ns = time.monotonic_ns()
        proc = subprocess.Popen(
            argv,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        timed_out = False
        try:
            stdout, stderr = proc.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._stop(proc)
            stdout, stderr = proc.communicate()
        except BaseException:
            self._stop(proc)
            proc.communicate()
            raise
        return CommandResult(
            argv=argv,
            returncode=124 if timed_out else proc.returncode,
            stdout=stdout,
            stderr=stderr,
            elapsed_ms=elapsed_ms(start_ns),
            timed_out=timed_out,
            path_aliases=self.path_aliases.copy(),
        )

    @staticmethod
    def _stop(proc: subprocess.Popen[str]) -> None:
        if proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def debug_spore_wrapper(real_spore_bin: pathlib.Path, runtime_dir: pathlib.Path) -> pathlib.Path:
    digest = sha256_file(real_spore_bin)[:12]
    wrapper = runtime_dir / f"spore-with-restore-metrics-{digest}"
    wrapper.write_text(
        "#!/usr/bin/env python3\n"
        "import os\n"
        "import sys\n"
        f"os.execv({str(real_spore_bin)!r}, [sys.argv[0], '--debug', *sys.argv[1:]])\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o700)
    return wrapper


def read_pid(path: pathlib.Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
        pid = int(raw)
        return pid if pid > 0 else None
    except (FileNotFoundError, OSError, ValueError):
        return None


def pid_alive(pid: int | None) -> bool:
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_pid(pid: int | None, timeout_s: float) -> bool:
    if not pid_alive(pid):
        return False
    assert pid is not None
    for signum in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            return True
        deadline = time.monotonic() + min(timeout_s, 1)
        while pid_alive(pid) and time.monotonic() < deadline:
            time.sleep(0.02)
        if not pid_alive(pid):
            return True
    return True


def active_lease_snapshot(runtime_dir: pathlib.Path) -> dict[str, tuple[int, str]]:
    lease_dir = runtime_dir / "leases"
    if not lease_dir.exists():
        return {}
    if lease_dir.is_symlink() or not lease_dir.is_dir():
        raise BenchmarkError("active lease path is not a regular directory")
    snapshot: dict[str, tuple[int, str]] = {}
    for path in sorted(lease_dir.iterdir()):
        if path.is_symlink() or not path.is_file():
            raise BenchmarkError(f"active lease is not a regular file: {path.name}")
        stat = path.stat()
        snapshot[path.name] = (stat.st_size, sha256_file(path))
    return snapshot


def cleanup_named(
    runner: CommandRunner,
    spore_bin: pathlib.Path,
    env: dict[str, str],
    runtime_dir: pathlib.Path,
    name: str,
    leases_before: dict[str, tuple[int, str]],
    timeout_s: float,
) -> dict[str, object]:
    with runner.signals.cleanup():
        vm_dir = runtime_dir / "vms" / name
        pid = read_pid(vm_dir / "pid")
        result = runner.run([str(spore_bin), "rm", name], env, timeout_s)
        deadline = time.monotonic() + (min(timeout_s, 5) if result.returncode == 0 else 0)
        while (vm_dir.exists() or pid_alive(pid)) and time.monotonic() < deadline:
            time.sleep(0.02)
        forced_pid_cleanup = stop_pid(pid, timeout_s)
        if pid_alive(pid):
            raise BenchmarkError(f"named monitor {name} survived rm and exact-PID cleanup")
        if vm_dir.exists():
            shutil.rmtree(vm_dir, ignore_errors=True)
        if vm_dir.exists():
            raise BenchmarkError(f"named runtime {name} survived cleanup")
        leases_after_rm = active_lease_snapshot(runtime_dir)
        if any(leases_after_rm.get(key) != value for key, value in leases_before.items()):
            raise BenchmarkError(f"named cleanup changed a pre-existing active lease: {name}")
        added_leases = sorted(set(leases_after_rm) - set(leases_before))
        for lease_name in added_leases:
            (runtime_dir / "leases" / lease_name).unlink()
        leases_after = active_lease_snapshot(runtime_dir)
        if leases_after != leases_before:
            raise BenchmarkError(f"named cleanup did not restore the active lease set: {name}")
        return {
            "status": result.returncode,
            "elapsed_ms": result.elapsed_ms,
            "runtime_absent": True,
            "pid_absent": True,
            "forced_pid_cleanup": forced_pid_cleanup,
            "lease_count_before": len(leases_before),
            "lease_count_after_rm": len(leases_after_rm),
            "lease_count_after": len(leases_after),
            "lease_restored": True,
            "forced_lease_cleanup": bool(added_leases),
            "command": result.evidence(),
        }


def read_monitor_log(runtime_dir: pathlib.Path, name: str) -> str:
    logs = list(runtime_dir.rglob(f"{name}/monitor.log"))
    return "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in logs)


def normalize_paths(value: object, aliases: dict[str, str]) -> object:
    if isinstance(value, str):
        normalized = value
        for path, alias in sorted(aliases.items(), key=lambda item: len(item[0]), reverse=True):
            normalized = normalized.replace(path, alias)
        return normalized
    if isinstance(value, list):
        return [normalize_paths(item, aliases) for item in value]
    if isinstance(value, dict):
        return {
            normalize_paths(key, aliases): normalize_paths(item, aliases)
            for key, item in value.items()
        }
    return value


def bounded_public_text(value: str, aliases: dict[str, str]) -> dict[str, object]:
    normalized = normalize_paths(value, aliases)
    assert isinstance(normalized, str)
    return bounded_text(normalized)


def binary_identity(runner: CommandRunner, path: pathlib.Path, env: dict[str, str], timeout_s: float) -> dict[str, object]:
    resolved = path.resolve()
    version = runner.run([str(resolved), "version"], env, timeout_s)
    if version.returncode != 0:
        raise BenchmarkError(f"binary version failed for {resolved}: {version.stderr.strip()}")
    stat = resolved.stat()
    return {"size": stat.st_size, "sha256": sha256_file(resolved), "version": version.stdout.strip()}


def filesystem_info(path: pathlib.Path) -> dict[str, object]:
    stat = path.stat()
    vfs = os.statvfs(path)
    filesystem = "not_reported"
    if platform.system() == "Linux":
        try:
            result = subprocess.run(
                ["findmnt", "--noheadings", "--output", "FSTYPE", "--target", str(path)],
                text=True,
                capture_output=True,
                check=False,
            )
        except OSError:
            pass
        else:
            if result.returncode == 0:
                fields = result.stdout.split()
                if fields:
                    filesystem = fields[0]
    return {
        "device": stat.st_dev,
        "filesystem": filesystem,
        "block_size": vfs.f_bsize,
        "fragment_size": vfs.f_frsize,
    }


def _linux_ioc(direction: int, number: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord("f") << 8) | number


def _linux_fsverity_probe(root: pathlib.Path) -> dict[str, object]:
    enable_format = "=IIIIQIIQ11Q"
    enable_arg = struct.pack(
        enable_format,
        1,
        1,
        os.sysconf("SC_PAGESIZE"),
        0,
        0,
        0,
        0,
        0,
        *([0] * 11),
    )
    enable_request = _linux_ioc(1, 133, struct.calcsize(enable_format))
    measure_request = _linux_ioc(3, 134, struct.calcsize("=HH"))
    probe = root / ".sporevm-fsverity-preflight"
    created = False
    fd = -1
    try:
        write_fd = os.open(
            probe,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        created = True
        try:
            payload = b"sporevm named-restore fs-verity preflight\n"
            written = 0
            while written < len(payload):
                count = os.write(write_fd, payload[written:])
                if count == 0:
                    raise BenchmarkError("release scratch fs-verity probe write made no progress")
                written += count
            os.fsync(write_fd)
        finally:
            os.close(write_fd)
        fd = os.open(probe, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        fcntl.ioctl(fd, enable_request, enable_arg)
        measured = bytearray(struct.pack("=HH32s", 1, 32, b"\0" * 32))
        fcntl.ioctl(fd, measure_request, measured, True)
        algorithm, digest_size, digest = struct.unpack("=HH32s", measured)
        if algorithm != 1 or digest_size != 32:
            raise BenchmarkError("release scratch fs-verity probe returned a non-SHA-256 digest")
        return {"status": "ok", "algorithm": "sha256", "digest": digest.hex()}
    except OSError as err:
        raise BenchmarkError(
            f"release scratch does not support required fs-verity: errno={err.errno} {err.strerror}"
        ) from err
    finally:
        if fd >= 0:
            os.close(fd)
        if created:
            with contextlib.suppress(FileNotFoundError):
                probe.unlink()


def require_release_scratch_filesystem(system: str, backend: str, filesystem: object) -> None:
    if backend == "kvm" and (system != "Linux" or filesystem != "ext4"):
        raise BenchmarkError(
            f"KVM release scratch must be Linux ext4, got {system}/{filesystem}"
        )


def release_scratch_precondition(path: pathlib.Path, backend: str) -> dict[str, object]:
    info = filesystem_info(path)
    system = platform.system()
    require_release_scratch_filesystem(system, backend, info["filesystem"])
    if backend != "kvm":
        return {"required": False, "filesystem": info}
    return {
        "required": True,
        "proof_schema": 2,
        "verity": "sha256",
        "filesystem": info,
        "probe": _linux_fsverity_probe(path),
    }


def file_identity(path: pathlib.Path) -> dict[str, object]:
    stat = path.stat()
    return {
        "device": stat.st_dev,
        "inode": stat.st_ino,
        "uid": stat.st_uid,
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "allocated_bytes": stat.st_blocks * 512,
    }


def managed_kernel_identities(root: pathlib.Path) -> list[dict[str, object]]:
    identities: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BenchmarkError(f"managed kernel cache contains a symlink: {path.relative_to(root)}")
        if path.is_file():
            identities.append({
                "relative_path": path.relative_to(root).as_posix(),
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
            })
    if not identities:
        raise BenchmarkError("managed kernel cache is empty after parent capture")
    sidecars = sorted(root.rglob("*.sha256"))
    if not sidecars:
        raise BenchmarkError("managed kernel cache has no checksum sidecar")
    for sidecar in sidecars:
        kernel = sidecar.with_suffix("")
        config = pathlib.Path(f"{kernel}.config")
        parts = sidecar.read_text(encoding="utf-8").split()
        if (
            len(parts) < 1
            or not re.fullmatch(r"[0-9a-f]{64}", parts[0])
            or not kernel.is_file()
            or not config.is_file()
            or sha256_file(kernel) != parts[0]
        ):
            raise BenchmarkError(f"managed kernel cache checksum set is invalid: {sidecar.relative_to(root)}")
    return identities


def require_managed_kernel_pin(
    identities: list[dict[str, object]],
    pin: dict[str, object] = MANAGED_KERNEL_PIN,
) -> None:
    files = pin.get("files")
    if not isinstance(files, dict):
        raise BenchmarkError("managed kernel pin has no file identities")
    actual = {
        str(item.get("relative_path")): {
            "size": item.get("size"),
            "sha256": item.get("sha256"),
        }
        for item in identities
    }
    if actual != files:
        raise BenchmarkError("managed kernel cache does not match the release pin")


def make_tree_immutable(root: pathlib.Path) -> None:
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            path = pathlib.Path(dirpath) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode & ~0o222)
        for name in dirnames:
            path = pathlib.Path(dirpath) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode & ~0o222)
    root.chmod(root.stat().st_mode & ~0o222)


def make_tree_writable(root: pathlib.Path) -> None:
    if not root.exists():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        for name in [*dirnames, *filenames]:
            path = pathlib.Path(dirpath) / name
            if not path.is_symlink():
                with contextlib.suppress(OSError):
                    path.chmod(path.stat().st_mode | 0o700)
    with contextlib.suppress(OSError):
        root.chmod(root.stat().st_mode | 0o700)


def git_identity(repo: pathlib.Path, expected_commit: str) -> dict[str, object]:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, text=True, capture_output=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=repo, text=True, capture_output=True, check=True).stdout
    if head != expected_commit:
        raise BenchmarkError(f"repository HEAD {head} does not match expected commit {expected_commit}")
    if dirty:
        raise BenchmarkError("release benchmark requires a clean worktree")
    return {"commit": head, "dirty": False}


def host_identity(backend: str) -> dict[str, object]:
    uname = platform.uname()
    cpu_model = "unknown"
    if uname.system == "Darwin":
        result = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            cpu_model = result.stdout.strip()
    elif uname.system == "Linux":
        with contextlib.suppress(OSError):
            for line in pathlib.Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
                key, separator, value = line.partition(":")
                if separator and key.strip() in ("model name", "Model", "Hardware"):
                    cpu_model = value.strip()
                    break
    page_size = os.sysconf("SC_PAGE_SIZE")
    return {
        "os": uname.system,
        "release": uname.release,
        "version": uname.version,
        "architecture": uname.machine,
        "cpu_model": cpu_model,
        "cpu_count": os.cpu_count(),
        "memory_bytes": os.sysconf("SC_PHYS_PAGES") * page_size,
        "load_average": list(os.getloadavg()),
        "page_size": page_size,
        "backend": backend,
    }


def archive_member_identity(archive: pathlib.Path, member_path: str) -> dict[str, object]:
    digest = hashlib.sha256()
    with tarfile.open(archive, "r:gz") as tar:
        member = tar.getmember(member_path)
        extracted = tar.extractfile(member)
        if extracted is None or not member.isfile():
            raise BenchmarkError(f"baseline archive member is not a regular file: {member_path}")
        for chunk in iter(lambda: extracted.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": member_path, "size": member.size, "sha256": digest.hexdigest()}


def verify_release_inputs(
    archive: pathlib.Path,
    checksums: pathlib.Path,
    expected_archive_sha256: str,
    expected_checksums_sha256: str,
    baseline_bin: pathlib.Path,
    member_path: str,
) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{64}", expected_archive_sha256):
        raise BenchmarkError("expected baseline archive sha256 is not canonical")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_checksums_sha256):
        raise BenchmarkError("expected baseline checksums sha256 is not canonical")
    actual_checksums_sha256 = sha256_file(checksums)
    if actual_checksums_sha256 != expected_checksums_sha256:
        raise BenchmarkError(
            f"baseline checksums sha256 {actual_checksums_sha256} does not match expected {expected_checksums_sha256}"
        )
    actual_archive_sha256 = sha256_file(archive)
    if actual_archive_sha256 != expected_archive_sha256:
        raise BenchmarkError(
            f"baseline archive sha256 {actual_archive_sha256} does not match expected {expected_archive_sha256}"
        )
    entries: list[str] = []
    for line in checksums.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 2 and pathlib.Path(parts[-1].lstrip("*")).name == archive.name:
            entries.append(parts[0])
    if entries != [expected_archive_sha256]:
        raise BenchmarkError(f"release checksums do not pin {archive.name} to {expected_archive_sha256}")
    member = archive_member_identity(archive, member_path)
    extracted = {"size": baseline_bin.stat().st_size, "sha256": sha256_file(baseline_bin)}
    if extracted != {"size": member["size"], "sha256": member["sha256"]}:
        raise BenchmarkError("--baseline-bin does not match the verified release archive member")
    return {
        "archive_name": archive.name,
        "archive_sha256": actual_archive_sha256,
        "checksums_sha256": actual_checksums_sha256,
        "binary_member": member,
    }


def median(rows: list[dict[str, object]], field: str) -> float:
    values = [float(row[field]) for row in rows if is_number(row.get(field))]
    if len(values) != len(rows) or not values:
        raise BenchmarkError(f"cannot compute {field} median from incomplete rows")
    return statistics.median(values)


def lane_summary(rows: list[dict[str, object]]) -> dict[str, object]:
    fields = (
        "restore_return_ms",
        "exec_ready_wait_ms",
        "restore_total_ms",
        "backend_memory_ms",
        "backend_state_ms",
        "backend_pre_run_ms",
        "run_from_noop_ms",
        "first_noop_exec_ms",
        "repeated_exec_median_ms",
        "proof_validation_us",
        "proof_precharge_us",
        "cleanup_ms",
    )
    medians: dict[str, float | None] = {}
    for field in fields:
        present = [is_number(row.get(field)) for row in rows]
        if any(present) and not all(present):
            raise BenchmarkError(f"lane summary field is partially populated: {field}")
        medians[field] = median(rows, field) if all(present) else None
    return {
        "rows": len(rows),
        "restore_sources": sorted({str(row["restore_source"]) for row in rows}),
        "restore_reasons": sorted({
            str(row["restore_reason"])
            for row in rows
            if row.get("restore_reason") is not None
        }),
        "proof_schemas": sorted({
            row["proof_schema_version"]
            for row in rows
            if row.get("proof_schema_version") is not None
        }),
        "medians": medians,
    }


def non_regression_gates(
    candidate: list[dict[str, object]], reference: list[dict[str, object]], label: str
) -> list[dict[str, object]]:
    gates: list[dict[str, object]] = []
    for field in NON_REGRESSION_FIELDS:
        candidate_value = median(candidate, field)
        reference_value = median(reference, field)
        delta = candidate_value - reference_value
        relative = math.inf if reference_value == 0 and delta > 0 else (delta / reference_value if reference_value else 0.0)
        gates.append({
            "name": f"{label}.{field}.non_regression",
            "kind": "performance",
            "threshold": {
                "relative": NON_REGRESSION_RELATIVE,
                "absolute_ms": NON_REGRESSION_ABSOLUTE_MS,
                "fails_when_both_exceeded": True,
            },
            "observed": {
                "candidate_median_ms": candidate_value,
                "reference_median_ms": reference_value,
                "delta_ms": delta,
                "relative": relative,
            },
            "passed": not (delta >= NON_REGRESSION_ABSOLUTE_MS and relative > NON_REGRESSION_RELATIVE),
        })
    return gates


def performance_gate(local: list[dict[str, object]], eager: list[dict[str, object]], label: str) -> list[dict[str, object]]:
    local_restore = median(local, "restore_return_ms")
    eager_restore = median(eager, "restore_return_ms")
    ratio = math.inf if local_restore == 0 else eager_restore / local_restore
    gates = [{
        "name": f"{label}.local_readiness_speedup",
        "kind": "performance",
        "threshold": {"minimum_ratio": MIN_LOCAL_SPEEDUP, "comparison": "same-head eager/local restore_return_ms"},
        "observed": {"ratio": ratio, "local_median_ms": local_restore, "eager_median_ms": eager_restore},
        "passed": ratio >= MIN_LOCAL_SPEEDUP,
    }]
    gates.extend(non_regression_gates(local, eager, label))
    gates.append({
        "name": f"{label}.eager_materialization_cost",
        "kind": "measurement",
        "threshold": {"all_rows_positive": True},
        "observed": {
            "median_ms": median(eager, "backend_memory_ms"),
            "min_ms": min(float(row["backend_memory_ms"]) for row in eager),
            "max_ms": max(float(row["backend_memory_ms"]) for row in eager),
        },
        "passed": all(float(row["backend_memory_ms"]) > 0 for row in eager),
    })
    return gates


def self_test() -> None:
    assert _linux_ioc(1, 133, 128) == 0x40806685
    assert _linux_ioc(3, 134, 4) == 0xC0046686
    original_ioctl = fcntl.ioctl
    ioctl_requests: list[int] = []

    def fake_ioctl(_fd: int, request: int, arg: object = 0, _mutate: bool = True) -> object:
        ioctl_requests.append(request)
        if isinstance(arg, bytearray):
            struct.pack_into("=HH32s", arg, 0, 1, 32, b"\xab" * 32)
        return arg

    with tempfile.TemporaryDirectory(prefix="sporevm-fsverity-preflight-test-") as raw_root:
        fcntl.ioctl = fake_ioctl
        try:
            probe = _linux_fsverity_probe(pathlib.Path(raw_root))
        finally:
            fcntl.ioctl = original_ioctl
        assert probe == {"status": "ok", "algorithm": "sha256", "digest": "ab" * 32}
        assert not (pathlib.Path(raw_root) / ".sporevm-fsverity-preflight").exists()
    assert ioctl_requests == [0x40806685, 0xC0046686]
    require_release_scratch_filesystem("Linux", "kvm", "ext4")
    for filesystem in ("zfs", "tmpfs", "not_reported"):
        try:
            require_release_scratch_filesystem("Linux", "kvm", filesystem)
        except BenchmarkError:
            pass
        else:
            raise AssertionError(f"KVM release scratch accepted {filesystem}")
    restore_rows = parse_restore_metrics_all(
        "info: kvm restore metrics: mode=local_backing ram_mib=1024 chunks=16 "
        "nonzero_chunks=12 manifest_ms=1 map_ram_ms=0 memory_ms=0 state_ms=2 pre_run_ms=4"
    )
    assert restore_rows == [{
        "backend": "kvm", "mode": "local_backing", "ram_mib": 1024, "chunks": 16,
        "nonzero_chunks": 12, "manifest_ms": 1, "map_ram_ms": 0, "memory_ms": 0,
        "state_ms": 2, "pre_run_ms": 4,
    }]
    assert len(parse_restore_metrics_all(
        "kvm restore metrics: mode=eager_chunks ram_mib=1 memory_ms=1 state_ms=1 pre_run_ms=1\n"
        "kvm restore metrics: mode=local_backing ram_mib=1 memory_ms=0 state_ms=1 pre_run_ms=1"
    )) == 2
    proof = parse_proof_metrics(
        "debug: local RAM backing proof metrics: operation=validate status=ok source=local_backing "
        "reason=proof_valid schema=2 verity=sha256 validation_us=91 precharge_us=7",
        "validate",
    )
    assert proof[0]["reason"] == "proof_valid"
    assert proof[0]["validation_us"] == 91
    duplicate_proof = (
        "local RAM backing proof metrics: operation=validate status=ok source=local_backing "
        "reason=proof_valid schema=2 verity=sha256 validation_us=1 precharge_us=1\n"
    ) * 2
    try:
        require_single_proof_metric(duplicate_proof, "validate", "duplicate")
    except BenchmarkError:
        pass
    else:
        raise AssertionError("duplicate proof metrics were accepted")
    synthetic_kernel = [{
        "relative_path": "repo/release/Image",
        "size": 4,
        "sha256": "a" * 64,
    }]
    synthetic_pin: dict[str, object] = {
        "files": {"repo/release/Image": {"size": 4, "sha256": "a" * 64}},
    }
    require_managed_kernel_pin(synthetic_kernel, synthetic_pin)
    try:
        require_managed_kernel_pin(
            [synthetic_kernel[0] | {"sha256": "b" * 64}],
            synthetic_pin,
        )
    except BenchmarkError:
        pass
    else:
        raise AssertionError("managed kernel drift was accepted")
    sample = [{
        "restore_return_ms": 50.0, "run_from_noop_ms": 20.0, "first_noop_exec_ms": 5.0,
        "repeated_exec_median_ms": 4.0, "backend_memory_ms": 0,
    }]
    eager = [{
        "restore_return_ms": 100.0, "run_from_noop_ms": 20.0, "first_noop_exec_ms": 5.0,
        "repeated_exec_median_ms": 4.0, "backend_memory_ms": 500,
    }]
    assert all(bool(gate["passed"]) for gate in performance_gate(sample, eager, "boundary"))
    baseline = [{
        "run_from_noop_ms": 100.0, "first_noop_exec_ms": 100.0, "repeated_exec_median_ms": 100.0,
    }]
    allowed = [{
        "run_from_noop_ms": 149.0, "first_noop_exec_ms": 149.0, "repeated_exec_median_ms": 149.0,
    }]
    blocked = [{
        "run_from_noop_ms": 151.0, "first_noop_exec_ms": 151.0, "repeated_exec_median_ms": 151.0,
    }]
    assert all(bool(gate["passed"]) for gate in non_regression_gates(allowed, baseline, "allowed"))
    assert not any(bool(gate["passed"]) for gate in non_regression_gates(blocked, baseline, "blocked"))

    secret_root = "/private/benchmark-secret"
    aliases = {
        f"{secret_root}/repo/zig-out/bin/spore": "$CURRENT_BIN",
        f"{secret_root}/baseline/bin/spore": "$BASELINE_BIN",
        f"{secret_root}/inputs/spore.tar.gz": "$BASELINE_ARCHIVE",
        f"{secret_root}/inputs/checksums.txt": "$BASELINE_CHECKSUMS",
        f"{secret_root}/repo": "$REPO",
        f"{secret_root}/scratch": "$SCRATCH",
        f"{secret_root}/output": "$OUTPUT",
    }
    command = CommandResult(
        argv=[f"{secret_root}/repo/zig-out/bin/spore", "restore", f"{secret_root}/scratch/parent.spore"],
        returncode=1,
        stdout=f"parent={secret_root}/scratch/parent.spore",
        stderr=f"output={secret_root}/output/rows.jsonl",
        elapsed_ms=1.0,
        path_aliases=aliases,
    )
    image_resolution = CommandResult(
        argv=[f"{secret_root}/repo/zig-out/bin/spore", "image", "resolve"],
        returncode=0,
        stdout=f"cache={secret_root}/scratch/rootfs-cache",
        stderr=f"binary={secret_root}/baseline/bin/spore",
        elapsed_ms=2.0,
        path_aliases=aliases,
    )
    split_path = f"{secret_root}/scratch/split-boundary"
    split_tail = "z" * (MAX_CAPTURE_BYTES - len(secret_root) // 2)
    split_result = CommandResult(
        argv=[f"{secret_root}/baseline/bin/spore", f"{secret_root}/inputs/spore.tar.gz"],
        returncode=0,
        stdout="x" * 20 + split_path + split_tail,
        stderr=f"checksums={secret_root}/inputs/checksums.txt",
        elapsed_ms=3.0,
        path_aliases=aliases,
    )
    nested_evidence = {
        "command": command.evidence(),
        "image_resolution": image_resolution.evidence(),
        "parent": {
            "capture": split_result.evidence(),
            "archive": f"{secret_root}/inputs/spore.tar.gz",
            f"{secret_root}/scratch/nested-key": "normalized",
        },
        "fanout": [{
            "child": f"{secret_root}/output/fanout/000000",
            "stderr": f"repo={secret_root}/repo baseline={secret_root}/baseline/bin/spore",
        }],
    }
    normalized = normalize_paths(nested_evidence, aliases)
    serialized = json.dumps(normalized, sort_keys=True)
    assert secret_root not in serialized
    assert secret_root[len(secret_root) // 2:] not in serialized
    assert "$CURRENT_BIN" in serialized
    assert "$SCRATCH/parent.spore" in serialized
    assert "$OUTPUT/fanout/000000" in serialized
    print("self-test ok")
