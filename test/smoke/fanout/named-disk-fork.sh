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

expect_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || die "${label}: expected ${expected}, got ${actual}"
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

image_ref="${SPORE_SMOKE_NAMED_DISK_FORK_IMAGE:-docker.io/library/alpine:3.20}"
memory="${SPORE_SMOKE_NAMED_DISK_FORK_MEMORY:-512mb}"
work_root="${SPORE_SMOKE_NAMED_DISK_FORK_WORK_ROOT:-/tmp}"
workdir="$(mktemp -d "${work_root%/}/sporevm-named-disk-fork.XXXXXX")"
source_console_log="${workdir}/source-console.log"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
mkdir -p "${SPOREVM_RUNTIME_DIR}" "${SPOREVM_ROOTFS_CACHE_DIR}"
chmod 700 "${SPOREVM_RUNTIME_DIR}"
exact_spore_bin="$(cd "$(dirname "${spore_bin}")" && pwd -P)/$(basename "${spore_bin}")"
debug_spore_bin="${workdir}/spore-debug"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exact_spore=%q\n' "${exact_spore_bin}"
  printf 'exec -a "$0" "$exact_spore" --debug "$@"\n'
} >"${debug_spore_bin}"
chmod 700 "${debug_spore_bin}"
spore_bin="${debug_spore_bin}"
lock_pid=""
save_pid=""
lock_release=""

cleanup() {
  local status="$?"
  if [[ -n "${lock_release}" ]]; then
    touch "${lock_release}" 2>/dev/null || true
  fi
  if [[ -n "${save_pid}" ]]; then
    kill "${save_pid}" 2>/dev/null || true
    wait "${save_pid}" 2>/dev/null || true
  fi
  if [[ -n "${lock_pid}" ]]; then
    kill "${lock_pid}" 2>/dev/null || true
    wait "${lock_pid}" 2>/dev/null || true
  fi
  for name in repeated-nested repeated-restored postrestore postprune restored grandchild child-1 child-0 source; do
    "${spore_bin}" rm "${name}" >/dev/null 2>&1 || true
  done
  if [[ "${status}" != "0" ]]; then
    for log in "${SPOREVM_RUNTIME_DIR}"/vms/*/monitor.log; do
      [[ -f "${log}" ]] || continue
      echo "== ${log} ==" >&2
      tail -120 "${log}" >&2 || true
    done
  fi
  if [[ "${SPORE_SMOKE_NAMED_DISK_FORK_KEEP:-0}" == "1" ]]; then
    echo "kept workdir: ${workdir}" >&2
  else
    rm -rf "${workdir}"
  fi
  return "${status}"
}
trap cleanup EXIT

"${spore_bin}" create source \
  --backend "${backend}" \
  --memory "${memory}" \
  --image "${image_ref}" \
  --console-log "${source_console_log}" \
  -- /bin/sh -lc 'while true; do sleep 3600; done'
"${spore_bin}" exec source -- /bin/sh -lc 'printf inherited > /fork-marker; sync'

# Cache contention must be resolved before the source pause begins. Keep a
# guest-side counter moving while an external process owns the exact cache
# lock, then require the pending save to report the accumulated wait.
monitor_log="${SPOREVM_RUNTIME_DIR}/vms/source/monitor.log"
"${spore_bin}" exec source -- /bin/sh -lc 'nohup sh -c '\''i=0; while :; do i=$((i + 1)); printf "snapshot-lock-counter:%s\n" "$i" >/dev/console; sleep 0.05; done'\'' </dev/null >/dev/null 2>&1 &'
deadline=$((SECONDS + 10))
while ! grep -q 'snapshot-lock-counter:' "${source_console_log}"; do
  if (( SECONDS >= deadline )); then
    tail -80 "${source_console_log}" >&2 2>/dev/null || true
    tail -80 "${monitor_log}" >&2 2>/dev/null || true
    die "guest progress did not reach the configured console log"
  fi
  sleep 0.01
done
counter_before="$(grep -c 'snapshot-lock-counter:' "${source_console_log}")"
lock_ready="${workdir}/snapshot-lock.ready"
lock_release="${workdir}/snapshot-lock.release"
python3 - "${SPOREVM_ROOTFS_CACHE_DIR}/.sporevm-rootfs-cache.lock" "${lock_ready}" "${lock_release}" <<'PY' &
import fcntl
import pathlib
import sys
import time

lock_path, ready_path, release_path = map(pathlib.Path, sys.argv[1:])
lock_path.parent.mkdir(parents=True, exist_ok=True)
with lock_path.open("a+b") as lock_file:
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    ready_path.touch()
    while not release_path.exists():
        time.sleep(0.01)
PY
lock_pid="$!"
deadline=$((SECONDS + 10))
while [[ ! -f "${lock_ready}" ]]; do
  if (( SECONDS >= deadline )); then
    tail -80 "${source_console_log}" >&2 2>/dev/null || true
    tail -80 "${monitor_log}" >&2 2>/dev/null || true
    die "external cache-lock holder did not become ready"
  fi
  sleep 0.01
done
contention_save="${workdir}/contention.spore"
"${spore_bin}" save source --out "${contention_save}" >"${workdir}/contention-save.stdout" 2>"${workdir}/contention-save.stderr" &
save_pid="$!"
sleep 1
kill -0 "${save_pid}" 2>/dev/null || {
  cat "${workdir}/contention-save.stderr" >&2 || true
  touch "${lock_release}"
  wait "${lock_pid}" || true
  die "named save did not remain pending behind the held cache lock"
}
counter_during="$(grep -c 'snapshot-lock-counter:' "${source_console_log}")"
(( counter_during - counter_before >= 10 )) || die "guest counter did not advance while named save remained pending: before=${counter_before} during=${counter_during}"
touch "${lock_release}"
wait "${lock_pid}"
lock_pid=""
wait "${save_pid}"
save_pid=""
python3 - "${monitor_log}" <<'PY'
import re
import sys

lines = [line for line in open(sys.argv[1], encoding="utf-8") if "named snapshot publication metrics" in line]
assert lines, "missing named snapshot publication metrics"
match = re.search(r"cache_lock_wait_ms=(\d+).*source_pause_ms=(\d+)", lines[-1])
assert match, lines[-1]
wait_ms, pause_ms = map(int, match.groups())
assert wait_ms > 0, lines[-1]
print(f"named snapshot contention cache_lock_wait_ms={wait_ms} source_pause_ms={pause_ms}")
PY
"${spore_bin}" rm --spore "${contention_save}"

fork_json="${workdir}/fork.json"
"${spore_bin}" --json fork --vm source --count 2 --name 'child-%d' >"${fork_json}"
python3 - "${fork_json}" "${SPOREVM_RUNTIME_DIR}" <<'PY'
import base64
import json
import sys
from pathlib import Path

document = json.load(open(sys.argv[1], encoding="utf-8"))
assert document["children"] == ["child-0", "child-1"], document
metrics = ("ram_capture_ms", "disk_fork_ms", "source_pause_ms", "child_ready_ms")
for metric in metrics:
    assert isinstance(document.get(metric), int), (metric, document)
print("named disk fork metrics " + " ".join(f"{metric}={document[metric]}" for metric in metrics))

runtime_root = Path(sys.argv[2])
identities = []
for index, child in enumerate(document["children"]):
    spec = json.load(open(runtime_root / "vms" / child / "spec.json", encoding="utf-8"))
    assert spec["disk_fork_claim"] is None, spec
    assert spec["disk_baseline_lease"] is not None, spec
    manifest = json.load(open(Path(spec["resume_dir"]) / "manifest.json", encoding="utf-8"))
    assert manifest["disk"] is None, manifest
    generation = manifest["generation"]
    assert generation["interrupt_status"] != 0, generation
    params = json.loads(base64.b64decode(generation["params_b64"]))
    assert params["fork_index"] == index, params
    assert params["parallel_index"] == index, params
    assert params["fork_count"] == 2, params
    assert params["parallel_count"] == 2, params
    identities.append(params)

assert identities[0]["fork_batch_id"] == identities[1]["fork_batch_id"], identities
for field in ("vm_id", "hostname", "mac_seed", "mac_address"):
    assert identities[0][field] != identities[1][field], (field, identities)
PY

# The first request after resume must observe inherited disk state. This also
# prevents guest session replay from hiding the child's actual response.
expect_eq inherited "$("${spore_bin}" exec child-0 -- /bin/cat /fork-marker)" "child-0 inherited marker"
expect_eq inherited "$("${spore_bin}" exec child-1 -- /bin/cat /fork-marker)" "child-1 inherited marker"

"${spore_bin}" exec source -- /bin/sh -lc 'printf parent > /fork-marker; sync'
"${spore_bin}" exec child-0 -- /bin/sh -lc 'printf child0 > /fork-marker; sync'
expect_eq parent "$("${spore_bin}" exec source -- /bin/cat /fork-marker)" "parent divergent marker"
expect_eq child0 "$("${spore_bin}" exec child-0 -- /bin/cat /fork-marker)" "child-0 divergent marker"
expect_eq inherited "$("${spore_bin}" exec child-1 -- /bin/cat /fork-marker)" "child-1 isolated marker"

"${spore_bin}" fork --vm child-1 --count 1 --name grandchild
expect_eq inherited "$("${spore_bin}" exec grandchild -- /bin/cat /fork-marker)" "nested child marker"
"${spore_bin}" save grandchild --out "${workdir}/grandchild.spore"
"${spore_bin}" restore "${workdir}/grandchild.spore" --name restored --backend "${backend}"
expect_eq inherited "$("${spore_bin}" exec restored -- /bin/cat /fork-marker)" "restored nested child marker"

# Once the source is gone, live children and durable saves must remain the
# roots of their own immutable baselines.
"${spore_bin}" rm source
"${spore_bin}" --json cache gc --rootfs --force >"${workdir}/gc.json"
"${spore_bin}" --json system prune \
  --rootfs \
  --force \
  --max-bytes 0 \
  --include-digest-artifacts \
  --include-rootfs-chunks \
  >"${workdir}/prune.json"
expect_eq child0 "$("${spore_bin}" exec child-0 -- /bin/cat /fork-marker)" "post-prune child-0 marker"
expect_eq inherited "$("${spore_bin}" exec child-1 -- /bin/cat /fork-marker)" "post-prune child-1 marker"
expect_eq inherited "$("${spore_bin}" exec grandchild -- /bin/cat /fork-marker)" "post-prune nested child marker"
expect_eq inherited "$("${spore_bin}" exec restored -- /bin/cat /fork-marker)" "post-prune restored marker"

"${spore_bin}" rm grandchild
"${spore_bin}" rm restored
"${spore_bin}" fork --vm child-1 --count 1 --name postprune
expect_eq inherited "$("${spore_bin}" exec postprune -- /bin/cat /fork-marker)" "post-prune nested fork marker"
"${spore_bin}" save child-1 --out "${workdir}/after-prune.spore"
mv "${workdir}/after-prune.spore" "${workdir}/relocated-after-prune.spore"
"${spore_bin}" restore "${workdir}/relocated-after-prune.spore" --name postrestore --backend "${backend}"
expect_eq inherited "$("${spore_bin}" exec postrestore -- /bin/cat /fork-marker)" "post-prune save/restore marker"

# A repeated non-destructive save must publish a complete new global-CAS
# baseline before its pin becomes visible. Removing the first save and forcing
# collection cannot break the source monitor's lease; the second save must
# restore with the same exact descriptor/root and remain eligible for nested
# fast fork.
first_repeat_dir="${workdir}/repeat-first.spore"
second_repeat_dir="${workdir}/repeat-second.spore"
"${spore_bin}" save child-1 --out "${first_repeat_dir}"
"${spore_bin}" rm --spore "${first_repeat_dir}"
"${spore_bin}" --json cache gc --rootfs --force >"${workdir}/repeat-gc.json"
"${spore_bin}" --json system prune \
  --rootfs \
  --force \
  --max-bytes 0 \
  --include-digest-artifacts \
  --include-rootfs-chunks \
  >"${workdir}/repeat-prune.json"
expect_eq inherited "$("${spore_bin}" exec child-1 -- /bin/cat /fork-marker)" "continued source after first save removal"
"${spore_bin}" exec child-1 -- /bin/sh -lc 'printf repeated > /fork-marker; sync'
"${spore_bin}" save child-1 --out "${second_repeat_dir}"

assert_pinned_runtime_authority() {
  local save_dir="$1"
  local vm_name="$2"
  python3 - "${save_dir}" "${vm_name}" "${SPOREVM_ROOTFS_CACHE_DIR}" "${SPOREVM_RUNTIME_DIR}" <<'PY'
import json
import pathlib
import sys

save, vm_name, cache, runtime = sys.argv[1:]
save = pathlib.Path(save)
cache = pathlib.Path(cache).resolve()
runtime = pathlib.Path(runtime)
manifest = json.load(open(save / "manifest.json", encoding="utf-8"))
disk = manifest["disk"]
ref = json.load(open(save / "sporevm-disk-pin.json", encoding="utf-8"))
pin = json.load(open(cache / "pins" / (ref["id"] + ".json"), encoding="utf-8"))
spec = json.load(open(runtime / "vms" / vm_name / "spec.json", encoding="utf-8"))
lease = spec["disk_baseline_lease"]
storage = pin["storage"]

assert pin["id"] == ref["id"], (pin, ref)
assert pin["storage"] == lease["rootfs_storage"], (pin, lease)
assert lease["store"] == "rootfs_cache", lease
assert pathlib.Path(lease["root"]).resolve() == cache, lease
assert lease["baseline_kind"] == "disk_index", lease
assert lease["baseline_identity"] == disk["base"], (lease, disk)
assert storage["index_digest"] == disk["base"], (storage, disk)
assert storage["base_identity"] == disk["base"], (storage, disk)
assert storage["logical_size"] == disk["size"], (storage, disk)
assert storage["chunk_size"] == disk["chunk_size"], (storage, disk)
assert storage["hash_algorithm"] == disk["hash_algorithm"], (storage, disk)
assert storage["object_namespace"] == disk["object_namespace"], (storage, disk)
assert storage["device"] == disk["device"], (storage, disk)

active = [json.load(open(path, encoding="utf-8")) for path in (runtime / "leases").glob("runtime-*.json")]
assert lease in active, (lease, active)
digest = disk["base"].split(":", 1)[1]
index = cache / "cas" / "rootfs" / "blake3" / "indexes" / (digest + ".json")
stamp = cache / "cas" / "rootfs" / "blake3" / "complete" / (digest + ".complete")
local_index = save / "cas" / "rootfs" / "blake3" / "indexes" / (digest + ".json")
assert index.is_file() and index.stat().st_size > 0, index
assert stamp.is_file() and stamp.read_text(encoding="utf-8") == "spore-rootfs-cas-complete-v1\n", stamp
assert not local_index.exists(), local_index
print(f"authority-ok vm={vm_name} pin={ref['id']} index={disk['base']} root={cache}")
PY
}

assert_pinned_runtime_authority "${second_repeat_dir}" child-1
"${spore_bin}" restore "${second_repeat_dir}" --name repeated-restored --backend "${backend}"
assert_pinned_runtime_authority "${second_repeat_dir}" repeated-restored
"${spore_bin}" fork --vm repeated-restored --count 1 --name repeated-nested
expect_eq repeated "$("${spore_bin}" exec repeated-nested -- /bin/cat /fork-marker)" "repeated-save nested restore marker"

echo "smoke:named-disk-fork ok backend=${backend} image=${image_ref}"
