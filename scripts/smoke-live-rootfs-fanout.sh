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

count="${SPORE_SMOKE_LIVE_ROOTFS_FANOUT_COUNT:-3}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_LIVE_ROOTFS_FANOUT_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_LIVE_ROOTFS_FANOUT_COUNT must be greater than zero"

image_ref="${SPORE_SMOKE_LIVE_ROOTFS_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_SMOKE_LIVE_ROOTFS_PLATFORM:-linux/arm64}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-live-rootfs-fanout.XXXXXX")"
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

capture_dir="${workdir}/live-rootfs.spore"
fork_dir="${workdir}/children"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
fanout_stdout="${workdir}/fanout.stdout"
fanout_stderr="${workdir}/fanout.stderr"

if [[ "${image_ref}" == *@sha256:* ]]; then
  resolved_image_ref="${image_ref}"
else
  resolved_image_ref="$("${spore_bin}" rootfs resolve "${image_ref}" --platform "${platform}")"
fi
printf 'live rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

ruby_args=(
  /usr/local/bin/ruby
  -e 'STDOUT.sync=true;STDERR.sync=true;puts "ruby live ready";printed=false;tick=0'
  -e 'def e;begin;File.readlines("/run/sporevm/env").to_h{|l|l.strip.split("=",2)};rescue Errno::ENOENT;{};end;end'
  -e 'loop do;env=e;ready=%w[SPORE_PARALLEL_JOB SPORE_PARALLEL_JOB_COUNT SPORE_GENERATION SPORE_PARENT_GENERATION SPORE_FORK_BATCH_ID].all?{|k|env[k]}'
  -e 'if !printed&&ready;gen=env["SPORE_GENERATION"].to_i;parent=env["SPORE_PARENT_GENERATION"].to_i;if gen>parent'
  -e 'host=(File.read("/proc/sys/kernel/hostname").strip rescue "unknown");puts "ruby live generation #{gen} parent=#{parent} batch=#{env["SPORE_FORK_BATCH_ID"]}"'
  -e 'puts "ruby live parallel #{env["SPORE_PARALLEL_JOB"]}/#{env["SPORE_PARALLEL_JOB_COUNT"]} host=#{host}";printed=true;end;end;puts "ruby live tick #{tick}";tick+=1;sleep 1;end'
)

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --save "${capture_dir}" \
  --save-on USR1 \
  -- "${ruby_args[@]}" \
  >"${run_stdout}" 2>"${run_stderr}" &
run_pid="$!"

seen_ready=0
for _ in $(seq 1 "${SPORE_SMOKE_LIVE_ROOTFS_CAPTURE_POLLS:-180}"); do
  if grep -Fq 'ruby live ready' "${run_stdout}"; then
    seen_ready=1
    break
  fi
  sleep "${SPORE_SMOKE_LIVE_ROOTFS_CAPTURE_POLL_INTERVAL:-0.2}"
done
if [[ "${seen_ready}" != "1" ]]; then
  tail -120 "${run_stdout}" >&2 || true
  tail -120 "${run_stderr}" >&2 || true
  die "live rootfs fan-out smoke did not see Ruby ready before capture"
fi

kill -USR1 "${run_pid}"
(
  sleep "${SPORE_SMOKE_LIVE_ROOTFS_CAPTURE_TIMEOUT_SECONDS:-60}"
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
  die "spore run live rootfs capture exited ${run_rc}, expected 0"
fi
[[ -f "${capture_dir}/manifest.json" ]] || die "capture did not write ${capture_dir}/manifest.json"

"${spore_bin}" fork "${capture_dir}" --count "${count}" --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"

children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(find "${fork_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#children[@]}" == "${count}" ]] || die "expected ${count} child spores, found ${#children[@]}"

set +e
"${spore_bin}" fanout --backend "${backend}" "${fork_dir}" --for "${SPORE_SMOKE_LIVE_ROOTFS_FANOUT_DURATION:-20s}" \
  >"${fanout_stdout}" 2>"${fanout_stderr}"
fanout_rc="$?"
set -e

if [[ "${fanout_rc}" != "0" ]]; then
  cat "${fanout_stdout}" >&2 || true
  cat "${fanout_stderr}" >&2 || true
  die "spore fanout exited ${fanout_rc}, expected 0"
fi

for child in "${children[@]}"; do
  child_name="$(basename "${child}")"
  child_index="$((10#${child_name}))"
  if ! grep -Eaq "^\[${child_name}\] ruby live parallel ${child_index}/${count} host=spore-" "${fanout_stdout}"; then
    tail -200 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "child ${child_name} did not observe distinct live fanout identity"
  fi
  if ! grep -Eaq "^\[${child_name}\] ruby live generation [0-9]+ parent=[0-9]+ batch=[0-9a-f]{32}" "${fanout_stdout}"; then
    tail -200 "${fanout_stdout}" >&2 || true
    cat "${fanout_stderr}" >&2 || true
    die "child ${child_name} did not observe fresh live generation metadata"
  fi
done

echo "smoke:live-rootfs-fanout ok backend=${backend} count=${count} image=${resolved_image_ref}"
