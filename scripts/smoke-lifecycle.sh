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
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-life.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

vm_name="life-${backend}-$$"
created=0
failed=0
cleanup() {
  if [[ "${failed}" == "1" && -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:lifecycle kept workdir=${workdir} runtime_dir=${runtime_dir}" >&2
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
writeout_stdout="${workdir}/writeout.stdout"
writeout_stderr="${workdir}/writeout.stderr"
true_stdout="${workdir}/true.stdout"
true_stderr="${workdir}/true.stderr"
ls_stdout="${workdir}/ls.stdout"
ls_stderr="${workdir}/ls.stderr"
rm_stdout="${workdir}/rm.stdout"
rm_stderr="${workdir}/rm.stderr"
ls_after_stdout="${workdir}/ls-after.stdout"
ls_after_stderr="${workdir}/ls-after.stderr"
json_rootfs_stdout="${workdir}/json-rootfs.stdout"
json_rootfs_stderr="${workdir}/json-rootfs.stderr"
json_image_stdout="${workdir}/json-image.stdout"
json_image_stderr="${workdir}/json-image.stderr"

if run_capture "${json_rootfs_stdout}" "${json_rootfs_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" --json create "${vm_name}-missing-rootfs" --rootfs "${workdir}/missing.ext4"; then
  die "spore --json create accepted a missing rootfs"
else
  status=$?
  [[ "${status}" == "22" ]] || {
    cat "${json_rootfs_stderr}" >&2 || true
    die "spore --json create missing rootfs exited ${status}, expected 22"
  }
fi
python3 - "${json_rootfs_stdout}" "${json_rootfs_stderr}" <<'PY'
import json
import sys

stdout_path, stderr_path = sys.argv[1], sys.argv[2]
if open(stdout_path, "rb").read():
    raise SystemExit("spore --json create missing rootfs wrote stdout")
with open(stderr_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

err = payload.get("error", {})
if payload.get("schema") != "spore.error.v1" or err.get("code") != "object.not_found" or err.get("source") != "create":
    raise SystemExit("spore --json create missing rootfs did not emit the stable error envelope")
PY

if run_capture "${json_image_stdout}" "${json_image_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" --json create "${vm_name}-bad-image" --image alpine:3.20; then
  die "spore --json create accepted an image ref without registry"
else
  status=$?
  [[ "${status}" == "2" ]] || {
    cat "${json_image_stderr}" >&2 || true
    die "spore --json create bad image exited ${status}, expected 2"
  }
fi
python3 - "${json_image_stdout}" "${json_image_stderr}" <<'PY'
import json
import sys

stdout_path, stderr_path = sys.argv[1], sys.argv[2]
if open(stdout_path, "rb").read():
    raise SystemExit("spore --json create bad image wrote stdout")
with open(stderr_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

err = payload.get("error", {})
if payload.get("schema") != "spore.error.v1" or err.get("code") != "usage.invalid_argument" or err.get("source") != "create":
    raise SystemExit("spore --json create bad image did not emit the stable error envelope")
PY

if run_capture "${create_stdout}" "${create_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --timeout-ms "${timeout_ms}" \
    --console-log "${console_log}"; then
  created=1
else
  status=$?
  require_success "${status}" "spore create" "${create_stderr}"
fi

if run_capture "${writeout_stdout}" "${writeout_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec "${vm_name}" -- /bin/writeout; then
  :
else
  status=$?
  require_success "${status}" "first spore exec" "${writeout_stderr}"
fi
grep -Fxq "spore stdout" "${writeout_stdout}" || {
  cat "${writeout_stdout}" >&2 || true
  cat "${writeout_stderr}" >&2 || true
  die "first spore exec did not forward guest stdout"
}
grep -Fq "spore stderr" "${writeout_stderr}" || {
  cat "${writeout_stdout}" >&2 || true
  cat "${writeout_stderr}" >&2 || true
  die "first spore exec did not forward guest stderr"
}

if run_capture "${true_stdout}" "${true_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" exec "${vm_name}" -- /bin/true; then
  :
else
  status=$?
  require_success "${status}" "second spore exec" "${true_stderr}"
fi
[[ ! -s "${true_stdout}" ]] || {
  cat "${true_stdout}" >&2 || true
  die "second spore exec wrote unexpected stdout"
}

if run_capture "${ls_stdout}" "${ls_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json ls; then
  :
else
  status=$?
  require_success "${status}" "spore ls" "${ls_stderr}"
fi
python3 - "${ls_stdout}" "${vm_name}" <<'PY'
import json
import sys

path, vm_name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)

if not any(entry.get("name") == vm_name and entry.get("state") == "ready" for entry in entries):
    raise SystemExit(f"VM {vm_name} was not listed as ready")
PY

if run_capture "${rm_stdout}" "${rm_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}"; then
  created=0
else
  status=$?
  require_success "${status}" "spore rm" "${rm_stderr}"
fi

if run_capture "${ls_after_stdout}" "${ls_after_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json ls; then
  :
else
  status=$?
  require_success "${status}" "post-rm spore ls" "${ls_after_stderr}"
fi
python3 - "${ls_after_stdout}" "${vm_name}" <<'PY'
import json
import sys

path, vm_name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)

if any(entry.get("name") == vm_name for entry in entries):
    raise SystemExit(f"VM {vm_name} remained listed after rm")
PY

echo "smoke:lifecycle ok backend=${backend}"
