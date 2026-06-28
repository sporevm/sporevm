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

jsonl_output_contains() {
  python3 - "$1" "$2" "$3" <<'PY'
import base64
import json
import sys

needle = sys.argv[3].encode()
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") != sys.argv[2]:
            continue
        if needle in base64.b64decode(event.get("data_base64", "")):
            sys.exit(0)
sys.exit(1)
PY
}

manifest_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)
value = manifest
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

expect_manifest_v1() {
  local dir="$1"
  [[ -f "${dir}/manifest.json" ]] || die "missing manifest: ${dir}/manifest.json"
  [[ "$(manifest_field "${dir}/manifest.json" version)" == "1" ]] || die "manifest is not v1: ${dir}/manifest.json"
  [[ "$(manifest_field "${dir}/manifest.json" platform.vcpu_count)" == "${vcpus}" ]] || die "manifest vcpu_count mismatch: ${dir}/manifest.json"
}

expect_nproc_equals() {
  local stdout="$1"
  local count
  count="$(awk '/^spore nproc / {print $3; exit}' "${stdout}")"
  [[ -n "${count}" ]] || {
    cat "${stdout}" >&2 || true
    die "nproc output was not observed"
  }
  (( count == vcpus )) || {
    cat "${stdout}" >&2 || true
    die "guest reported ${count} CPUs, expected ${vcpus}"
  }
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

vcpus="${SPORE_SMOKE_VCPUS:-2}"
memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-512}mib}"
create_timeout_ms="${SPORE_SMOKE_CREATE_TIMEOUT_MS:-120000}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-multi-vcpu.XXXXXX")"
runtime_dir="${workdir}/runtime"
mkdir -p "${runtime_dir}"
chmod 700 "${runtime_dir}"
cleanup() {
  local status="$?"
  if [[ "${SPORE_SMOKE_KEEP_WORKDIR:-0}" == "1" || "${status}" != "0" ]]; then
    echo "kept smoke workdir: ${workdir}" >&2
    exit "${status}"
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

nproc_stdout="${workdir}/nproc.stdout"
nproc_stderr="${workdir}/nproc.stderr"
if ! "${spore_bin}" run \
  --backend "${backend}" \
  --vcpus "${vcpus}" \
  --memory "${memory}" \
  -- /bin/nproc \
  >"${nproc_stdout}" 2>"${nproc_stderr}"; then
  cat "${nproc_stdout}" >&2 || true
  cat "${nproc_stderr}" >&2 || true
  die "multi-vCPU nproc run failed"
fi
expect_nproc_equals "${nproc_stdout}"

from_base_dir="${workdir}/from-base.spore"
from_stdout="${workdir}/from.stdout"
from_stderr="${workdir}/from.stderr"
if ! "${spore_bin}" run \
  --backend "${backend}" \
  --vcpus "${vcpus}" \
  --memory "${memory}" \
  --capture "${from_base_dir}" \
  -- /bin/true \
  >"${workdir}/from-base.stdout" 2>"${workdir}/from-base.stderr"; then
  cat "${workdir}/from-base.stdout" >&2 || true
  cat "${workdir}/from-base.stderr" >&2 || true
  die "multi-vCPU run --capture base failed"
fi
expect_manifest_v1 "${from_base_dir}"

if ! "${spore_bin}" run \
  --backend "${backend}" \
  --events=jsonl \
  --from "${from_base_dir}" \
  -- /bin/writeout \
  >"${from_stdout}" 2>"${from_stderr}"; then
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "multi-vCPU run --from failed"
fi
jsonl_output_contains "${from_stdout}" stdout "spore stdout" || die "multi-vCPU run --from did not emit stdout"
jsonl_output_contains "${from_stdout}" stderr "spore stderr" || die "multi-vCPU run --from did not emit stderr"

capture_dir="${workdir}/active.spore"
capture_stdout="${workdir}/capture.stdout"
capture_stderr="${workdir}/capture.stderr"
capture_events_pipe="${workdir}/capture.events.pipe"
mkfifo "${capture_events_pipe}"
"${spore_bin}" run \
  --backend "${backend}" \
  --events=jsonl \
  --vcpus "${vcpus}" \
  --memory "${memory}" \
  --capture "${capture_dir}" \
  --capture-on USR1 \
  -- /bin/finite \
  >"${capture_events_pipe}" 2>"${capture_stderr}" &
capture_pid="$!"

if ! python3 "${repo_root}/scripts/capture-on-output-marker.py" --pid "${capture_pid}" --signal USR1 --event stdout --contains "spore finite ready" --out "${capture_stdout}" <"${capture_events_pipe}"; then
  kill -TERM "${capture_pid}" >/dev/null 2>&1 || true
  wait "${capture_pid}" >/dev/null 2>&1 || true
  cat "${capture_stdout}" >&2 || true
  cat "${capture_stderr}" >&2 || true
  die "multi-vCPU capture did not reach the long-running command"
fi

set +e
wait "${capture_pid}"
capture_status="$?"
set -e
if [[ "${capture_status}" != "0" ]]; then
  cat "${capture_stdout}" >&2 || true
  cat "${capture_stderr}" >&2 || true
  die "multi-vCPU signal capture did not finish cleanly"
fi
expect_manifest_v1 "${capture_dir}"

resume_stdout="${workdir}/resume.stdout"
resume_stderr="${workdir}/resume.stderr"
if ! "${spore_bin}" resume --events=jsonl --backend "${backend}" "${capture_dir}" >"${resume_stdout}" 2>"${resume_stderr}"; then
  cat "${resume_stdout}" >&2 || true
  cat "${resume_stderr}" >&2 || true
  die "multi-vCPU resume failed"
fi
jsonl_output_contains "${resume_stdout}" stdout "spore finite" || {
  cat "${resume_stdout}" >&2 || true
  cat "${resume_stderr}" >&2 || true
  die "multi-vCPU resume did not continue the captured workload"
}
grep -Fq '"exit_code":0' "${resume_stdout}" || die "multi-vCPU resume did not report exit_code 0"

if [[ "${SPORE_SMOKE_NAMED_LIFECYCLE:-0}" == "1" ]]; then
  vm_name="mvcpus-${backend}"
  resumed_name="${vm_name}-resumed"
  named_dir="${workdir}/named.spore"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" create "${vm_name}" --backend "${backend}" --vcpus "${vcpus}" --memory "${memory}" --timeout-ms "${create_timeout_ms}" >"${workdir}/create.stdout" 2>"${workdir}/create.stderr"; then
    cat "${workdir}/create.stdout" >&2 || true
    cat "${workdir}/create.stderr" >&2 || true
    die "multi-vCPU named create failed"
  fi
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${vm_name}" -- /bin/nproc >"${workdir}/exec-nproc.stdout" 2>"${workdir}/exec-nproc.stderr"; then
    cat "${workdir}/exec-nproc.stdout" >&2 || true
    cat "${workdir}/exec-nproc.stderr" >&2 || true
    die "multi-vCPU named exec nproc failed"
  fi
  expect_nproc_equals "${workdir}/exec-nproc.stdout"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" suspend "${vm_name}" --out "${named_dir}" >"${workdir}/suspend.stdout" 2>"${workdir}/suspend.stderr"; then
    cat "${workdir}/suspend.stdout" >&2 || true
    cat "${workdir}/suspend.stderr" >&2 || true
    die "multi-vCPU named suspend failed"
  fi
  expect_manifest_v1 "${named_dir}"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" resume "${named_dir}" --name "${resumed_name}" >"${workdir}/named-resume.stdout" 2>"${workdir}/named-resume.stderr"; then
    cat "${workdir}/named-resume.stdout" >&2 || true
    cat "${workdir}/named-resume.stderr" >&2 || true
    die "multi-vCPU named resume failed"
  fi
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${resumed_name}" -- /bin/writeout >"${workdir}/named-exec.stdout" 2>"${workdir}/named-exec.stderr"; then
    cat "${workdir}/named-exec.stdout" >&2 || true
    cat "${workdir}/named-exec.stderr" >&2 || true
    die "multi-vCPU named exec after resume failed"
  fi
  grep -Fxq "spore stdout" "${workdir}/named-exec.stdout" || die "multi-vCPU named exec did not emit stdout after resume"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${resumed_name}" >/dev/null
fi

echo "smoke:multi-vcpu ok backend=${backend} vcpus=${vcpus}"
