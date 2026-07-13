#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

expect_manifest_v3() {
  local dir="$1"
  [[ -f "${dir}/manifest.json" ]] || die "missing manifest: ${dir}/manifest.json"
  [[ "$(manifest_field "${dir}/manifest.json" version)" == "3" ]] || die "manifest is not v3: ${dir}/manifest.json"
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

expect_online_cpus() {
  local stdout="$1"
  local actual expected="0"
  actual="$(awk '/^spore cpus-online / {print $3; exit}' "${stdout}")"
  if (( vcpus > 1 )); then
    expected="0-$((vcpus - 1))"
  fi
  [[ "${actual}" == "${expected}" ]] || {
    cat "${stdout}" >&2 || true
    die "guest reported online CPUs ${actual:-unknown}, expected ${expected}"
  }
}

expect_named_online_cpus() {
  local name="$1"
  local prefix="$2"
  local stdout="${workdir}/${prefix}.stdout"
  local stderr="${workdir}/${prefix}.stderr"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${name}" -- "${online_cpu_command[@]}" >"${stdout}" 2>"${stderr}"; then
    cat "${stdout}" >&2 || true
    cat "${stderr}" >&2 || true
    die "multi-vCPU online CPU check failed for ${name}"
  fi
  expect_online_cpus "${stdout}"
}

save_named_with_metrics() {
  local name="$1"
  local out_dir="$2"
  local label="$3"
  local monitor_log="${runtime_dir}/vms/${name}/monitor.log"
  local snapshot_before publication_before

  snapshot_before="$(grep -c "${backend} snapshot metrics:" "${monitor_log}" 2>/dev/null || true)"
  publication_before="$(grep -c "${backend} named snapshot publication metrics:" "${monitor_log}" 2>/dev/null || true)"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" save "${name}" --out "${out_dir}" \
    >"${workdir}/${label}-save.stdout" 2>"${workdir}/${label}-save.stderr"; then
    cat "${workdir}/${label}-save.stdout" >&2 || true
    cat "${workdir}/${label}-save.stderr" >&2 || true
    die "${label} non-destructive save failed"
  fi

  local snapshot_after publication_after snapshot_line publication_line
  snapshot_after="$(grep -c "${backend} snapshot metrics:" "${monitor_log}" || true)"
  publication_after="$(grep -c "${backend} named snapshot publication metrics:" "${monitor_log}" || true)"
  [[ "${snapshot_after}" == "$((snapshot_before + 1))" ]] || die "${label} save did not emit exactly one snapshot metric"
  [[ "${publication_after}" == "$((publication_before + 1))" ]] || die "${label} save did not emit exactly one publication metric"
  snapshot_line="$(grep "${backend} snapshot metrics:" "${monitor_log}" | tail -1)"
  publication_line="$(grep "${backend} named snapshot publication metrics:" "${monitor_log}" | tail -1)"
  python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" --snapshot "${snapshot_line}" >"${workdir}/${label}-snapshot.json"
  python3 "${repo_root}/scripts/benchmark/parse-save-metrics.py" --named-publication "${publication_line}" >"${workdir}/${label}-publication.json"

  python3 - "${workdir}/${label}-snapshot.json" "${workdir}/${label}-publication.json" "${out_dir}/manifest.json" "${backend}" "${vcpus}" "${label}" <<'PY'
import json
import sys

snapshot_path, publication_path, manifest_path, backend, vcpus, label = sys.argv[1:]
snapshot = json.load(open(snapshot_path, encoding="utf-8"))
publication = json.load(open(publication_path, encoding="utf-8"))
manifest = json.load(open(manifest_path, encoding="utf-8"))
ram_mib = manifest["platform"]["ram_size"] // (1024 * 1024)
assert snapshot["backend"] == backend, snapshot
assert publication["backend"] == backend, publication
assert manifest["platform"]["vcpu_count"] == int(vcpus), manifest["platform"]
assert publication["source_pause_ms"] >= snapshot["snapshot_total_ms"], (snapshot, publication)
print(
    f"named save metrics case={label} backend={backend} vcpus={vcpus} "
    f"ram_mib={ram_mib} snapshot_total_ms={snapshot['snapshot_total_ms']} "
    f"source_pause_ms={publication['source_pause_ms']} "
    f"cache_lock_wait_ms={publication['cache_lock_wait_ms']} "
    f"manifest_pin_authorization_ms={publication['manifest_pin_authorization_ms']} "
    f"active_lease_handoff_ms={publication['active_lease_handoff_ms']} "
    f"lifecycle_spec_ms={publication['lifecycle_spec_ms']} "
    f"final_publication_ms={publication['final_publication_ms']}"
)
PY
}

run_disk_point_in_time_case() {
  local kind="$1"
  shift
  local source_name="${vm_name}-${kind}"
  local restored_name="${source_name}-restored"
  local saved_dir="${workdir}/${kind}.spore"

  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" create "${source_name}" \
    --backend "${backend}" \
    --vcpus "${vcpus}" \
    --memory "${memory}" \
    --timeout "${create_timeout_ms}ms" \
    "$@" \
    >"${workdir}/${kind}-create.stdout" 2>"${workdir}/${kind}-create.stderr"; then
    cat "${workdir}/${kind}-create.stdout" >&2 || true
    cat "${workdir}/${kind}-create.stderr" >&2 || true
    die "${kind} multi-vCPU named create failed"
  fi
  expect_named_online_cpus "${source_name}" "${kind}-source-cpus-online"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${source_name}" -- \
    /bin/sh -lc 'printf captured > /var/sporevm-save-point; sync'
  save_named_with_metrics "${source_name}" "${saved_dir}" "${kind}"
  expect_manifest_v3 "${saved_dir}"
  [[ "$(manifest_field "${saved_dir}/manifest.json" disk.kind)" == "chunk-index-disk-v0" ]] || \
    die "${kind} save did not record a writable disk index"

  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${source_name}" -- \
    /bin/sh -lc 'printf continued > /var/sporevm-save-point; sync'
  [[ "$(SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${source_name}" -- /bin/cat /var/sporevm-save-point)" == "continued" ]] || \
    die "${kind} source did not observe its post-save disk mutation"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${source_name}" >/dev/null

  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" restore "${saved_dir}" \
    --name "${restored_name}" --backend "${backend}" \
    >"${workdir}/${kind}-restore.stdout" 2>"${workdir}/${kind}-restore.stderr"; then
    cat "${workdir}/${kind}-restore.stdout" >&2 || true
    cat "${workdir}/${kind}-restore.stderr" >&2 || true
    die "${kind} point-in-time restore failed"
  fi
  expect_named_online_cpus "${restored_name}" "${kind}-restored-cpus-online"
  [[ "$(SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${restored_name}" -- /bin/cat /var/sporevm-save-point)" == "captured" ]] || \
    die "${kind} restore did not preserve the saved point-in-time disk state"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${restored_name}" >/dev/null
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm --spore "${saved_dir}" >/dev/null
}

# expect_still_ticking NAME PREFIX -> assert the guest counter advances, proving
# the VM is still running and executing the workload.
expect_still_ticking() {
  local name="$1"
  local prefix="$2"
  local out="${workdir}/${prefix}-tick"
  local before after numbers
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" exec "${name}" -- /bin/sh -c 'before="$(cat /tick)"; sleep 3; after="$(cat /tick)"; echo "$before $after"' \
    >"${out}" 2>"${out}.err" || {
    cat "${out}" >&2 || true
    cat "${out}.err" >&2 || true
    die "failed to observe /tick progress from ${name}"
  }
  numbers="$(tr -cs '0-9' ' ' <"${out}")"
  read -r before after <<<"${numbers}"
  [[ -n "${before}" && -n "${after}" ]] || {
    cat "${out}" >&2 || true
    die "no numeric tick pair observed from ${name}"
  }
  (( after > before )) || die "${name} is not ticking (before=${before} after=${after})"
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
(( vcpus > 1 )) || die "multi-vCPU smoke requires SPORE_SMOKE_VCPUS greater than 1"
online_cpu_command=(/bin/sh -c 'printf "spore cpus-online "; cat /sys/devices/system/cpu/online')
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-multi-vcpu.XXXXXX")"
# Keep the runtime dir short: control socket paths must fit the 104-byte
# macOS sun_path limit, and macOS TMPDIR lives under a deep /var/folders path.
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-mvcpu.XXXXXX")"
chmod 700 "${runtime_dir}"
if [[ "${SPORE_SMOKE_NAMED_LIFECYCLE:-0}" == "1" ]]; then
  exact_spore_bin="$(cd "$(dirname "${spore_bin}")" && pwd -P)/$(basename "${spore_bin}")"
  debug_spore_bin="${workdir}/spore-debug"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exact_spore=%q\n' "${exact_spore_bin}"
    printf 'exec -a "$0" "$exact_spore" --debug "$@"\n'
  } >"${debug_spore_bin}"
  chmod 700 "${debug_spore_bin}"
  spore_bin="${debug_spore_bin}"
fi
vm_name="mvcpus-${backend}"
forked_name="${vm_name}-forked"
resumed_name="${vm_name}-resumed"
cleanup() {
  local status="$?"
  if [[ -d "${runtime_dir}" ]]; then
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${forked_name}" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${resumed_name}" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}-image" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}-image-restored" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}-explicit-rootfs" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}-explicit-rootfs-restored" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}-auto" >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
    for saved_dir in "${workdir}/image.spore" "${workdir}/explicit-rootfs.spore" "${workdir}/auto.spore"; do
      [[ -d "${saved_dir}" ]] || continue
      SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm --spore "${saved_dir}" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${SPORE_SMOKE_KEEP_WORKDIR:-0}" == "1" || "${status}" != "0" ]]; then
    echo "kept smoke workdir: ${workdir} runtime_dir=${runtime_dir}" >&2
    exit "${status}"
  fi
  rm -rf "${runtime_dir}" "${workdir}"
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
  --save "${from_base_dir}" \
  -- /bin/true \
  >"${workdir}/from-base.stdout" 2>"${workdir}/from-base.stderr"; then
  cat "${workdir}/from-base.stdout" >&2 || true
  cat "${workdir}/from-base.stderr" >&2 || true
  die "multi-vCPU run --save base failed"
fi
expect_manifest_v3 "${from_base_dir}"

fork_dir="${workdir}/v3-children"
fork_child_stdout="${workdir}/fork-child.stdout"
fork_child_stderr="${workdir}/fork-child.stderr"
if ! "${spore_bin}" fork "${from_base_dir}" --count 2 --out "${fork_dir}" \
  >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"; then
  cat "${workdir}/fork.stdout" >&2 || true
  cat "${workdir}/fork.stderr" >&2 || true
  die "multi-vCPU fork failed"
fi
expect_manifest_v3 "${fork_dir}/000000"
expect_manifest_v3 "${fork_dir}/000001"

if ! "${spore_bin}" run \
  --backend "${backend}" \
  --events=jsonl \
  --from "${fork_dir}/000000" \
  -- /bin/writeout \
  >"${fork_child_stdout}" 2>"${fork_child_stderr}"; then
  cat "${fork_child_stdout}" >&2 || true
  cat "${fork_child_stderr}" >&2 || true
  die "multi-vCPU fork child run --from failed"
fi
jsonl_output_contains "${fork_child_stdout}" stdout "spore stdout" || die "multi-vCPU fork child run --from did not emit stdout"
jsonl_output_contains "${fork_child_stdout}" stderr "spore stderr" || die "multi-vCPU fork child run --from did not emit stderr"

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
  --save "${capture_dir}" \
  --save-on USR1 \
  -- /bin/finite \
  >"${capture_events_pipe}" 2>"${capture_stderr}" &
capture_pid="$!"

if ! python3 "${repo_root}/scripts/internal/capture-on-output-marker.py" --pid "${capture_pid}" --signal USR1 --event stdout --contains "spore finite ready" --out "${capture_stdout}" <"${capture_events_pipe}"; then
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
expect_manifest_v3 "${capture_dir}"

resume_stdout="${workdir}/resume.stdout"
resume_stderr="${workdir}/resume.stderr"
if ! "${spore_bin}" attach --events=jsonl --backend "${backend}" "${capture_dir}" >"${resume_stdout}" 2>"${resume_stderr}"; then
  cat "${resume_stdout}" >&2 || true
  cat "${resume_stderr}" >&2 || true
  die "multi-vCPU attach failed"
fi
jsonl_output_contains "${resume_stdout}" stdout "spore finite" || {
  cat "${resume_stdout}" >&2 || true
  cat "${resume_stderr}" >&2 || true
  die "multi-vCPU attach did not continue the saved workload"
}
grep -Fq '"exit_code":0' "${resume_stdout}" || die "multi-vCPU attach did not report exit_code 0"

if [[ "${SPORE_SMOKE_NAMED_LIFECYCLE:-0}" == "1" ]]; then
  named_dir="${workdir}/named.spore"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" create "${vm_name}" --backend "${backend}" --vcpus "${vcpus}" --memory "${memory}" --timeout "${create_timeout_ms}ms" >"${workdir}/create.stdout" 2>"${workdir}/create.stderr"; then
    cat "${workdir}/create.stdout" >&2 || true
    cat "${workdir}/create.stderr" >&2 || true
    die "multi-vCPU named create failed"
  fi
  expect_named_online_cpus "${vm_name}" "exec-cpus-online"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" fork --vm "${vm_name}" --count 1 --name "${forked_name}" >"${workdir}/named-fork.stdout" 2>"${workdir}/named-fork.stderr"; then
    cat "${workdir}/named-fork.stdout" >&2 || true
    cat "${workdir}/named-fork.stderr" >&2 || true
    die "multi-vCPU named fork failed"
  fi
  expect_named_online_cpus "${forked_name}" "forked-cpus-online"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${forked_name}" >/dev/null

  # Non-destructive multi-vCPU save for an exec-ready VM: save it WITHOUT
  # --stop, confirm the source VM remains registered, then restore the saved
  # spore under a second name while the source is still alive.
  concurrent_name="${vm_name}-saved"
  concurrent_dir="${workdir}/named-live.spore"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" save "${vm_name}" --out "${concurrent_dir}" >"${workdir}/named-live-save.stdout" 2>"${workdir}/named-live-save.stderr"; then
    cat "${workdir}/named-live-save.stdout" >&2 || true
    cat "${workdir}/named-live-save.stderr" >&2 || true
    die "multi-vCPU named non-destructive save failed"
  fi
  expect_manifest_v3 "${concurrent_dir}"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" ls >"${workdir}/named-live-ls.stdout" 2>"${workdir}/named-live-ls.stderr"; then
    cat "${workdir}/named-live-ls.stdout" >&2 || true
    cat "${workdir}/named-live-ls.stderr" >&2 || true
    die "spore ls failed after multi-vCPU named non-destructive save"
  fi
  grep -Fq "${vm_name}" "${workdir}/named-live-ls.stdout" || {
    cat "${workdir}/named-live-ls.stdout" >&2 || true
    die "non-destructive save removed ${vm_name} from the registry"
  }
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" restore "${concurrent_dir}" --name "${concurrent_name}" >"${workdir}/named-live-restore.stdout" 2>"${workdir}/named-live-restore.stderr"; then
    cat "${workdir}/named-live-restore.stdout" >&2 || true
    cat "${workdir}/named-live-restore.stderr" >&2 || true
    die "multi-vCPU restore of non-destructive save failed"
  fi
  expect_named_online_cpus "${concurrent_name}" "named-live-cpus-online"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${concurrent_name}" >/dev/null

  # Prove a disk-backed non-destructive save is a point-in-time boundary for
  # both public named-rootfs sources. The continuing VM mutates the same file
  # after save; restore must still observe the captured value.
  disk_image="${SPORE_SMOKE_MULTI_VCPU_DISK_IMAGE:-docker.io/library/alpine:3.20}"
  disk_platform="${SPORE_SMOKE_MULTI_VCPU_DISK_PLATFORM:-linux/arm64}"
  if [[ "${disk_image}" == *@sha256:* ]]; then
    resolved_disk_image="${disk_image}"
  else
    resolved_disk_image="$("${spore_bin}" rootfs resolve "${disk_image}" --platform "${disk_platform}")"
  fi
  run_disk_point_in_time_case image --image "${resolved_disk_image}"
  explicit_rootfs="${workdir}/explicit-rootfs.ext4"
  "${spore_bin}" rootfs build "${resolved_disk_image}" \
    --platform "${disk_platform}" \
    --output "${explicit_rootfs}" \
    >"${workdir}/explicit-rootfs-build.stdout" 2>"${workdir}/explicit-rootfs-build.stderr"
  run_disk_point_in_time_case explicit-rootfs --rootfs "${explicit_rootfs}"

  # The default memory contract is auto/16GiB. Keep this as a separate sparse
  # diskless save so the native gate records its complete source pause without
  # conflating it with rootfs publication work.
  auto_name="${vm_name}-auto"
  auto_dir="${workdir}/auto.spore"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" create "${auto_name}" \
    --backend "${backend}" \
    --vcpus "${vcpus}" \
    --timeout "${create_timeout_ms}ms" \
    >"${workdir}/auto-create.stdout" 2>"${workdir}/auto-create.stderr"; then
    cat "${workdir}/auto-create.stdout" >&2 || true
    cat "${workdir}/auto-create.stderr" >&2 || true
    die "default-memory multi-vCPU named create failed"
  fi
  expect_named_online_cpus "${auto_name}" "auto-cpus-online"
  save_named_with_metrics "${auto_name}" "${auto_dir}" "default-auto-memory"
  [[ "$(manifest_field "${auto_dir}/manifest.json" platform.ram_size)" == "17179869184" ]] || \
    die "default-memory save did not preserve the 16GiB auto contract"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${auto_name}" >/dev/null
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm --spore "${auto_dir}" >/dev/null

  # Non-destructive multi-vCPU save of an active workload: prove the source VM
  # stays registered and keeps ticking after save, then remove the source and
  # verify the point-in-time spore restores and preserves the captured workload
  # state. `expect_manifest_v3` above verifies the saved vCPU topology; the first
  # post-restore exec may run under the restored file-stdio affinity gate.
  live_name="${vm_name}-live"
  live_restored_name="${vm_name}-live-restored"
  live_dir="${workdir}/live.spore"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" create "${live_name}" --backend "${backend}" --vcpus "${vcpus}" --memory "${memory}" --timeout "${create_timeout_ms}ms" 'i=0; while true; do echo "$i" > /tick; i=$((i + 1)); sleep 1; done' >"${workdir}/live-create.stdout" 2>"${workdir}/live-create.stderr"; then
    cat "${workdir}/live-create.stdout" >&2 || true
    cat "${workdir}/live-create.stderr" >&2 || true
    die "multi-vCPU live create failed"
  fi
  # The workload must be ticking before the save so the save captures a running guest.
  expect_still_ticking "${live_name}" "live-pre-save"
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" save "${live_name}" --out "${live_dir}" >"${workdir}/live-save.stdout" 2>"${workdir}/live-save.stderr"; then
    cat "${workdir}/live-save.stdout" >&2 || true
    cat "${workdir}/live-save.stderr" >&2 || true
    die "multi-vCPU non-destructive save failed"
  fi
  expect_manifest_v3 "${live_dir}"
  # The source VM must still be registered as ready after a non-destructive save.
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" ls >"${workdir}/live-ls.stdout" 2>"${workdir}/live-ls.stderr"; then
    cat "${workdir}/live-ls.stdout" >&2 || true
    cat "${workdir}/live-ls.stderr" >&2 || true
    die "spore ls failed after non-destructive save"
  fi
  grep -Fq "${live_name}" "${workdir}/live-ls.stdout" || {
    cat "${workdir}/live-ls.stdout" >&2 || true
    die "non-destructive save removed ${live_name} from the registry"
  }
  # The source VM must still be running the workload after the save.
  expect_still_ticking "${live_name}" "live-post-save"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${live_name}" >/dev/null
  # The saved spore must restore and keep ticking (the running workload was
  # captured in the spore's memory state).
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" restore "${live_dir}" --name "${live_restored_name}" >"${workdir}/live-restore.stdout" 2>"${workdir}/live-restore.stderr"; then
    cat "${workdir}/live-restore.stdout" >&2 || true
    cat "${workdir}/live-restore.stderr" >&2 || true
    die "multi-vCPU restore of non-destructive save failed"
  fi
  expect_still_ticking "${live_restored_name}" "live-restored"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${live_restored_name}" >/dev/null

  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" save "${vm_name}" --out "${named_dir}" --stop >"${workdir}/suspend.stdout" 2>"${workdir}/suspend.stderr"; then
    cat "${workdir}/suspend.stdout" >&2 || true
    cat "${workdir}/suspend.stderr" >&2 || true
    die "multi-vCPU named save --stop failed"
  fi
  expect_manifest_v3 "${named_dir}"
  # Multi-vCPU stopped saves write v3 manifests; inspect must accept everything
  # restore accepts.
  if ! "${spore_bin}" --json inspect "${named_dir}" >"${workdir}/inspect.json" 2>"${workdir}/inspect.stderr"; then
    cat "${workdir}/inspect.json" >&2 || true
    cat "${workdir}/inspect.stderr" >&2 || true
    die "spore inspect rejected a multi-vCPU save that restore accepts"
  fi
  grep -Eq '"vcpu_count": *'"${vcpus}" "${workdir}/inspect.json" || {
    cat "${workdir}/inspect.json" >&2 || true
    die "spore inspect did not report the saved vCPU count"
  }
  if ! SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" restore "${named_dir}" --name "${resumed_name}" >"${workdir}/named-resume.stdout" 2>"${workdir}/named-resume.stderr"; then
    cat "${workdir}/named-resume.stdout" >&2 || true
    cat "${workdir}/named-resume.stderr" >&2 || true
    die "multi-vCPU named restore failed"
  fi
  expect_named_online_cpus "${resumed_name}" "named-cpus-online"
  SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${resumed_name}" >/dev/null
fi

echo "smoke:multi-vcpu ok backend=${backend} vcpus=${vcpus}"
