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

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

count="${SPORE_SMOKE_ROOTFS_FANOUT_COUNT:-3}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_ROOTFS_FANOUT_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_ROOTFS_FANOUT_COUNT must be greater than zero"

image_ref="${SPORE_SMOKE_ROOTFS_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_SMOKE_ROOTFS_PLATFORM:-linux/arm64}"
stream_children="${SPORE_SMOKE_ROOTFS_STREAM_CHILDREN:-1}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-rootfs-fanout.XXXXXX")"
run_pid=""
watchdog_pid=""
resume_pids=()
stream_pids=()
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
  rm -rf "${workdir}"
}
trap cleanup EXIT

capture_dir="${workdir}/ruby-counter.spore"
fork_dir="${workdir}/children"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
resolved_image_ref="$("${spore_bin}" rootfs resolve "${image_ref}" --platform "${platform}")"
printf 'rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --capture-on-abort "${capture_dir}" \
  --capture-signal USR1 \
  -- /usr/local/bin/ruby -e 'STDOUT.sync = true; puts "spore run ready"; i = 0; loop { puts "ruby counter #{i}"; i += 1; sleep 1 }' \
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
  die "rootfs fan-out smoke did not see the fresh Ruby counter"
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
grep -Fq '"digest": "blake3:' "${capture_dir}/manifest.json" || die "capture manifest did not record a rootfs digest"

"${spore_bin}" fork "${capture_dir}" --count "${count}" --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"

children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(find "${fork_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#children[@]}" == "${count}" ]] || die "expected ${count} child spores, found ${#children[@]}"

resume_logs=()
seen=()
for i in "${!children[@]}"; do
  log="${workdir}/resume-${i}.log"
  resume_logs+=("${log}")
  seen+=("0")
  : >"${log}"
  "${spore_bin}" resume --backend "${backend}" "${children[$i]}" >"${log}" 2>&1 &
  resume_pids+=("$!")
  if [[ "${stream_children}" == "1" ]]; then
    child_name="$(basename "${children[$i]}")"
    tail -n +1 -f "${log}" > >(awk -v prefix="[child ${child_name}] " '{ print prefix $0; fflush() }') &
    stream_pids+=("$!")
  fi
done

for _ in $(seq 1 "${SPORE_SMOKE_ROOTFS_RESUME_POLLS:-240}"); do
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
  sleep "${SPORE_SMOKE_ROOTFS_RESUME_POLL_INTERVAL:-0.25}"
done

for i in "${!resume_logs[@]}"; do
  if [[ "${seen[$i]}" != "1" ]]; then
    tail -120 "${resume_logs[$i]}" >&2 || true
    die "child ${i} did not stream a resumed Ruby counter line"
  fi
done

echo "smoke:rootfs-fanout ok backend=${backend} count=${count} image=${resolved_image_ref}"
