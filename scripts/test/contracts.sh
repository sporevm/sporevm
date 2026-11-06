#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

python3 scripts/benchmark/parse-save-metrics.py --self-test
python3 scripts/benchmark/suite.py --self-test
python3 scripts/spore-build-conformance.py --self-test-schema
python3 scripts/image-worker-conformance.py self-test
