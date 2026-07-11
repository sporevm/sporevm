#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)/$(uname -m)" != "Linux/aarch64" ]]; then
  echo "named restore readiness benchmark requires Linux/aarch64" >&2
  exit 1
fi
[[ -c /dev/kvm ]] || {
  echo "named restore readiness benchmark requires /dev/kvm" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

baseline_version="${SPOREVM_NAMED_RESTORE_BASELINE_VERSION:-v0.11.1}"
image="${SPOREVM_NAMED_RESTORE_IMAGE:-public.ecr.aws/docker/library/node:22-alpine}"
memory="${SPOREVM_NAMED_RESTORE_MEMORY:-512mb}"
iterations="${SPOREVM_NAMED_RESTORE_ITERATIONS:-5}"
repeated_execs="${SPOREVM_NAMED_RESTORE_REPEATED_EXECS:-5}"
output_dir="${SPOREVM_NAMED_RESTORE_OUTPUT_DIR:-zig-cache/named-restore-readiness}"
scratch_root="${SPOREVM_BENCHMARK_SCRATCH_ROOT:-/tmp}"
if [[ -d /var/tmp/nvme && -w /var/tmp/nvme && -z "${SPOREVM_BENCHMARK_SCRATCH_ROOT:-}" ]]; then
  scratch_root="/var/tmp/nvme"
fi

mkdir -p "${output_dir}" "${scratch_root}"
workdir="$(mktemp -d "${scratch_root%/}/sporevm-named-restore.XXXXXX")"
cleanup() {
  chmod -R u+w "${workdir}" 2>/dev/null || true
  rm -rf "${workdir}"
}
trap cleanup EXIT

mise run build:release
current_bin="${repo_root}/zig-out/bin/spore"

archive="${workdir}/baseline.tar.gz"
curl --fail --location --silent --show-error \
  "https://github.com/sporevm/sporevm/releases/download/${baseline_version}/spore_Linux_arm64.tar.gz" \
  --output "${archive}"
tar -xzf "${archive}" -C "${workdir}"
baseline_bin="${workdir}/spore_Linux_arm64/bin/spore"

export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
capture_runtime="${workdir}/capture-runtime"
mkdir -m 0700 "${capture_runtime}"
export SPOREVM_RUNTIME_DIR="${capture_runtime}"
parent="${workdir}/immutable-parent.spore"
"${baseline_bin}" run \
  --backend kvm \
  --image "${image}" \
  --memory "${memory}" \
  --save "${parent}" \
  -- /bin/true
chmod -R a-w "${parent}"

scripts/benchmark/named-restore-readiness.py \
  --spore-dir "${parent}" \
  --spore-bin "${baseline_bin}" \
  --backend kvm \
  --iterations "${iterations}" \
  --repeated-execs "${repeated_execs}" \
  --runtime-dir "${capture_runtime}" \
  --output "${output_dir}/baseline-${baseline_version}.jsonl" \
  --include-run-from \
  --no-build

scripts/benchmark/named-restore-readiness.py \
  --spore-dir "${parent}" \
  --spore-bin "${current_bin}" \
  --backend kvm \
  --iterations "${iterations}" \
  --repeated-execs "${repeated_execs}" \
  --runtime-dir "${capture_runtime}" \
  --output "${output_dir}/current.jsonl" \
  --include-run-from \
  --no-build

python3 - "${output_dir}/baseline-${baseline_version}.jsonl" "${output_dir}/current.jsonl" <<'PY'
import json
import statistics
import sys

expected_sources = ("eager_chunks", "local_backing")
for path, expected_source in zip(sys.argv[1:], expected_sources, strict=True):
    rows = [json.loads(line) for line in open(path, encoding="utf-8")]
    print(path)
    sources = sorted({row.get("restore_source") for row in rows if row.get("restore_source")})
    print(f"  restore_source: {','.join(sources) if sources else 'unknown'}")
    if sources != [expected_source]:
        raise SystemExit(f"{path}: expected restore_source={expected_source}, got {sources or ['unknown']}")
    for field in ("run_from_noop_ms", "restore_return_ms", "exec_ready_ms", "exec_ready_wait_ms", "backend_memory_ms", "backend_state_ms", "backend_pre_run_ms", "first_noop_exec_ms", "repeated_exec_median_ms"):
        values = [row[field] for row in rows if isinstance(row.get(field), (int, float))]
        print(f"  {field}: median={statistics.median(values):.3f}ms n={len(values)}" if values else f"  {field}: n=0")
PY
