#!/usr/bin/env python3
"""Publish merged benchmark trend data for the website."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


DEFAULT_BUCKET = "sporevm-benchmarks"
DEFAULT_PLATFORMS = ("macos", "linux-arm64")
DEFAULT_OUTPUT_DIR = Path("zig-cache/sporevm-benchmarks/published-site")
DEFAULT_MAX_RUNS = 500


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_exporter():
    path = Path(__file__).with_name("export-sporevm-benchmark-data.py")
    spec = importlib.util.spec_from_file_location("sporevm_benchmark_export", path)
    if spec is None or spec.loader is None:
        die(f"cannot load exporter: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


exporter = load_exporter()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"file not found: {path}")
    except json.JSONDecodeError as err:
        die(f"invalid JSON {path}: {err}")
    if not isinstance(value, dict):
        die(f"expected JSON object: {path}")
    return value


def run_aws(args: list[str], *, missing_ok: bool = False) -> bool:
    completed = subprocess.run(
        ["aws", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode == 0:
        if completed.stdout:
            print(completed.stdout, end="")
        return True
    message = completed.stderr.strip() or completed.stdout.strip()
    if missing_ok and ("404" in message or "NoSuchKey" in message or "Not Found" in message):
        return False
    print(message, file=sys.stderr)
    raise SystemExit(completed.returncode)


def s3_uri(bucket: str, *parts: str) -> str:
    key = "/".join(part.strip("/") for part in parts if part)
    return f"s3://{bucket}/{key}"


def load_history(path: Path | None) -> list[dict[str, object]]:
    if path is None or not path.exists():
        return []
    runs = read_json(path).get("runs")
    if not isinstance(runs, list):
        die(f"history runs must be an array: {path}")
    return [run for run in runs if isinstance(run, dict)]


def canonical_run(run: dict[str, object], *, build_number: str, commit: str, platform: str, build_url: str | None) -> dict[str, object]:
    copy = dict(run)
    short_commit = commit[:12]
    copy["run_id"] = f"{build_number}-{short_commit}-{platform}"
    copy["source"] = {
        "s3_prefix": f"builds/{build_number}/{commit}/{platform}/",
        "platform": platform,
    }
    copy["build"] = {
        "number": build_number,
        "url": build_url,
    }
    if isinstance(copy.get("commit"), dict):
        commit_info = dict(copy["commit"])
    else:
        commit_info = {}
    commit_info["sha"] = commit
    copy["commit"] = commit_info
    return copy


def merge_runs(history: list[dict[str, object]], new_runs: list[dict[str, object]], max_runs: int) -> list[dict[str, object]]:
    merged: dict[str, dict[str, object]] = {}
    for run in history:
        run_id = run.get("run_id")
        if run_id:
            merged[str(run_id)] = run
    for run in new_runs:
        run_id = run.get("run_id")
        if run_id:
            merged[str(run_id)] = run
    return sorted(merged.values(), key=exporter.run_sort_key)[-max_runs:]


def merged_data(history: list[dict[str, object]], new_runs: list[dict[str, object]], max_runs: int) -> dict[str, object]:
    runs = merge_runs(history, new_runs, max_runs)
    return {
        "version": exporter.EXPORT_VERSION,
        "suite": "sporevm",
        "updated_at": utc_now(),
        "runs": runs,
        "series": exporter.build_series(runs),
    }


def download_inputs(args: argparse.Namespace, work_dir: Path) -> tuple[Path | None, list[Path]]:
    history = work_dir / "history.json"
    if not run_aws(["s3", "cp", s3_uri(args.bucket, args.site_prefix, "data.json"), str(history), "--no-progress"], missing_ok=True):
        history = None

    platform_paths = []
    for platform in args.platforms:
        path = work_dir / f"{platform}.json"
        run_aws([
            "s3",
            "cp",
            s3_uri(args.bucket, args.builds_prefix, args.build_number, args.commit, platform, "site", "data.json"),
            str(path),
            "--no-progress",
        ])
        platform_paths.append(path)
    return history, platform_paths


def publish_outputs(args: argparse.Namespace, data: dict[str, object]) -> None:
    json_out = args.output_dir / "data.json"
    js_out = args.output_dir / "data.js"
    homepage_json_out = args.output_dir / "homepage-summary.json"
    homepage_js_out = args.output_dir / "homepage-summary.js"
    homepage = exporter.build_homepage_summary(data)
    exporter.write_json(json_out, data)
    exporter.write_js(js_out, data)
    exporter.write_json(homepage_json_out, homepage)
    exporter.write_js(homepage_js_out, homepage, exporter.HOMEPAGE_JS_GLOBAL)
    run_aws([
        "s3", "cp", str(json_out), s3_uri(args.bucket, args.site_prefix, "data.json"),
        "--no-progress", "--content-type", "application/json; charset=utf-8", "--cache-control", "public, max-age=60",
    ])
    run_aws([
        "s3", "cp", str(js_out), s3_uri(args.bucket, args.site_prefix, "data.js"),
        "--no-progress", "--content-type", "text/javascript; charset=utf-8", "--cache-control", "public, max-age=60",
    ])
    run_aws([
        "s3", "cp", str(homepage_json_out), s3_uri(args.bucket, args.site_prefix, "homepage-summary.json"),
        "--no-progress", "--content-type", "application/json; charset=utf-8", "--cache-control", "public, max-age=60",
    ])
    run_aws([
        "s3", "cp", str(homepage_js_out), s3_uri(args.bucket, args.site_prefix, "homepage-summary.js"),
        "--no-progress", "--content-type", "text/javascript; charset=utf-8", "--cache-control", "public, max-age=60",
    ])
    print(f"published benchmark site data: {s3_uri(args.bucket, args.site_prefix)} runs={len(data['runs'])} series={len(data['series'])}")


def publish(args: argparse.Namespace) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="sporevm-benchmark-site-") as tmp:
        history_path, platform_paths = download_inputs(args, Path(tmp))
        history = load_history(history_path)
        new_runs = []
        for platform, path in zip(args.platforms, platform_paths, strict=True):
            data = read_json(path)
            runs = data.get("runs")
            if not isinstance(runs, list) or not runs:
                die(f"no runs in {path}")
            for run in runs:
                if isinstance(run, dict):
                    new_runs.append(canonical_run(
                        run,
                        build_number=args.build_number,
                        commit=args.commit,
                        platform=platform,
                        build_url=os.environ.get("BUILDKITE_BUILD_URL"),
                    ))
        data = merged_data(history, new_runs, args.max_runs)
        publish_outputs(args, data)
        return data


def self_test() -> None:
    result = {
        "name": "cold_tti/sequential",
        "benchmark": "cold_tti",
        "mode": "sequential",
        "label": "Cold TTI / sequential",
        "unit": "ms",
        "lower_is_better": True,
        "value": 10.0,
        "success_rate": 1.0,
    }
    history = [{
        "run_id": "1-old-linux-arm64",
        "generated_at": "2026-06-25T00:00:00Z",
        "commit": {"sha": "old", "branch": "main"},
        "runner": {"queue": "sporevm-linux-arm64", "build_number": "1"},
        "results": [dict(result, value=20.0)],
    }]
    new_runs = [
        canonical_run({
            "run_id": "random-mac",
            "generated_at": "2026-06-26T00:00:00Z",
            "commit": {"branch": "main"},
            "runner": {"queue": "sporevm-mac", "build_number": "2"},
            "results": [dict(result, value=11.0)],
        }, build_number="2", commit="abcdef1234567890", platform="macos", build_url="https://example.test/build/2"),
        canonical_run({
            "run_id": "random-linux",
            "generated_at": "2026-06-26T00:01:00Z",
            "commit": {"branch": "main"},
            "runner": {"queue": "sporevm-linux-arm64", "build_number": "2"},
            "results": [dict(result, value=12.0)],
        }, build_number="2", commit="abcdef1234567890", platform="linux-arm64", build_url="https://example.test/build/2"),
    ]
    data = merged_data(history, new_runs, 500)
    assert len(data["runs"]) == 3
    assert {run["run_id"] for run in data["runs"]} >= {"2-abcdef123456-macos", "2-abcdef123456-linux-arm64"}
    assert len(data["series"]) == 2
    assert {series["name"] for series in data["series"]} == {
        "cold_tti/sequential@sporevm-mac",
        "cold_tti/sequential@sporevm-linux-arm64",
    }
    assert exporter.build_homepage_summary(data)["latest"] is None
    print("self-test ok")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", default=os.environ.get("SPOREVM_BENCHMARK_BUCKET", DEFAULT_BUCKET))
    parser.add_argument("--build-number", default=os.environ.get("BUILDKITE_BUILD_NUMBER"))
    parser.add_argument("--commit", default=os.environ.get("BUILDKITE_COMMIT"))
    parser.add_argument("--builds-prefix", default="builds")
    parser.add_argument("--site-prefix", default="site")
    parser.add_argument("--platforms", nargs="+", default=list(DEFAULT_PLATFORMS))
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--max-runs", type=int, default=DEFAULT_MAX_RUNS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    if not args.build_number:
        die("--build-number or BUILDKITE_BUILD_NUMBER is required")
    if not args.commit:
        die("--commit or BUILDKITE_COMMIT is required")
    if args.max_runs <= 0:
        die("--max-runs must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
    else:
        publish(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
