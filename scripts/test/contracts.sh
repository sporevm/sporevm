#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

python3 scripts/benchmark/parse-save-metrics.py --self-test
python3 scripts/benchmark/detect_regressions.py --self-test
bash scripts/benchmark/download-history.sh --self-test
python3 scripts/benchmark/named-restore-readiness.py --self-test
python3 scripts/benchmark/named-restore-readiness-test.py
bash scripts/ci/named-restore-release-inputs-test.sh
python3 scripts/spore-build-conformance.py --self-test-schema
