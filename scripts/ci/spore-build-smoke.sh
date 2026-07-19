#!/usr/bin/env bash
set -euo pipefail

: "${BUILDKITE_JOB_ID:?BUILDKITE_JOB_ID is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

smoke_root="zig-cache/spore-build-run-smoke/${BUILDKITE_JOB_ID}"
smoke_log="${smoke_root}/smoke.log"
mkdir -p "${smoke_root}"
if zig build spore-build-run-smoke >"${smoke_log}" 2>&1; then
  tail -n 1 "${smoke_log}"
else
  status=$?
  tail -n 200 "${smoke_log}"
  exit "${status}"
fi
