#!/usr/bin/env python3
"""Render a Buildkite annotation for a SporeVM benchmark summary."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
import sys


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_summary(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"summary not found: {path}")
    except json.JSONDecodeError as err:
        die(f"invalid summary JSON {path}: {err}")
    if not isinstance(value, dict):
        die(f"summary must be a JSON object: {path}")
    return value


def as_dict(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def as_list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def text(value: object, fallback: str = "-") -> str:
    if value is None:
        return fallback
    if isinstance(value, (str, int, float, bool)):
        raw = str(value)
        return raw if raw else fallback
    return fallback


def short_image(value: object) -> str:
    raw = text(value)
    if raw == "-":
        return raw
    if "@sha256:" in raw:
        name, digest = raw.split("@sha256:", 1)
        return f"{name}@sha256:{digest[:12]}"
    return raw


def number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) else None


def ms(value: object) -> str:
    raw = number(value)
    if raw is None:
        return "-"
    if raw >= 1000:
        return f"{raw / 1000:.2f}s"
    if raw == round(raw):
        return f"{raw:.0f}ms"
    return f"{raw:.1f}ms"


def pct(value: object) -> str:
    raw = number(value)
    if raw is None:
        return "-"
    return f"{raw * 100:.0f}%"


def score(value: object) -> str:
    raw = number(value)
    if raw is None:
        return "-"
    return f"{raw:.1f}"


def md(value: object) -> str:
    return html.escape(text(value), quote=False)


def benchmark_label(benchmark: object) -> str:
    labels = {
        "cold_import": "Cold Import",
        "cold_tti": "Cold TTI",
        "warm_spore_tti": "Warm Spore TTI",
        "distribution_tti": "Distribution TTI",
        "writable_rootfs": "Writable Rootfs",
    }
    raw = text(benchmark)
    return labels.get(raw, raw.replace("_", " ").title())


def result_sort_key(result: object) -> tuple[str, str]:
    item = as_dict(result)
    order = {
        "cold_import": "0",
        "cold_tti": "1",
        "warm_spore_tti": "2",
        "distribution_tti": "3",
        "writable_rootfs": "4",
    }
    benchmark = text(item.get("benchmark"), "")
    return (order.get(benchmark, benchmark), text(item.get("mode"), ""))


def artifact_link(label: str, path: str) -> str:
    return f'<a href="artifact://{html.escape(path, quote=True)}">{html.escape(label)}</a>'


def render(summary: dict[str, object], summary_artifact_path: str) -> str:
    config = as_dict(summary.get("config"))
    results = sorted(as_list(summary.get("results")), key=result_sort_key)
    run_id = text(summary.get("run_id"))
    summary_path = summary_artifact_path
    run_artifact_root = str(Path(summary_path).parent / run_id) if run_id != "-" else str(Path(summary_path).parent)

    lines: list[str] = []
    lines.append("# SporeVM benchmark results")
    lines.append("")
    lines.append(
        " ".join(
            [
                f"**Profile:** `{md(config.get('profile'))}`",
                f"**Backend:** `{md(config.get('backend'))}`",
                f"**Memory:** `{md(config.get('memory'))}`",
                f"**Run:** `{md(run_id)}`",
            ]
        )
    )
    lines.append("")
    lines.append(f"**Image:** `{md(short_image(config.get('image')))}`")
    lines.append("")

    if results:
        lines.append("<table>")
        lines.append(
            "<thead><tr>"
            "<th>Benchmark</th><th>Mode</th><th>Runs</th><th>Success</th>"
            "<th>Median</th><th>p95</th><th>p99</th><th>Wall</th><th>First ready</th><th>Score</th>"
            "</tr></thead>"
        )
        lines.append("<tbody>")
        for raw_result in results:
            result = as_dict(raw_result)
            timings = as_dict(result.get("tti_ms"))
            lines.append(
                "<tr>"
                f"<td>{html.escape(benchmark_label(result.get('benchmark')))}</td>"
                f"<td><code>{md(result.get('mode'))}</code></td>"
                f"<td>{md(result.get('success_count'))}/{md(result.get('count'))}</td>"
                f"<td>{pct(result.get('success_rate'))}</td>"
                f"<td>{ms(timings.get('median'))}</td>"
                f"<td>{ms(timings.get('p95'))}</td>"
                f"<td>{ms(timings.get('p99'))}</td>"
                f"<td>{ms(result.get('wall_clock_ms'))}</td>"
                f"<td>{ms(result.get('time_to_first_ready_ms'))}</td>"
                f"<td>{score(result.get('composite_score'))}</td>"
                "</tr>"
            )
        lines.append("</tbody>")
        lines.append("</table>")
    else:
        lines.append("_No timed benchmark results were recorded._")

    lines.append("")
    links = [
        artifact_link("summary JSON", summary_path),
        artifact_link("raw JSONL", f"{run_artifact_root}/results.jsonl"),
        artifact_link("config", f"{run_artifact_root}/config.json"),
        artifact_link("logs", f"{run_artifact_root}/logs/"),
    ]
    lines.append("Artifacts: " + " | ".join(links))
    lines.append("")
    lines.append("_Lower timing values are better. Rootfs prewarm is outside timed TTI unless the run disables prewarming._")
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument(
        "--summary-artifact-path",
        default="zig-cache/sporevm-benchmarks/latest-summary.json",
        help="Artifact path to link for the latest summary JSON",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    print(render(load_summary(args.summary), args.summary_artifact_path), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
