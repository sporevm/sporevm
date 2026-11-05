#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

SPOREVM_MONITOR_JAIL_SMOKE=1 \
  "${spore_bin}" monitor jail-smoke

echo "smoke:monitor-jail ok"
