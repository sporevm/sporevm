#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/demo-ruby-rootfs-fanout.sh [options]

Build or reuse a Ruby OCI rootfs, run a counter in it, capture the VM, fork the
captured spore, then resume children in parallel with interleaved terminal
output.

Options:
  --count N          Number of child spores to resume (default: 4)
  --image REF        Ruby OCI image ref (default: docker.io/library/ruby:3.3-alpine)
  --backend NAME     Backend to use: hvf or kvm (default: infer from host)
  --workdir DIR      Directory for logs and spores (default: mktemp)
  --spore-bin PATH   Prebuilt spore CLI (default: zig-out/bin/spore)
  --no-build         Do not run `mise run build` first
  -h, --help         Show this help

Examples:
  scripts/demo-ruby-rootfs-fanout.sh
  scripts/demo-ruby-rootfs-fanout.sh --count 10
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

infer_backend() {
  if [[ -n "${SPORE_BACKEND:-}" ]]; then
    echo "${SPORE_BACKEND}"
    return
  fi

  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "hvf" ;;
    Linux-aarch64|Linux-arm64) echo "kvm" ;;
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set --backend hvf or --backend kvm" ;;
  esac
}

valid_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

phase() {
  printf '\n==> %s\n' "$*"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
count="${SPORE_DEMO_FANOUT_COUNT:-4}"
image_ref="${SPORE_DEMO_RUBY_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_DEMO_PLATFORM:-linux/arm64}"
backend=""
workdir=""
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
build=1

while (($#)); do
  case "$1" in
    --count)
      need_value "$1" "${2-}"
      count="$2"
      shift 2
      ;;
    --image)
      need_value "$1" "${2-}"
      image_ref="$2"
      shift 2
      ;;
    --backend)
      need_value "$1" "${2-}"
      backend="$2"
      shift 2
      ;;
    --workdir)
      need_value "$1" "${2-}"
      workdir="$2"
      shift 2
      ;;
    --spore-bin)
      need_value "$1" "${2-}"
      spore_bin="$2"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

valid_positive_int "${count}" || die "--count must be a positive integer"
if [[ -z "${backend}" ]]; then
  backend="$(infer_backend)"
fi
case "${backend}" in
  hvf|kvm) ;;
  *) die "--backend must be hvf or kvm" ;;
esac

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-ruby-fanout-demo.XXXXXX")"
else
  mkdir -p "${workdir}"
fi

run_pid=""
watchdog_pid=""
stream_pids=()
resume_pids=()
cleanup() {
  if [[ -n "${run_pid}" ]]; then
    kill -TERM "${run_pid}" >/dev/null 2>&1 || true
    wait "${run_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${watchdog_pid}" ]]; then
    kill "${watchdog_pid}" >/dev/null 2>&1 || true
    wait "${watchdog_pid}" >/dev/null 2>&1 || true
  fi
  for pid in "${resume_pids[@]}"; do
    kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
  sleep 0.2
  for pid in "${resume_pids[@]}"; do
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  done
  for pid in "${stream_pids[@]}"; do
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

phase "workspace"
printf 'repo:    %s\n' "${repo_root}"
printf 'workdir: %s\n' "${workdir}"
printf 'backend: %s\n' "${backend}"
printf 'count:   %s\n' "${count}"

if [[ "${build}" == "1" ]]; then
  phase "build spore"
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise run build)
  else
    (cd "${repo_root}" && zig build)
  fi
fi
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

phase "resolve Ruby rootfs"
resolved_image_ref="$("${spore_bin}" rootfs resolve "${image_ref}" --platform "${platform}")"
printf 'image:   %s\n' "${image_ref}"
printf 'resolved:%s\n' " ${resolved_image_ref}"

capture_dir="${workdir}/ruby-counter.spore"
fork_dir="${workdir}/ruby-counter.children"
run_stdout="${workdir}/parent.stdout"
run_stderr="${workdir}/parent.stderr"

phase "run Ruby counter and capture"
: >"${run_stdout}"
: >"${run_stderr}"
tail -n +1 -f "${run_stdout}" > >(awk '{ print "[parent] " $0; fflush() }') &
stream_pids+=("$!")

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --capture-on-abort "${capture_dir}" \
  --capture-signal USR1 \
  -- /usr/local/bin/ruby -e 'STDOUT.sync = true; puts "spore run ready"; i = 0; loop { puts "ruby counter #{i}"; i += 1; sleep 1 }' \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_counter=0
for _ in $(seq 1 "${SPORE_DEMO_CAPTURE_POLLS:-600}"); do
  if grep -Eaq 'ruby counter [0-9]+' "${run_stdout}"; then
    seen_counter=1
    break
  fi
  if ! kill -0 "${run_pid}" >/dev/null 2>&1; then
    break
  fi
  sleep "${SPORE_DEMO_CAPTURE_POLL_INTERVAL:-0.5}"
done
if [[ "${seen_counter}" != "1" ]]; then
  tail -80 "${run_stdout}" >&2 || true
  tail -160 "${run_stderr}" >&2 || true
  die "Ruby counter did not start"
fi

sleep "${SPORE_DEMO_CAPTURE_SETTLE_SECONDS:-1}"
printf 'capturing with USR1...\n'
kill -USR1 "${run_pid}"

(
  sleep "${SPORE_DEMO_CAPTURE_TIMEOUT_SECONDS:-30}"
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
rootfs_digest="$(python3 - "${capture_dir}/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    manifest = json.load(f)

rootfs = manifest.get("rootfs") or {}
artifact = rootfs.get("artifact") or {}
digest = artifact.get("digest")
if not isinstance(digest, str):
    raise SystemExit("manifest did not record a rootfs digest")
print(digest)
PY
)"
printf 'captured: %s\n' "${capture_dir}"
printf 'rootfs:   %s\n' "${rootfs_digest}"

phase "fork ${count} child spores"
"${spore_bin}" fork "${capture_dir}" --count "${count}" --out "${fork_dir}" \
  >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"

children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(find "${fork_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#children[@]}" == "${count}" ]] || die "expected ${count} child spores, found ${#children[@]}"
printf 'children: %s\n' "${fork_dir}"

phase "resume children in parallel"
resume_logs=()
seen=()
for i in "${!children[@]}"; do
  child_name="$(basename "${children[$i]}")"
  log="${workdir}/resume-${child_name}.log"
  resume_logs+=("${log}")
  seen+=("0")
  : >"${log}"
  "${spore_bin}" resume --backend "${backend}" "${children[$i]}" >"${log}" 2>&1 &
  resume_pids+=("$!")
  tail -n +1 -f "${log}" > >(awk -v prefix="[child ${child_name}] " '{ print prefix $0; fflush() }') &
  stream_pids+=("$!")
done

for _ in $(seq 1 "${SPORE_DEMO_RESUME_POLLS:-240}"); do
  all_seen=1
  for i in "${!resume_logs[@]}"; do
    if [[ "${seen[$i]}" == "1" ]]; then
      continue
    fi
    if grep -Eaq 'ruby counter [0-9]+' "${resume_logs[$i]}"; then
      seen[$i]=1
    else
      all_seen=0
    fi
  done
  if [[ "${all_seen}" == "1" ]]; then
    break
  fi
  sleep "${SPORE_DEMO_RESUME_POLL_INTERVAL:-0.25}"
done

for i in "${!resume_logs[@]}"; do
  if [[ "${seen[$i]}" != "1" ]]; then
    tail -120 "${resume_logs[$i]}" >&2 || true
    die "child ${i} did not stream a resumed Ruby counter line"
  fi
done

phase "done"
printf 'demo ok: resumed %s children from one captured Ruby rootfs spore\n' "${count}"
printf 'logs and spores kept in: %s\n' "${workdir}"
