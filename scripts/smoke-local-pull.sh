#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

infer_backend() {
  if [[ -n "${SPORE_BACKEND:-}" ]]; then
    echo "${SPORE_BACKEND}"
    return
  fi

  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "hvf" ;;
    Linux-aarch64|Linux-arm64) echo "kvm" ;;
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
  esac
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)[sys.argv[2]])
PY
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

count="${SPORE_SMOKE_LOCAL_PULL_COUNT:-3}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_LOCAL_PULL_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_LOCAL_PULL_COUNT must be greater than zero"

image_ref="${SPORE_SMOKE_ROOTFS_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_SMOKE_ROOTFS_PLATFORM:-linux/arm64}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-local-pull.XXXXXX")"
run_pid=""
watchdog_pid=""
cleanup() {
  if [[ -n "${run_pid}" ]]; then
    kill -TERM "${run_pid}" >/dev/null 2>&1 || true
    wait "${run_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${watchdog_pid}" ]]; then
    kill "${watchdog_pid}" >/dev/null 2>&1 || true
    wait "${watchdog_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

pack_rootfs_cache="${workdir}/pack-rootfs-cache"
pull_rootfs_cache="${workdir}/pull-rootfs-cache"
bundle_cache="${workdir}/bundle-cache"
capture_dir="${workdir}/ruby-counter.spore"
fork_dir="${workdir}/children"
bundle_dir="${workdir}/ruby.bundle"
pulled_dir="${workdir}/pulled"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
fanout_stdout="${workdir}/fanout.stdout"
fanout_stderr="${workdir}/fanout.stderr"

mkdir -p "${pack_rootfs_cache}" "${pull_rootfs_cache}" "${bundle_cache}" "${pulled_dir}"

resolved_image_ref="$(SPOREVM_ROOTFS_CACHE_DIR="${pack_rootfs_cache}" "${spore_bin}" rootfs resolve "${image_ref}" --platform "${platform}")"
printf 'rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

SPOREVM_ROOTFS_CACHE_DIR="${pack_rootfs_cache}" "${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --capture "${capture_dir}" \
  --capture-on USR1 \
  -- /usr/local/bin/ruby \
  -e 'def spore_env; File.readlines("/run/sporevm/env").to_h { |l| l.strip.split("=", 2) }; rescue; {}; end' \
  -e 'STDOUT.sync = true; puts "spore run ready"; printed = false; i = 0' \
  -e 'loop do' \
  -e 'e = spore_env; if !printed && e["SPORE_PARALLEL_JOB"] && e["SPORE_PARALLEL_JOB_COUNT"]' \
  -e 'puts "spore parallel job #{e["SPORE_PARALLEL_JOB"]}/#{e["SPORE_PARALLEL_JOB_COUNT"]}"; printed = true; end' \
  -e 'puts "ruby counter #{i}"; i += 1; sleep 1; end' \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_counter=0
for _ in $(seq 1 "${SPORE_SMOKE_ROOTFS_CAPTURE_POLLS:-600}"); do
  if grep -Eaq 'ruby counter [0-9]+' "${run_stdout}"; then
    seen_counter=1
    break
  fi
  if ! kill -0 "${run_pid}" >/dev/null 2>&1; then
    break
  fi
  sleep "${SPORE_SMOKE_ROOTFS_CAPTURE_POLL_INTERVAL:-0.5}"
done
if [[ "${seen_counter}" != "1" ]]; then
  tail -80 "${run_stdout}" >&2 || true
  tail -160 "${run_stderr}" >&2 || true
  die "local pull smoke did not see the fresh Ruby counter"
fi

sleep "${SPORE_SMOKE_ROOTFS_CAPTURE_SETTLE_SECONDS:-1}"
kill -USR1 "${run_pid}"

(
  sleep "${SPORE_SMOKE_CAPTURE_TIMEOUT_SECONDS:-30}"
  kill -TERM "${run_pid}" >/dev/null 2>&1 || true
) &
watchdog_pid="$!"

set +e
wait "${run_pid}"
run_rc="$?"
set -e
run_pid=""
kill "${watchdog_pid}" >/dev/null 2>&1 || true
wait "${watchdog_pid}" >/dev/null 2>&1 || true
watchdog_pid=""

if [[ "${run_rc}" != "0" ]]; then
  cat "${run_stdout}" >&2 || true
  cat "${run_stderr}" >&2 || true
  die "spore run capture exited ${run_rc}, expected 0"
fi
[[ -f "${capture_dir}/manifest.json" ]] || die "capture did not write ${capture_dir}/manifest.json"
grep -Fq '"rootfs"' "${capture_dir}/manifest.json" || die "capture manifest did not record rootfs metadata"

"${spore_bin}" fork "${capture_dir}" --count "${count}" --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"
SPOREVM_ROOTFS_CACHE_DIR="${pack_rootfs_cache}" "${spore_bin}" pack "${capture_dir}" --children "${fork_dir}" --out "${bundle_dir}" >"${workdir}/pack.json"

for i in $(seq 0 $((count - 1))); do
  child_name="$(printf '%06d' "${i}")"
  pull_json="${workdir}/pull-${child_name}.json"
  SPOREVM_ROOTFS_CACHE_DIR="${pull_rootfs_cache}" \
    SPOREVM_BUNDLE_CACHE_DIR="${bundle_cache}" \
    "${spore_bin}" pull "file://${bundle_dir}" --child "${i}" --out "${pulled_dir}/${child_name}" >"${pull_json}"
  selected_child="$(json_field "${pull_json}" selected_child)"
  [[ "${selected_child}" == "${child_name}" ]] || die "pull selected ${selected_child}, expected ${child_name}"
  chunk_bytes_fetched="$(json_field "${pull_json}" chunk_bytes_fetched)"
  rootfs_bytes_fetched="$(json_field "${pull_json}" rootfs_bytes_fetched)"
  rootfs_cache_hits="$(json_field "${pull_json}" rootfs_cache_hit_count)"
  rootfs_cache_misses="$(json_field "${pull_json}" rootfs_cache_miss_count)"
  if [[ "${i}" == "0" ]]; then
    [[ "${chunk_bytes_fetched}" -gt 0 ]] || die "first pull did not fetch chunk bytes"
    [[ "${rootfs_bytes_fetched}" -gt 0 ]] || die "first pull did not populate the rootfs cache"
    [[ "${rootfs_cache_misses}" -gt 0 ]] || die "first pull did not report a rootfs cache miss"
  fi
  if [[ "${i}" -gt 0 ]]; then
    cache_hits="$(json_field "${pull_json}" cache_hit_count)"
    [[ "${cache_hits}" -gt 0 ]] || die "pull ${child_name} did not reuse the local chunk cache"
    [[ "${chunk_bytes_fetched}" == "0" ]] || die "pull ${child_name} fetched ${chunk_bytes_fetched} chunk bytes from the bundle"
    [[ "${rootfs_bytes_fetched}" == "0" ]] || die "pull ${child_name} fetched ${rootfs_bytes_fetched} rootfs bytes"
    [[ "${rootfs_cache_hits}" -gt 0 ]] || die "pull ${child_name} did not report a rootfs cache hit"
    [[ "${rootfs_cache_misses}" == "0" ]] || die "pull ${child_name} reported ${rootfs_cache_misses} rootfs cache misses"
  fi
done

set +e
SPOREVM_ROOTFS_CACHE_DIR="${pull_rootfs_cache}" "${spore_bin}" fanout --backend "${backend}" "${pulled_dir}" --parallel --for "${SPORE_SMOKE_LOCAL_PULL_FANOUT_DURATION:-20s}" \
  >"${fanout_stdout}" 2>"${fanout_stderr}"
fanout_rc="$?"
set -e

if [[ "${fanout_rc}" != "0" ]]; then
  cat "${fanout_stdout}" >&2 || true
  cat "${fanout_stderr}" >&2 || true
  die "spore fanout from pulled children exited ${fanout_rc}, expected 0"
fi

for i in $(seq 0 $((count - 1))); do
  child_name="$(printf '%06d' "${i}")"
  if ! grep -Eaq "^\[${child_name}\] spore parallel job ${i}/${count}" "${fanout_stdout}"; then
    tail -160 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "pulled child ${child_name} did not report SPORE_PARALLEL_JOB=${i} SPORE_PARALLEL_JOB_COUNT=${count}"
  fi
  if ! grep -Eaq "^\[${child_name}\] .*ruby counter [0-9]+" "${fanout_stdout}"; then
    tail -120 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "pulled child ${child_name} did not stream a prefixed resumed Ruby counter line"
  fi
done

echo "smoke:local-pull ok backend=${backend} count=${count} image=${resolved_image_ref}"
