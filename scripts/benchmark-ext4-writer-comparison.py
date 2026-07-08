#!/usr/bin/env python3
"""Compare SporeVM's ext4 writers against OSS tar-to-ext4 implementations.

Feeds the same flattened rootfs tar to:
  - spore rootfs import-tar with SPOREVM_EXT4_WRITER=native
  - spore rootfs import-tar with SPOREVM_EXT4_WRITER=external (mke2fs -d + debugfs)
  - hcsshim tar2ext4 (compactext4), default and -inline modes

Produce the input tar with, for example:
  docker create --platform linux/arm64 docker.io/buildkite/agent:3 /bin/true
  docker export <cid> -o buildkite-agent-3.tar

Install tar2ext4 with:
  GOBIN=<dir> go install github.com/Microsoft/hcsshim/cmd/tar2ext4@latest

Caveats recorded in the summary:
  - spore totals include BLAKE3 hashing, metadata, and local ref writes;
    conversion phases isolate the writer work.
  - spore emits a fixed-size padded image; compactext4 emits a compact image,
    so sizes are not directly comparable.
"""

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


PROFILE_RE = re.compile(r"spore rootfs profile: phase=(?P<phase>\S+) ms=(?P<ms>\d+)")

CONVERSION_PHASES = (
    "tree_merge",
    "layer_extract_staging",
    "rootfs_tree_finalize",
    "host_metadata_normalize",
    "ext4_size_scan",
    "ext4_create_empty",
    "mkfs_ext4",
    "debugfs_finalize",
    "native_ext4_emit",
)

E2FSCK_CANDIDATES = (
    "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck",
    "/usr/local/opt/e2fsprogs/sbin/e2fsck",
    "e2fsck",
)


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_timed(argv: list[str], env: dict[str, str], stdout: Path, stderr: Path, timeout_s: int) -> tuple[int, int]:
    started = time.monotonic_ns()
    with stdout.open("wb") as out, stderr.open("wb") as err:
        completed = subprocess.run(argv, env=env, stdout=out, stderr=err, timeout=timeout_s, check=False)
    return completed.returncode, (time.monotonic_ns() - started) // 1_000_000


def parse_profile(path: Path) -> dict[str, int]:
    phases: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PROFILE_RE.search(line)
        if match:
            phases[match.group("phase")] = int(match.group("ms"))
    return phases


def find_e2fsck() -> str | None:
    for candidate in E2FSCK_CANDIDATES:
        resolved = shutil.which(candidate) if "/" not in candidate else (candidate if Path(candidate).exists() else None)
        if resolved:
            return resolved
    return None


def fsck(image: Path, log: Path) -> str:
    e2fsck = find_e2fsck()
    if e2fsck is None:
        return "skipped (e2fsck not found)"
    with log.open("wb") as out:
        completed = subprocess.run([e2fsck, "-fn", str(image)], stdout=out, stderr=subprocess.STDOUT, check=False)
    # e2fsck exit 0 = clean; anything else means errors were found or usage failed.
    return "clean" if completed.returncode == 0 else f"exit {completed.returncode}"


def run_spore(args: argparse.Namespace, writer: str) -> dict[str, object]:
    workdir = args.output_dir / f"spore-{writer}"
    shutil.rmtree(workdir, ignore_errors=True)
    cache_dir = workdir / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    stdout = workdir / "stdout"
    stderr = workdir / "stderr"

    env = os.environ.copy()
    env["SPOREVM_EXT4_WRITER"] = writer
    env["SPOREVM_ROOTFS_BUILD_PROFILE"] = "1"
    env["SPOREVM_ROOTFS_CACHE_DIR"] = str(cache_dir)

    argv = [
        str(args.spore_bin),
        "rootfs",
        "import-tar",
        str(args.tar),
        "--ref",
        "local/ext4-writer-bench:comparison",
        "--rootfs-storage",
        "flat",
        "--platform",
        args.platform,
    ]
    status, elapsed_ms = run_timed(argv, env, stdout, stderr, args.timeout_s)
    phases = parse_profile(stderr)
    images = sorted(cache_dir.glob("*.ext4"))
    image = images[0] if images else None
    return {
        "tool": f"spore ({writer})",
        "status": status,
        "elapsed_ms": elapsed_ms,
        "conversion_ms": sum(phases.get(phase, 0) for phase in CONVERSION_PHASES),
        "phases": phases,
        "image": str(image) if image else None,
        "size": image.stat().st_size if image else None,
        "fsck": fsck(image, workdir / "e2fsck.log") if image and status == 0 else "-",
        "stderr": str(stderr),
    }


def run_tar2ext4(args: argparse.Namespace, label: str, extra: list[str]) -> dict[str, object]:
    workdir = args.output_dir / label
    shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir(parents=True, exist_ok=True)
    image = workdir / "rootfs.ext4"
    stdout = workdir / "stdout"
    stderr = workdir / "stderr"
    argv = [str(args.tar2ext4_bin), *extra, "-i", str(args.tar), "-o", str(image)]
    status, elapsed_ms = run_timed(argv, os.environ.copy(), stdout, stderr, args.timeout_s)
    return {
        "tool": label,
        "status": status,
        "elapsed_ms": elapsed_ms,
        "conversion_ms": elapsed_ms,
        "phases": {},
        "image": str(image) if image.exists() else None,
        "size": image.stat().st_size if image.exists() else None,
        "fsck": fsck(image, workdir / "e2fsck.log") if image.exists() and status == 0 else "-",
        "stderr": str(stderr),
    }


def fmt_ms(value: object) -> str:
    if not isinstance(value, int):
        return "-"
    if value >= 1000:
        return f"{value / 1000:.2f}s"
    return f"{value}ms"


def fmt_size(value: object) -> str:
    if not isinstance(value, int):
        return "-"
    return f"{value} ({value / (1 << 20):.0f} MiB)"


def render_markdown(args: argparse.Namespace, tar_size: int, runs: list[dict[str, object]]) -> str:
    lines = [
        "# ext4 writer comparison",
        "",
        f"- Input tar: `{args.tar}` ({tar_size} bytes, {tar_size / (1 << 20):.0f} MiB)",
        f"- Platform: `{args.platform}`",
        f"- Spore binary: `{args.spore_bin}`",
        f"- tar2ext4 binary: `{args.tar2ext4_bin}`",
        "",
        "| Tool | Status | Wall | Conversion | Output size | e2fsck -fn |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for run in runs:
        lines.append(
            f"| `{run['tool']}` | {run['status']} | {fmt_ms(run['elapsed_ms'])} | "
            f"{fmt_ms(run['conversion_ms'])} | {fmt_size(run['size'])} | {run['fsck']} |"
        )
    lines.extend([
        "",
        "Notes:",
        "- spore wall time includes BLAKE3 hashing, metadata, and ref writes;",
        "  the conversion column sums writer-only profile phases.",
        "- tar2ext4 has no separable phases; wall time is conversion.",
        "- spore emits a fixed-size padded image, compactext4 a compact one, so",
        "  output sizes measure allocation policy, not efficiency of the writer.",
        "",
    ])
    spore_runs = [run for run in runs if run["phases"]]
    if spore_runs:
        lines.extend(["| Phase | " + " | ".join(str(run["tool"]) for run in spore_runs) + " |",
                      "|---|" + "---:|" * len(spore_runs)])
        for phase in CONVERSION_PHASES:
            cells = [fmt_ms(run["phases"].get(phase)) for run in spore_runs]
            if all(cell == "-" for cell in cells):
                continue
            lines.append(f"| `{phase}` | " + " | ".join(cells) + " |")
        lines.append("")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tar", type=Path, required=True, help="flattened rootfs tar (e.g. docker export output)")
    parser.add_argument("--platform", default="linux/arm64")
    parser.add_argument("--output-dir", type=Path, default=Path("zig-cache/ext4-writer-comparison"))
    parser.add_argument("--spore-bin", type=Path, default=repo_root() / "zig-out/bin/spore")
    parser.add_argument("--tar2ext4-bin", type=Path, default=repo_root() / "zig-cache/bench-bin/tar2ext4")
    parser.add_argument("--timeout-s", type=int, default=900)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    args.tar = args.tar.resolve()
    args.output_dir = args.output_dir.resolve()
    args.spore_bin = args.spore_bin.resolve()
    args.tar2ext4_bin = args.tar2ext4_bin.resolve()
    if not args.tar.exists():
        die(f"input tar not found: {args.tar}")
    if not args.spore_bin.exists():
        die(f"spore binary not found: {args.spore_bin} (run `mise run build`)")
    if not args.tar2ext4_bin.exists():
        die(
            f"tar2ext4 not found: {args.tar2ext4_bin}\n"
            f"install with: GOBIN={args.tar2ext4_bin.parent} go install github.com/Microsoft/hcsshim/cmd/tar2ext4@latest"
        )
    args.output_dir.mkdir(parents=True, exist_ok=True)

    runs = [
        run_spore(args, "native"),
        run_spore(args, "external"),
        run_tar2ext4(args, "tar2ext4", []),
        run_tar2ext4(args, "tar2ext4-inline", ["-inline"]),
    ]

    summary = render_markdown(args, args.tar.stat().st_size, runs)
    summary_path = args.output_dir / "summary.md"
    summary_path.write_text(summary, encoding="utf-8")
    (args.output_dir / "summary.json").write_text(
        json.dumps({"tar": str(args.tar), "platform": args.platform, "runs": runs}, indent=2),
        encoding="utf-8",
    )
    print(summary)
    print(f"summary written to {summary_path}")
    return 0 if all(run["status"] == 0 for run in runs) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
