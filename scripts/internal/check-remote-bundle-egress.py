#!/usr/bin/env python3
import argparse
import json
import math
import sys


def non_negative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number") from exc
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError(f"{value!r} must be non-negative")
    return parsed


def ratio(numerator: int, denominator: int):
    if denominator == 0:
        return None
    return round(numerator / denominator, 6)


def origin_egress_bytes(metrics: dict) -> int:
    if "origin_egress_bytes" in metrics:
        return int(metrics["origin_egress_bytes"])
    if metrics.get("origin_mode", "").startswith("source-peer"):
        return int(metrics.get("source_peer_egress_bytes", 0))
    return int(metrics.get("total_destination_origin_bytes", 0))


def check_limit(name: str, value, limit) -> None:
    if limit is None:
        return
    if value is None:
        raise SystemExit(f"{name} is unavailable; cannot enforce limit {limit:g}")
    if value > limit:
        raise SystemExit(f"{name} {value:g} exceeds limit {limit:g}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check remote bundle fan-out egress metrics against optional ceilings.",
    )
    parser.add_argument("metrics_json")
    parser.add_argument(
        "--max-origin-egress-multiplier-vs-bundle",
        type=non_negative_float,
        default=None,
    )
    parser.add_argument(
        "--max-origin-egress-multiplier-vs-content",
        type=non_negative_float,
        default=None,
    )
    args = parser.parse_args()

    with open(args.metrics_json, "r", encoding="utf-8") as f:
        metrics = json.load(f)

    bundle_bytes = int(metrics.get("bundle_bytes", 0))
    unique_content_bytes = int(metrics.get("unique_content_bytes", 0))
    if unique_content_bytes == 0:
        unique_content_bytes = (
            int(metrics.get("unique_chunk_bytes", 0))
            + int(metrics.get("disk_object_bytes", 0))
            + int(metrics.get("rootfs_payload_bytes", 0))
        )
    egress_bytes = origin_egress_bytes(metrics)
    vs_bundle = ratio(egress_bytes, bundle_bytes)
    vs_content = ratio(egress_bytes, unique_content_bytes)

    check_limit(
        "origin egress multiplier vs bundle",
        vs_bundle,
        args.max_origin_egress_multiplier_vs_bundle,
    )
    check_limit(
        "origin egress multiplier vs unique content",
        vs_content,
        args.max_origin_egress_multiplier_vs_content,
    )

    source = metrics.get(
        "origin_egress_source",
        "source-peer" if metrics.get("origin_mode", "").startswith("source-peer") else "object-store",
    )
    print(
        "remote bundle egress gate ok: "
        f"source={source} "
        f"bytes={egress_bytes} "
        f"vs_bundle={vs_bundle} "
        f"vs_unique_content={vs_content}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
