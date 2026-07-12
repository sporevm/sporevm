#!/usr/bin/env bash
set -euo pipefail

signal_self_test="${SPOREVM_NAMED_RESTORE_SIGNAL_SELF_TEST:-}"
case "$(uname -s)/$(uname -m)" in
  Linux/aarch64|Linux/arm64)
    backend="kvm"
    asset="spore_Linux_arm64.tar.gz"
    asset_dir="spore_Linux_arm64"
    [[ "${signal_self_test}" == "1" || -c /dev/kvm ]] || {
      echo "named restore readiness benchmark requires /dev/kvm" >&2
      exit 1
    }
    ;;
  Darwin/arm64)
    backend="hvf"
    asset="spore_Darwin_arm64.tar.gz"
    asset_dir="spore_Darwin_arm64"
    ;;
  *)
    if [[ "${signal_self_test}" == "1" ]]; then
      backend="self-test"
      asset="spore_Linux_arm64.tar.gz"
      asset_dir="spore_Linux_arm64"
    else
      echo "named restore readiness benchmark requires Linux ARM64/KVM or macOS ARM64/HVF" >&2
      exit 1
    fi
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"
source "${repo_root}/scripts/ci/named-restore-release-inputs.sh"

baseline_version="${SPOREVM_NAMED_RESTORE_BASELINE_VERSION:-v0.12.0}"
load_pinned_release_identity "${baseline_version}" "${asset}"
require_pinned_reassertion "${SPOREVM_NAMED_RESTORE_BASELINE_SHA256:-}" "${pinned_archive_sha256}" "baseline archive SHA-256"
require_pinned_reassertion "${SPOREVM_NAMED_RESTORE_CHECKSUMS_SHA256:-}" "${pinned_checksums_sha256}" "baseline checksums SHA-256"
image="${SPOREVM_NAMED_RESTORE_IMAGE:-docker.io/library/node@sha256:d51cff3fa44ab8a368ae8708ae974480165be1b699b19527b7c0d2523433b271}"
require_digest_image "${image}"
memory="${SPOREVM_NAMED_RESTORE_MEMORY:-1024mb}"
iterations="${SPOREVM_NAMED_RESTORE_ITERATIONS:-5}"
repeated_execs="${SPOREVM_NAMED_RESTORE_REPEATED_EXECS:-5}"
timeout="${SPOREVM_NAMED_RESTORE_TIMEOUT_SECONDS:-120}"
output_dir="${SPOREVM_NAMED_RESTORE_OUTPUT_DIR:-zig-cache/named-restore-readiness}"
unsupported_fs_dir="${SPOREVM_NAMED_RESTORE_UNSUPPORTED_FS_DIR:-/dev/shm}"
expected_commit="${SPOREVM_NAMED_RESTORE_EXPECTED_COMMIT:-${BUILDKITE_COMMIT:-$(git rev-parse HEAD)}}"
release_url="https://github.com/sporevm/sporevm/releases/download/${baseline_version}"

scratch_root="$(named_restore_scratch_root "${backend}" "${repo_root}")"
[[ "${scratch_root}" == /* ]] || {
  echo "named-restore release scratch must be absolute: ${scratch_root}" >&2
  exit 1
}
mkdir -p "${output_dir}" "${scratch_root}"
if [[ "${signal_self_test}" != "1" ]]; then
  require_named_restore_scratch_filesystem "${backend}" "${scratch_root}"
fi
workdir="$(mktemp -d "${scratch_root%/}/nr.XXXXXX")"
child_pid=""
forwarded_signals=0

cleanup() {
  chmod -R u+w "${workdir}" 2>/dev/null || true
  rm -rf "${workdir}"
}

forward_signal() {
  local signal_name="$1"
  forwarded_signals=$((forwarded_signals + 1))
  if [[ -n "${child_pid}" ]]; then
    kill -s "${signal_name}" "${child_pid}" 2>/dev/null || true
  elif [[ "${signal_name}" == "INT" ]]; then
    exit 130
  else
    exit 143
  fi
}

wait_for_exact_child() {
  local pid="$1"
  local observed_signals="${forwarded_signals}"
  local status=0
  local last_status=0

  while true; do
    if wait "${pid}"; then
      status=0
    else
      status=$?
    fi
    if [[ "${status}" -ne 127 ]]; then
      last_status="${status}"
    fi
    if [[ "${forwarded_signals}" -ne "${observed_signals}" ]]; then
      observed_signals="${forwarded_signals}"
      continue
    fi
    if [[ "${status}" -eq 127 ]]; then
      return "${last_status}"
    fi
    return "${status}"
  done
}

trap cleanup EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

if [[ "${signal_self_test}" == "1" ]]; then
  marker_dir="${SPOREVM_NAMED_RESTORE_SIGNAL_SELF_TEST_DIR:?signal self-test marker directory is required}"
  test_child="${SPOREVM_NAMED_RESTORE_SIGNAL_TEST_CHILD:?signal self-test child is required}"
  mkdir -p "${marker_dir}"
  printf '%s\n' "${workdir}" > "${marker_dir}/wrapper-workdir"
  python3 "${test_child}" --wrapper-child "${marker_dir}" "${workdir}" &
  child_pid=$!
  if wait_for_exact_child "${child_pid}"; then
    status=0
  else
    status=$?
  fi
  child_pid=""
  exit "${status}"
fi

mise run build:release
current_bin="${repo_root}/zig-out/bin/spore"

archive="${workdir}/${asset}"
checksums="${workdir}/checksums.txt"
curl --fail --location --silent --show-error "${release_url}/checksums.txt" --output "${checksums}"
curl --fail --location --silent --show-error "${release_url}/${asset}" --output "${archive}"

verify_pinned_release_assets \
  "${checksums}" "${archive}" "${asset}" "${pinned_checksums_sha256}" "${pinned_archive_sha256}"
tar -xzf "${archive}" -C "${workdir}"
baseline_bin="${workdir}/${asset_dir}/bin/spore"
[[ -x "${baseline_bin}" ]] || {
  echo "baseline archive does not contain ${asset_dir}/bin/spore" >&2
  exit 1
}

PYTHONPYCACHEPREFIX="${workdir}/pycache" python3 scripts/benchmark/named-restore-readiness.py \
  --matrix \
  --candidate-bin "${current_bin}" \
  --baseline-bin "${baseline_bin}" \
  --baseline-version "${baseline_version}" \
  --baseline-archive "${archive}" \
  --baseline-checksums "${checksums}" \
  --baseline-archive-sha256 "${pinned_archive_sha256}" \
  --baseline-checksums-sha256 "${pinned_checksums_sha256}" \
  --baseline-archive-member "${pinned_archive_member}" \
  --baseline-release-url "${release_url}" \
  --expected-commit "${expected_commit}" \
  --backend "${backend}" \
  --image "${image}" \
  --memory "${memory}" \
  --iterations "${iterations}" \
  --repeated-execs "${repeated_execs}" \
  --timeout "${timeout}" \
  --output-dir "${output_dir}" \
  --scratch-dir "${workdir}/m" \
  --unsupported-fs-dir "${unsupported_fs_dir}" &
child_pid=$!
if wait_for_exact_child "${child_pid}"; then
  status=0
else
  status=$?
fi
child_pid=""
exit "${status}"
