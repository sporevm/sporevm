#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "smoke:monitor-jail skipped: unsupported host $(uname -s)"; exit 0 ;;
esac

SPOREVM_MONITOR_JAIL_SMOKE=1 \
  "${spore_bin}" monitor jail-smoke

echo "smoke:monitor-jail ok"
