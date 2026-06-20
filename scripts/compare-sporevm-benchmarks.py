#!/usr/bin/env python3
"""Compare two SporeVM benchmark summary JSON files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def load_summary(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"error: summary not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as err:
        print(f"error: invalid summary JSON {path}: {err}", file=sys.stderr)
        raise SystemExit(2)


def index_results(summary: dict) -> dict[tuple[str, str], dict]:
    out: dict[tuple[str, str], dict] = {}
    for result in summary.get("results", []):
        key = (str(result.get("benchmark")), str(result.get("mode")))
        out[key] = result
    return out


def metric(result: dict, name: str) -> float | None:
    value = result.get("tti_ms", {}).get(name)
    if isinstance(value, (int, float)):
        return float(value)
    return None


def pct_delta(old: float, new: float) -> float | None:
    if old == 0:
        return None
    return ((new - old) / old) * 100.0


def compare(args: argparse.Namespace) -> int:
    baseline = index_results(load_summary(args.baseline))
    candidate = index_results(load_summary(args.candidate))
    wanted = set()
    if args.only:
        for item in args.only.split(","):
            item = item.strip()
            if not item:
                continue
            try:
                benchmark, mode = item.split("/", 1)
            except ValueError:
                print(f"error: --only entries must be benchmark/mode, got {item}", file=sys.stderr)
                return 2
            wanted.add((benchmark, mode))

    failures: list[str] = []
    rows: list[str] = []
    keys = sorted(set(baseline) & set(candidate))
    if wanted:
        keys = [key for key in keys if key in wanted]
    for key in keys:
        base = baseline[key]
        cand = candidate[key]
        label = f"{key[0]}/{key[1]}"
        base_success = float(base.get("success_rate", 0.0))
        cand_success = float(cand.get("success_rate", 0.0))
        success_drop = base_success - cand_success
        if success_drop > args.max_success_rate_drop:
            failures.append(
                f"{label} success rate dropped from {base_success:.3f} to {cand_success:.3f}"
            )
        for stat, max_pct in (("median", args.max_median_regression_pct), ("p95", args.max_p95_regression_pct), ("p99", args.max_p99_regression_pct)):
            old = metric(base, stat)
            new = metric(cand, stat)
            if old is None or new is None:
                continue
            delta = new - old
            percent = pct_delta(old, new)
            rows.append(
                f"{label:32s} {stat:6s} baseline={old:9.1f} candidate={new:9.1f} "
                f"delta={delta:8.1f} pct={percent if percent is not None else 0:7.1f}%"
            )
            if delta < args.min_regression_ms:
                continue
            if percent is not None and percent > max_pct:
                failures.append(
                    f"{label} {stat} regressed by {percent:.1f}% ({old:.1f}ms -> {new:.1f}ms)"
                )

    missing = sorted(set(baseline) - set(candidate))
    if wanted:
        missing = [key for key in missing if key in wanted]
    if missing and not args.allow_missing:
        for key in missing:
            failures.append(f"candidate missing result {key[0]}/{key[1]}")

    if rows:
        print("\n".join(rows))
    else:
        print("no overlapping benchmark results to compare")
    if failures:
        print("\nregressions:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("benchmark comparison ok")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-median-regression-pct", type=float, default=20.0)
    parser.add_argument("--max-p95-regression-pct", type=float, default=30.0)
    parser.add_argument("--max-p99-regression-pct", type=float, default=40.0)
    parser.add_argument("--min-regression-ms", type=float, default=50.0)
    parser.add_argument("--max-success-rate-drop", type=float, default=0.02)
    parser.add_argument("--only", help="Comma-separated benchmark/mode list")
    parser.add_argument("--allow-missing", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    return compare(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
