#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_spore_bin
smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-reporting"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-report"
export SPOREVM_RUNTIME_DIR="${runtime_dir}"
python3 "${repo_root}/test/smoke/run/free-page-reporting.py" "${spore_bin}" "$(infer_backend)" "${workdir}"
