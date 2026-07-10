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
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
mkdir -p "${SPOREVM_RUNTIME_DIR}" "${SPOREVM_ROOTFS_CACHE_DIR}"
chmod 700 "${SPOREVM_RUNTIME_DIR}"

cleanup() {
  local status="$?"
  for name in postrestore postprune restored grandchild child-1 child-0 source; do
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
  -- /bin/sh -lc 'while true; do sleep 3600; done'
"${spore_bin}" exec source -- /bin/sh -lc 'printf inherited > /fork-marker; sync'

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

echo "smoke:named-disk-fork ok backend=${backend} image=${image_ref}"
