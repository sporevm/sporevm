#!/usr/bin/env bash
set -euo pipefail

die() {
  failed=1
  echo "error: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

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

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1000000)'
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
  failed=1
  cat "${stderr_path}" >&2 || true
  die "${label} exited ${status}, expected 0"
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle-auto-memory.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-life-auto.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

vm_name="life-auto-${backend}-$$"
spore_dir="${workdir}/${vm_name}.spore"
console_log="${workdir}/console.log"
created=0
suspended=0
failed=0

cleanup() {
  local keep=0
  [[ "${failed}" == "1" || -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]] && keep=1

  if [[ "${created}" == "1" && "${suspended}" != "1" && -z "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi

  if [[ "${keep}" == "1" ]]; then
    echo "smoke:lifecycle-auto-memory kept workdir=${workdir} runtime_dir=${runtime_dir}" >&2
    for log in "${workdir}"/*.stdout "${workdir}"/*.stderr "${workdir}"/*.log; do
      [[ -e "${log}" ]] || continue
      echo "==> ${log}" >&2
      tail -120 "${log}" >&2 || true
    done
    return
  fi
  rm -rf "${runtime_dir}"
  rm -rf "${workdir}"
}
trap cleanup EXIT

create_stdout="${workdir}/create.stdout"
create_stderr="${workdir}/create.stderr"
exec1_stdout="${workdir}/exec1.stdout"
exec1_stderr="${workdir}/exec1.stderr"
exec2_stdout="${workdir}/exec2.stdout"
exec2_stderr="${workdir}/exec2.stderr"
ls_stdout="${workdir}/ls.stdout"
ls_stderr="${workdir}/ls.stderr"
suspend_stdout="${workdir}/suspend.stdout"
suspend_stderr="${workdir}/suspend.stderr"

create_start_ms="$(now_ms)"
if run_capture "${create_stdout}" "${create_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --backend "${backend}" \
    --memory auto \
    --timeout "${SPORE_SMOKE_LIFECYCLE_AUTO_MEMORY_TIMEOUT_MS:-60000}ms" \
    --console-log "${console_log}"; then
  created=1
else
  status=$?
  require_success "${status}" "spore create --memory auto" "${create_stderr}"
fi
create_ms="$(( $(now_ms) - create_start_ms ))"

if run_capture "${exec1_stdout}" "${exec1_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${vm_name}" -- /bin/writeout; then
  :
else
  status=$?
  require_success "${status}" "first spore exec" "${exec1_stderr}"
fi
grep -Fxq "spore stdout" "${exec1_stdout}" || die "first spore exec did not forward guest stdout"
grep -Fq "spore stderr" "${exec1_stderr}" || die "first spore exec did not forward guest stderr"

if run_capture "${exec2_stdout}" "${exec2_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${vm_name}" -- /bin/true; then
  :
else
  status=$?
  require_success "${status}" "second spore exec" "${exec2_stderr}"
fi
[[ ! -s "${exec2_stdout}" ]] || die "second spore exec wrote unexpected stdout"

if run_capture "${ls_stdout}" "${ls_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json ls; then
  :
else
  status=$?
  require_success "${status}" "spore --json ls" "${ls_stderr}"
fi

if ! ls_metrics="$(
  python3 - "${ls_stdout}" "${vm_name}" <<'PY'
import json
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)

entry = next((e for e in entries if e.get("name") == name), None)
if entry is None:
    raise SystemExit(f"{name} missing from spore --json ls")
if entry.get("state") != "ready":
    raise SystemExit(f"{name} state was {entry.get('state')!r}, expected ready")

memory = entry.get("memory") or {}
stats = entry.get("stats") or {}
def field(value):
    return "null" if value is None else str(value)

for key, value in {
    "memory_policy": memory.get("policy"),
    "memory_bytes": memory.get("bytes"),
    "chunk_size": stats.get("chunk_size"),
    "chunks_total": stats.get("chunks_total"),
}.items():
    if value is None:
        raise SystemExit(f"{key} missing from spore --json ls")

print(
    f"memory_policy={memory['policy']} "
    f"memory_bytes={memory['bytes']} "
    f"resident_bytes={field(stats.get('resident_bytes'))} "
    f"chunk_size={stats['chunk_size']} "
    f"chunks_total={stats['chunks_total']} "
    f"ls_chunks_nonzero={field(stats.get('chunks_nonzero'))} "
    f"dirty_chunks_pending={field(stats.get('dirty_chunks_pending'))}"
)
PY
)"; then
  failed=1
  die "could not read lifecycle list metrics"
fi

suspend_start_ms="$(now_ms)"
if run_capture "${suspend_stdout}" "${suspend_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" save "${vm_name}" --out "${spore_dir}" --stop; then
  suspended=1
  created=0
else
  status=$?
  require_success "${status}" "spore save --stop" "${suspend_stderr}"
fi
suspend_ms="$(( $(now_ms) - suspend_start_ms ))"

if ! manifest_metrics="$(
  python3 - "${spore_dir}" <<'PY'
import json
import os
import sys

spore_dir = sys.argv[1]
manifest_path = os.path.join(spore_dir, "manifest.json")
backing_path = os.path.join(spore_dir, "ram.backing")
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

ram_size = manifest["platform"]["ram_size"]
memory = manifest["memory"]
chunks = memory["chunks"]
chunks_total = len(chunks)
chunks_nonzero = sum(1 for chunk in chunks if chunk is not None)
backing = memory.get("backing") or {}
st = os.stat(backing_path)
backing_allocated = getattr(st, "st_blocks", 0) * 512

print(
    f"manifest_ram_size={ram_size} "
    f"manifest_chunk_size={memory['chunk_size']} "
    f"manifest_chunks_total={chunks_total} "
    f"manifest_chunks_nonzero={chunks_nonzero} "
    f"backing_kind={backing.get('kind')} "
    f"backing_size={backing.get('size')} "
    f"backing_logical_bytes={st.st_size} "
    f"backing_allocated_bytes={backing_allocated}"
)
PY
)"; then
  failed=1
  die "could not read lifecycle manifest metrics"
fi

eval "${ls_metrics}"
eval "${manifest_metrics}"

[[ "${memory_policy}" == "auto" ]] || die "memory policy was ${memory_policy}, expected auto"
[[ "${memory_bytes}" == "17179869184" ]] || die "memory bytes was ${memory_bytes}, expected 17179869184"
[[ "${manifest_ram_size}" == "17179869184" ]] || die "manifest ram size was ${manifest_ram_size}, expected 17179869184"
[[ "${chunk_size}" == "2097152" && "${manifest_chunk_size}" == "2097152" ]] || die "unexpected memory chunk size"
[[ "${chunks_total}" == "8192" && "${manifest_chunks_total}" == "8192" ]] || die "unexpected chunk count"
if [[ "${resident_bytes}" != "null" ]]; then
  [[ "${resident_bytes}" =~ ^[0-9]+$ && "${resident_bytes}" -gt 0 && "${resident_bytes}" -lt "${memory_bytes}" ]] || die "resident bytes did not distinguish host cost from configured RAM"
fi
[[ "${manifest_chunks_nonzero}" =~ ^[0-9]+$ && "${manifest_chunks_nonzero}" -gt 0 && "${manifest_chunks_nonzero}" -lt "${manifest_chunks_total}" ]] || die "manifest chunks were not sparse"
[[ "${backing_kind}" == "map-private-file-v0" ]] || die "unexpected backing kind: ${backing_kind}"
[[ "${backing_size}" == "${manifest_ram_size}" && "${backing_logical_bytes}" == "${manifest_ram_size}" ]] || die "backing logical size did not match configured RAM"
[[ "${backing_allocated_bytes}" =~ ^[0-9]+$ && "${backing_allocated_bytes}" -gt 0 && "${backing_allocated_bytes}" -lt "${backing_logical_bytes}" ]] || die "backing allocation did not stay sparse"

echo "smoke:lifecycle-auto-memory ok backend=${backend} create_ms=${create_ms} suspend_ms=${suspend_ms} ${ls_metrics} ${manifest_metrics}"
