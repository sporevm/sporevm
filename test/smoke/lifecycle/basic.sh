#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-life"

vm_name="life-${backend}-$$"
worker0="${vm_name}-worker-0"
worker1="${vm_name}-worker-1"
created=0
worker_created=0
cleanup() {
  if [[ "${worker_created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${worker0}" >/dev/null 2>&1 || true
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${worker1}" >/dev/null 2>&1 || true
  fi
  if [[ "${created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${vm_name}" >/dev/null 2>&1 || true
  fi
}

smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
timeout_ms="${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}"
console_log="${workdir}/console.log"

create_stdout="${workdir}/create.stdout"
create_stderr="${workdir}/create.stderr"
writeout_stdout="${workdir}/writeout.stdout"
writeout_stderr="${workdir}/writeout.stderr"
true_stdout="${workdir}/true.stdout"
true_stderr="${workdir}/true.stderr"
initial_output_json="${workdir}/initial-output.json"
initial_output_stderr="${workdir}/initial-output.stderr"
long_command_stdout="${workdir}/long-command.stdout"
long_command_stderr="${workdir}/long-command.stderr"
oversized_command_stdout="${workdir}/oversized-command.stdout"
oversized_command_stderr="${workdir}/oversized-command.stderr"
fork_stdout="${workdir}/fork.stdout"
fork_stderr="${workdir}/fork.stderr"
source_after_fork_stdout="${workdir}/source-after-fork.stdout"
source_after_fork_stderr="${workdir}/source-after-fork.stderr"
worker0_stdout="${workdir}/worker0.stdout"
worker0_stderr="${workdir}/worker0.stderr"
worker1_stdout="${workdir}/worker1.stdout"
worker1_stderr="${workdir}/worker1.stderr"
ls_stdout="${workdir}/ls.stdout"
ls_stderr="${workdir}/ls.stderr"
rm_worker0_stdout="${workdir}/rm-worker0.stdout"
rm_worker0_stderr="${workdir}/rm-worker0.stderr"
rm_worker1_stdout="${workdir}/rm-worker1.stdout"
rm_worker1_stderr="${workdir}/rm-worker1.stderr"
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
  "${spore_bin}" --json vm create "${vm_name}-missing-rootfs" --rootfs "${workdir}/missing.ext4"; then
  die "spore --json vm create accepted a missing rootfs"
else
  status=$?
  [[ "${status}" == "22" ]] || {
    cat "${json_rootfs_stderr}" >&2 || true
    die "spore --json vm create missing rootfs exited ${status}, expected 22"
  }
fi
python3 - "${json_rootfs_stdout}" "${json_rootfs_stderr}" <<'PY'
import json
import sys

stdout_path, stderr_path = sys.argv[1], sys.argv[2]
if open(stdout_path, "rb").read():
    raise SystemExit("spore --json vm create missing rootfs wrote stdout")
with open(stderr_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

err = payload.get("error", {})
if payload.get("schema") != "spore.error.v1" or err.get("code") != "object.not_found" or err.get("source") != "create":
    raise SystemExit("spore --json vm create missing rootfs did not emit the stable error envelope")
PY

if run_capture "${json_image_stdout}" "${json_image_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" --json vm create "${vm_name}-bad-image" --image alpine:3.20; then
  die "spore --json vm create accepted an image ref without registry"
else
  status=$?
  [[ "${status}" == "2" ]] || {
    cat "${json_image_stderr}" >&2 || true
    die "spore --json vm create bad image exited ${status}, expected 2"
  }
fi
python3 - "${json_image_stdout}" "${json_image_stderr}" <<'PY'
import json
import sys

stdout_path, stderr_path = sys.argv[1], sys.argv[2]
if open(stdout_path, "rb").read():
    raise SystemExit("spore --json vm create bad image wrote stdout")
with open(stderr_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

err = payload.get("error", {})
if payload.get("schema") != "spore.error.v1" or err.get("code") != "usage.invalid_argument" or err.get("source") != "create":
    raise SystemExit("spore --json vm create bad image did not emit the stable error envelope")
PY

if run_capture "${create_stdout}" "${create_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm create "${vm_name}" \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --timeout "${timeout_ms}ms" \
    --console-log "${console_log}" \
    -- /bin/sh -c 'i=0; while [ "$i" -lt 10000 ]; do printf 0123456789; printf abcdefghij >&2; i=$((i+1)); done; exit 7'; then
  created=1
else
  status=$?
  require_success "${status}" "spore vm create" "${create_stderr}"
fi

# The initial command writes more than a pipe buffer to both streams and exits
# non-zero. Create must return without a reader attached, while the guest keeps
# draining into fixed buffers so the command can finish unattended.
for _ in $(seq 1 50); do
  if run_capture "${initial_output_json}" "${initial_output_stderr}" \
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    "${spore_bin}" --json vm logs "${vm_name}"; then
    if python3 - "${initial_output_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
raise SystemExit(0 if payload.get("initial_command", {}).get("process_status") == "exited" else 1)
PY
    then
      break
    fi
  else
    status=$?
    require_success "${status}" "spore vm logs" "${initial_output_stderr}"
  fi
  sleep 0.1
done
python3 - "${initial_output_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
initial = payload.get("initial_command", {})
if payload.get("schema") != "spore.lifecycle.v1" or payload.get("action") != "logs":
    raise SystemExit("spore vm logs did not reuse the lifecycle result envelope")
if initial.get("output_disposition") != "retain" or initial.get("output_destination") != "named_logs":
    raise SystemExit("spore vm logs did not report retained named output")
if initial.get("startup_status") != "started" or initial.get("process_status") != "exited" or initial.get("exit_code") != 7:
    raise SystemExit("spore vm logs did not report the short-lived command exit")
limit = initial.get("output_limit_bytes_per_stream")
if limit != 16381 or len(initial.get("stdout", "")) != limit or len(initial.get("stderr", "")) != limit:
    raise SystemExit("spore vm logs did not enforce the per-stream output bound")
if not initial.get("stdout_truncated") or not initial.get("stderr_truncated"):
    raise SystemExit("spore vm logs did not report stream truncation")
PY

if run_capture "${writeout_stdout}" "${writeout_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/writeout; then
  :
else
  status=$?
  require_success "${status}" "first spore vm exec" "${writeout_stderr}"
fi
grep -Fxq "spore stdout" "${writeout_stdout}" || {
  cat "${writeout_stdout}" >&2 || true
  cat "${writeout_stderr}" >&2 || true
  die "first spore vm exec did not forward guest stdout"
}
grep -Fq "spore stderr" "${writeout_stderr}" || {
  cat "${writeout_stdout}" >&2 || true
  cat "${writeout_stderr}" >&2 || true
  die "first spore vm exec did not forward guest stderr"
}

if run_capture "${true_stdout}" "${true_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/true; then
  :
else
  status=$?
  require_success "${status}" "second spore vm exec" "${true_stderr}"
fi
[[ ! -s "${true_stdout}" ]] || {
  cat "${true_stdout}" >&2 || true
  die "second spore vm exec wrote unexpected stdout"
}

printf -v long_payload '%04096d' 0
long_command="echo ${long_payload}"
if run_capture "${long_command_stdout}" "${long_command_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" "${long_command}"; then
  :
else
  status=$?
  require_success "${status}" "long shell-form spore vm exec" "${long_command_stderr}"
fi
grep -Fxq "${long_payload}" "${long_command_stdout}" || {
  cat "${long_command_stdout}" >&2 || true
  cat "${long_command_stderr}" >&2 || true
  die "long shell-form spore vm exec did not preserve its command"
}

printf -v oversized_arg '%08000d' 0
if run_capture "${oversized_command_stdout}" "${oversized_command_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/echo "${oversized_arg}"; then
  die "spore vm exec accepted a command larger than the guest request limit"
else
  status=$?
  [[ "${status}" == "1" ]] || {
    cat "${oversized_command_stderr}" >&2 || true
    die "oversized spore vm exec exited ${status}, expected 1"
  }
fi
grep -Fxq "spore vm exec: guest command exceeds the 8191-byte request limit; shorten it or run a script in the guest" "${oversized_command_stderr}" || {
  cat "${oversized_command_stderr}" >&2 || true
  die "oversized spore vm exec did not report the guest request limit"
}
if grep -Fq "MonitorRequestFailed" "${oversized_command_stderr}"; then
  cat "${oversized_command_stderr}" >&2 || true
  die "oversized spore vm exec leaked the generic monitor error"
fi

if run_capture "${fork_stdout}" "${fork_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm fork "${vm_name}" --count 2 --name "${vm_name}-worker-%d"; then
  worker_created=1
else
  status=$?
  require_success "${status}" "spore vm fork" "${fork_stderr}"
fi

if run_capture "${source_after_fork_stdout}" "${source_after_fork_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/true; then
  :
else
  status=$?
  require_success "${status}" "source spore vm exec after fork" "${source_after_fork_stderr}"
fi
[[ ! -s "${source_after_fork_stdout}" ]] || {
  cat "${source_after_fork_stdout}" >&2 || true
  die "source exec after fork wrote unexpected stdout"
}

# A live name cannot be claimed again: create fails, and fork fails before it
# pauses the source, leaving the existing VM's spec untouched.
worker0_spec="${runtime_dir}/vms/${worker0}/spec.json"
worker0_spec_before="$(cksum <"${worker0_spec}")"
if env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm create "${vm_name}" \
  --backend "${backend}" --memory "${smoke_memory}" >/dev/null 2>"${workdir}/create-existing.stderr"; then
  die "spore vm create of an existing name unexpectedly succeeded"
fi
grep -Fq "already exists" "${workdir}/create-existing.stderr" || {
  cat "${workdir}/create-existing.stderr" >&2 || true
  die "spore vm create of an existing name did not report it"
}
if env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm fork "${vm_name}" --count 1 --name "${worker0}" \
  >/dev/null 2>"${workdir}/fork-existing.stderr"; then
  die "spore vm fork onto an existing name unexpectedly succeeded"
fi
grep -Fq "already exists" "${workdir}/fork-existing.stderr" || {
  cat "${workdir}/fork-existing.stderr" >&2 || true
  die "spore vm fork onto an existing name did not report it"
}
[[ "$(cksum <"${worker0_spec}")" == "${worker0_spec_before}" ]] || die "spore vm fork rewrote the existing VM's spec"

if run_capture "${worker0_stdout}" "${worker0_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${worker0}" -- /bin/writeout; then
  :
else
  status=$?
  require_success "${status}" "worker0 spore vm exec" "${worker0_stderr}"
fi
grep -Fxq "spore stdout" "${worker0_stdout}" || {
  cat "${worker0_stdout}" >&2 || true
  cat "${worker0_stderr}" >&2 || true
  die "worker0 spore vm exec did not forward guest stdout"
}
grep -Fq "spore stderr" "${worker0_stderr}" || {
  cat "${worker0_stdout}" >&2 || true
  cat "${worker0_stderr}" >&2 || true
  die "worker0 spore vm exec did not forward guest stderr"
}

if run_capture "${worker1_stdout}" "${worker1_stderr}" \
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${worker1}" -- /bin/true; then
  :
else
  status=$?
  require_success "${status}" "worker1 spore vm exec" "${worker1_stderr}"
fi
[[ ! -s "${worker1_stdout}" ]] || {
  cat "${worker1_stdout}" >&2 || true
  die "worker1 spore vm exec wrote unexpected stdout"
}

if run_capture "${ls_stdout}" "${ls_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json vm ls; then
  :
else
  status=$?
  require_success "${status}" "spore vm ls" "${ls_stderr}"
fi
python3 - "${ls_stdout}" "${vm_name}" "${worker0}" "${worker1}" <<'PY'
import json
import sys

path, *names = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)["entries"]

ready_names = {entry.get("name") for entry in entries if entry.get("state") == "ready"}
missing = [name for name in names if name not in ready_names]
if missing:
    raise SystemExit(f"VMs were not listed as ready: {', '.join(missing)}")
PY

if run_capture "${rm_worker0_stdout}" "${rm_worker0_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${worker0}"; then
  :
else
  status=$?
  require_success "${status}" "spore vm rm worker0" "${rm_worker0_stderr}"
fi

if run_capture "${rm_worker1_stdout}" "${rm_worker1_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${worker1}"; then
  worker_created=0
else
  status=$?
  require_success "${status}" "spore vm rm worker1" "${rm_worker1_stderr}"
fi

# rm must not wait for a running exec: the monitor answers shutdown at once
# and fails the exec with the removal message.
running_exec_stdout="${workdir}/running-exec.stdout"
running_exec_stderr="${workdir}/running-exec.stderr"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm exec "${vm_name}" -- /bin/sh -c 'echo started; exec sleep 300' \
  >"${running_exec_stdout}" 2>"${running_exec_stderr}" &
running_exec_pid=$!
for _ in $(seq 1 300); do
  grep -Fxq started "${running_exec_stdout}" && break
  kill -0 "${running_exec_pid}" 2>/dev/null || break
  sleep 0.1
done
grep -Fxq started "${running_exec_stdout}" || {
  cat "${running_exec_stderr}" >&2 || true
  die "background spore vm exec did not start"
}

rm_started="${SECONDS}"
if run_capture "${rm_stdout}" "${rm_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${vm_name}"; then
  created=0
else
  status=$?
  require_success "${status}" "spore vm rm" "${rm_stderr}"
fi
rm_seconds=$((SECONDS - rm_started))
((rm_seconds <= 5)) || die "spore vm rm took ${rm_seconds}s while an exec was running"
if wait "${running_exec_pid}"; then
  die "spore vm exec succeeded although its VM was removed"
fi
grep -Fq "named VM is being removed" "${running_exec_stderr}" || {
  cat "${running_exec_stderr}" >&2 || true
  die "spore vm exec did not report the VM removal"
}
if env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm logs "${vm_name}" >/dev/null 2>&1; then
  die "spore vm logs unexpectedly retained output after VM removal"
fi
[[ ! -e "${runtime_dir}/vms/${vm_name}" ]] || die "spore vm rm left retained initial output state behind"

if run_capture "${ls_after_stdout}" "${ls_after_stderr}" env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" --json vm ls; then
  :
else
  status=$?
  require_success "${status}" "post-rm spore vm ls" "${ls_after_stderr}"
fi
python3 - "${ls_after_stdout}" "${vm_name}" "${worker0}" "${worker1}" <<'PY'
import json
import sys

path, *names = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    entries = json.load(fh)["entries"]

remaining = {entry.get("name") for entry in entries}
unexpected = [name for name in names if name in remaining]
if unexpected:
    raise SystemExit(f"VMs remained listed after rm: {', '.join(unexpected)}")
PY

echo "smoke:lifecycle ok backend=${backend}"
