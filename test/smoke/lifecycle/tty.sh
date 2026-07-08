#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
image="${SPORE_LIFECYCLE_TTY_IMAGE:-docker.io/library/alpine:3.20}"

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

run_capture() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2

  set +e
  "$@" >"${stdout_path}" 2>"${stderr_path}"
  local status=$?
  set -e
  return "${status}"
}

require_success() {
  local status="$1"
  local label="$2"
  local stderr_path="$3"
  [[ "${status}" == "0" ]] && return
  cat "${stderr_path}" >&2 || true
  die "${label} exited ${status}, expected 0"
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle-tty.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-life-tty.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

vm_name="life-tty-${backend}-$$"
created=0
failed=0
cleanup() {
  if [[ "${failed}" == "1" && -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:lifecycle-tty kept workdir=${workdir} runtime_dir=${runtime_dir}" >&2
    return
  fi
  if [[ "${created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${runtime_dir}"
  rm -rf "${workdir}"
}
trap cleanup EXIT

smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
timeout_ms="${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}"
console_log="${workdir}/console.log"

create_stdout="${workdir}/create.stdout"
create_stderr="${workdir}/create.stderr"
interactive_stdout="${workdir}/interactive.stdout"
interactive_stderr="${workdir}/interactive.stderr"
bounded_stdout="${workdir}/bounded.stdout"
bounded_stderr="${workdir}/bounded.stderr"
tty_stdout="${workdir}/tty.stdout"
tty_stderr="${workdir}/tty.stderr"

if run_capture "${create_stdout}" "${create_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --backend "${backend}" \
    --image "${image}" \
    --memory "${smoke_memory}" \
    --timeout "${timeout_ms}ms" \
    --console-log "${console_log}"; then
  created=1
else
  status=$?
  failed=1
  require_success "${status}" "spore create" "${create_stderr}"
fi

if printf 'named-input\n' | run_capture "${interactive_stdout}" "${interactive_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec -i "${vm_name}" -- /bin/cat; then
  :
else
  status=$?
  failed=1
  require_success "${status}" "spore exec -i" "${interactive_stderr}"
fi
grep -Fxq "named-input" "${interactive_stdout}" || {
  failed=1
  cat "${interactive_stdout}" >&2 || true
  cat "${interactive_stderr}" >&2 || true
  die "spore exec -i did not forward stdin through the monitor stream"
}
[[ ! -s "${interactive_stderr}" ]] || {
  failed=1
  cat "${interactive_stderr}" >&2 || true
  die "spore exec -i wrote unexpected stderr"
}

if run_capture "${bounded_stdout}" "${bounded_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec "${vm_name}" -- /bin/sh -lc 'printf bounded-ok'; then
  :
else
  status=$?
  failed=1
  require_success "${status}" "bounded spore exec after streaming exec" "${bounded_stderr}"
fi
grep -Fxq "bounded-ok" "${bounded_stdout}" || {
  failed=1
  cat "${bounded_stdout}" >&2 || true
  cat "${bounded_stderr}" >&2 || true
  die "bounded spore exec did not work after streaming exec"
}

if run_capture "${tty_stdout}" "${tty_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec -t "${vm_name}" -- /bin/true; then
  failed=1
  die "spore exec -t succeeded while stdout was not a terminal"
else
  status=$?
  [[ "${status}" == "2" ]] || {
    failed=1
    cat "${tty_stderr}" >&2 || true
    die "spore exec -t exited ${status}, expected 2 when stdout is not a terminal"
  }
fi
grep -Fq "requires stdout to be a terminal" "${tty_stderr}" || {
  failed=1
  cat "${tty_stderr}" >&2 || true
  die "spore exec -t did not explain the terminal policy failure"
}

# Bulk exec stdio: over 1MiB must round-trip byte-exact through interactive
# exec stdin and streamed exec stdout. Historically the SPIO transport broke
# above one vsock packet, so tiny fixtures cannot cover this path.
bulk_bytes=$((1536 * 1024))
head -c "${bulk_bytes}" /dev/urandom >"${workdir}/bulk.bin"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec -i "${vm_name}" -- /bin/sh -c 'cat > /tmp/spore-exec-bulk.bin' \
  <"${workdir}/bulk.bin" || {
  failed=1
  die "bulk exec stdin transfer failed"
}
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec -i "${vm_name}" -- /bin/cat /tmp/spore-exec-bulk.bin \
  </dev/null >"${workdir}/bulk-stdout.bin" || {
  failed=1
  die "bulk exec stdout transfer failed"
}
cmp -s "${workdir}/bulk.bin" "${workdir}/bulk-stdout.bin" || {
  failed=1
  die "bulk exec stdio roundtrip mismatch"
}

# A deliberately failed stream must leave the VM usable: kill the CLI mid
# bulk stdin transfer, then require a follow-up exec to succeed.
( exec env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    "${spore_bin}" exec -i "${vm_name}" -- /bin/sh -c 'cat > /dev/null' \
    < <(head -c $((64 * 1024 * 1024)) /dev/zero) ) &
failed_stream_pid=$!
sleep 1
kill -KILL "${failed_stream_pid}" 2>/dev/null || true
wait "${failed_stream_pid}" 2>/dev/null || true
after_failed_stream="$(env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec "${vm_name}" -- /bin/sh -c 'echo usable')"
[[ "${after_failed_stream}" == "usable" ]] || {
  failed=1
  die "VM unusable after deliberately failed stream"
}

echo "smoke:lifecycle-tty ok"
