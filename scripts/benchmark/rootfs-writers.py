#!/usr/bin/env python3
"""Compare native and external rootfs writer phase timings."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


PROFILE_RE = re.compile(r"spore rootfs profile: phase=(?P<phase>\S+) ms=(?P<ms>\d+)(?P<tail>.*)")

CONVERSION_PHASES = (
    "tree_merge",
    "layer_extract_staging",
    "rootfs_tree_finalize",
    "host_metadata_normalize",
    "ext4_size_scan",
    "ext4_create_empty",
    "mkfs_ext4",
    "debugfs_finalize",
    "rootfs_cas_preload",
    "native_ext4_emit",
)


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def run_command(argv: list[str], env: dict[str, str], stdout: Path, stderr: Path, timeout_s: int) -> tuple[int, int]:
    stdout.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic_ns()
    with stdout.open("wb") as out, stderr.open("wb") as err:
        completed = subprocess.run(argv, env=env, stdout=out, stderr=err, timeout=timeout_s, check=False)
    return completed.returncode, (time.monotonic_ns() - started) // 1_000_000


def parse_profile(path: Path) -> dict[str, dict[str, object]]:
    phases: dict[str, dict[str, object]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PROFILE_RE.search(line)
        if not match:
            continue
        extra: dict[str, int] = {}
        for part in match.group("tail").split():
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            try:
                extra[key] = int(value)
            except ValueError:
                continue
        phases[match.group("phase")] = {"ms": int(match.group("ms")), **extra}
    return phases


def phase_ms(phases: dict[str, dict[str, object]], name: str) -> int | None:
    value = phases.get(name, {}).get("ms")
    return value if isinstance(value, int) else None


def conversion_ms(phases: dict[str, dict[str, object]]) -> int:
    return sum(phase_ms(phases, phase) or 0 for phase in CONVERSION_PHASES)


def load_metadata(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def run_writer(args: argparse.Namespace, writer: str, root: Path) -> dict[str, object]:
    output = args.output_dir / f"rootfs-{writer}.ext4"
    metadata = args.output_dir / f"rootfs-{writer}.json"
    stdout = args.output_dir / f"{writer}.stdout"
    stderr = args.output_dir / f"{writer}.stderr"
    cache_dir = args.output_dir / f"{writer}-cache"
    shutil.rmtree(cache_dir, ignore_errors=True)
    cache_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["SPOREVM_EXT4_WRITER"] = writer
    env["SPOREVM_ROOTFS_BUILD_PROFILE"] = "1"
    env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache_dir)

    argv = [
        str(args.spore_bin),
        "rootfs",
        "build",
        args.image,
        "--platform",
        args.platform,
        "--output",
        str(output),
        "--metadata",
        str(metadata),
    ]
    status, elapsed_ms = run_command(argv, env, stdout, stderr, args.timeout_s)
    metadata_json = load_metadata(metadata)
    rootfs_storage = metadata_json.get("rootfs_storage")
    index_digest = rootfs_storage.get("index_digest") if isinstance(rootfs_storage, dict) else None
    valid_index_digest = (
        isinstance(index_digest, str)
        and re.fullmatch(r"blake3:[0-9a-f]{64}", index_digest) is not None
    )
    phases = parse_profile(stderr)
    return {
        "writer": writer,
        "status": status,
        "success": status == 0 and valid_index_digest,
        "elapsed_ms": elapsed_ms,
        "output": str(output),
        "metadata": str(metadata),
        "stdout": str(stdout),
        "stderr": str(stderr),
        "rootfs_size": metadata_json.get("rootfs_size"),
        "index_digest": index_digest,
        "resolved_image_ref": metadata_json.get("resolved_image_ref"),
        "phases": phases,
        "conversion_ms": conversion_ms(phases),
        "spore_bin": str(args.spore_bin),
        "repo": str(root),
    }


def fmt_ms(value: object) -> str:
    if not isinstance(value, int):
        return "-"
    if value >= 1000:
        return f"{value / 1000:.2f}s"
    return f"{value}ms"


def render_markdown(result: dict[str, object]) -> str:
    runs = {str(run["writer"]): run for run in result["runs"] if isinstance(run, dict)}
    native = runs.get("native", {})
    external = runs.get("external", {})
    lines = [
        "# Rootfs writer benchmark",
        "",
        f"- Image: `{result['image']}`",
        f"- Platform: `{result['platform']}`",
        f"- Spore binary: `{result['spore_bin']}`",
        "",
        "| Writer | Status | Total | Conversion phases | Rootfs size | Index digest |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for writer in ("external", "native"):
        run = runs.get(writer, {})
        digest = str(run.get("index_digest") or "-")
        if len(digest) > 16:
            digest = digest[:16]
        lines.append(
            f"| `{writer}` | {run.get('status', '-')} | {fmt_ms(run.get('elapsed_ms'))} | "
            f"{fmt_ms(run.get('conversion_ms'))} | {run.get('rootfs_size', '-')} | `{digest}` |"
        )
    lines.extend([
        "",
        "| Phase | External | Native |",
        "|---|---:|---:|",
    ])
    native_phases = native.get("phases") if isinstance(native.get("phases"), dict) else {}
    external_phases = external.get("phases") if isinstance(external.get("phases"), dict) else {}
    for phase in CONVERSION_PHASES:
        lines.append(f"| `{phase}` | {fmt_ms(phase_ms(external_phases, phase))} | {fmt_ms(phase_ms(native_phases, phase))} |")
    lines.append("")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="public.ecr.aws/docker/library/node:22-alpine")
    parser.add_argument("--platform", default="linux/arm64")
    parser.add_argument("--output-dir", type=Path, default=Path("zig-cache/rootfs-writer-benchmarks"))
    parser.add_argument("--spore-bin", type=Path, default=repo_root() / "zig-out/bin/spore")
    parser.add_argument("--timeout-s", type=int, default=900)
    parser.add_argument("--no-build", dest="build", action="store_false")
    parser.set_defaults(build=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = repo_root()
    args.output_dir = args.output_dir.resolve()
    args.spore_bin = args.spore_bin.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.build:
        build_cmd = ["mise", "run", "build"] if shutil.which("mise") else ["zig", "build"]
        subprocess.run(build_cmd, cwd=root, check=True)
    if not args.spore_bin.is_file() or not os.access(args.spore_bin, os.X_OK):
        die(f"spore binary not executable: {args.spore_bin}")

    runs = [run_writer(args, writer, root) for writer in ("external", "native")]
    result = {
        "image": args.image,
        "platform": args.platform,
        "spore_bin": str(args.spore_bin),
        "runs": runs,
    }
    json_path = args.output_dir / "summary.json"
    md_path = args.output_dir / "summary.md"
    json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(result), encoding="utf-8")
    print(f"rootfs writer benchmark ok: json={json_path} markdown={md_path}")
    return 0 if all(run.get("success") for run in runs) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
