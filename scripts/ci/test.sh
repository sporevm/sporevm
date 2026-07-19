#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

zig build test --summary all
if [[ "$(uname -s)" == "Linux" ]]; then
  zig fmt --check build.zig src
fi
scripts/test/contracts.sh
