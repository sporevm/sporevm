#!/usr/bin/env python3
import argparse
import base64
import json
import os
import signal
import sys


def signum(name):
    name = name.upper()
    if not name.startswith("SIG"):
        name = "SIG" + name
    value = getattr(signal, name, None)
    if not isinstance(value, signal.Signals):
        raise argparse.ArgumentTypeError(f"unknown signal: {name}")
    return int(value)


parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--signal", type=signum, default=signal.SIGUSR1)
parser.add_argument("--event", default="stdout")
parser.add_argument("--contains", required=True)
parser.add_argument("--out", required=True)
args = parser.parse_args()
if not args.contains:
    parser.error("--contains must not be empty")

needle = args.contains.encode()
tail_len = len(needle) - 1
tail = b""
sent = False

with open(args.out, "w", encoding="utf-8") as out:
    for line in sys.stdin:
        out.write(line)
        out.flush()
        if sent:
            continue
        try:
            event = json.loads(line)
            payload = base64.b64decode(event.get("data_base64", ""))
        except Exception:
            continue
        if event.get("event") != args.event:
            continue
        haystack = tail + payload
        if needle in haystack:
            os.kill(args.pid, args.signal)
            sent = True
        tail = haystack[-tail_len:] if tail_len else b""

if not sent:
    print(f"marker not observed: {args.contains}", file=sys.stderr)
    sys.exit(1)
