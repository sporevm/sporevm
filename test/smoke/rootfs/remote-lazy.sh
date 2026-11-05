#!/usr/bin/env bash
# Pushes a local image holding a large random file to a directory store, serves
# the store over loopback HTTP, and runs the image with an empty rootfs cache.
# The run must fetch only the objects the guest reads; a warm rerun fetches
# nothing, --save is refused, a named VM boots the same way and survives a
# refused `spore save`, and a store without its objects fails the run. Prints
# run times and the bytes fetched against the image's object bytes. Needs zig
# (to build the guest program) and python3, but no registry.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin
command -v zig >/dev/null || die "zig is required to build the guest program"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-remote-lazy"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-rl"
blob_mib="${SPORE_SMOKE_REMOTE_LAZY_BLOB_MIB:-256}"
server_pid=""
vm_name="remote-lazy-$$"
vm_created=0

cleanup() {
  if ((vm_created)); then
    SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}

# trace_field TRACE FIELD prints one field of the run's lazy fault summary.
trace_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

summary = None
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        event = json.loads(line)
        if event.get("event") == "lazy_cas_fault_summary":
            summary = event
if summary is None:
    sys.exit("no lazy_cas_fault_summary in " + sys.argv[1])
print(summary[sys.argv[2]])
PY
}

# A static Linux program, so the image needs no userland.
mkdir -p "${workdir}/rootfs"
cat >"${workdir}/hello.zig" <<'EOF'
const std = @import("std");

pub fn main() void {
    const message = "remote-lazy-ok\n";
    _ = std.os.linux.write(1, message, message.len);
}
EOF
case "$(uname -m)" in
  arm64 | aarch64) guest_arch=aarch64 platform=linux/arm64 ;;
  x86_64) guest_arch=x86_64 platform=linux/amd64 ;;
  *) die "unsupported host architecture $(uname -m)" ;;
esac
zig build-exe "${workdir}/hello.zig" -target "${guest_arch}-linux" -O ReleaseSmall -fstrip \
  --cache-dir "${workdir}/zig-cache" -femit-bin="${workdir}/rootfs/hello" >/dev/null

python3 - "${workdir}/rootfs/hello" "${workdir}/rootfs.tar" "${blob_mib}" <<'PY'
import io
import os
import sys
import tarfile

hello, output, blob_mib = sys.argv[1], sys.argv[2], int(sys.argv[3])
with tarfile.open(output, "w", format=tarfile.USTAR_FORMAT) as tar:
    tar.add(hello, arcname="hello")
    for name in ("data", "dev", "proc", "sys", "tmp"):
        info = tarfile.TarInfo(name)
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        tar.addfile(info)
    blob = os.urandom(blob_mib * 1024 * 1024)
    info = tarfile.TarInfo("data/blob")
    info.size = len(blob)
    info.mode = 0o644
    tar.addfile(info, io.BytesIO(blob))
PY

export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/producer-cache"
"${spore_bin}" rootfs import-tar "${workdir}/rootfs.tar" --ref local/remote-lazy:1 --platform "${platform}" >/dev/null
"${spore_bin}" --json image push local/remote-lazy:1 "${workdir}/store/demo" >"${workdir}/push.json"
objects_total="$(json_field "${workdir}/push.json" objects_total)"
object_bytes="$(json_field "${workdir}/push.json" bytes_written)"
image_digest="$(json_field "${workdir}/push.json" image_digest)"
index_bytes="$(wc -c <"${workdir}/store/images/${image_digest#blake3:}/index" | tr -d ' ')"

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "${workdir}/store" \
  >"${workdir}/server.out" 2>"${workdir}/server.err" &
server_pid=$!
port=""
for _ in $(seq 1 100); do
  port="$(sed -n 's/^Serving HTTP on .* port \([0-9][0-9]*\) .*/\1/p' "${workdir}/server.out")"
  [[ -n "${port}" ]] && break
  sleep 0.1
done
[[ -n "${port}" ]] || die "image store server did not start"
store_ref="http://127.0.0.1:${port}/demo"

# Warm the managed kernel so the timings below measure the rootfs alone.
"${spore_bin}" run --backend "${backend}" -- /bin/true

# run_image NAME IMAGE [RUN FLAGS...] runs /hello from IMAGE with a rootfs
# trace, writes NAME.stdout, NAME.stderr and NAME.ms (wall time), and returns
# the run's status.
run_image() {
  local name="$1" image="$2"
  shift 2
  SPOREVM_ROOTFS_TRACE="${workdir}/${name}.trace.jsonl" SPOREVM_ROOTFS_TRACE_SUMMARY_ONLY=1 \
    python3 - "${workdir}/${name}" "${spore_bin}" run --backend "${backend}" --image "${image}" "$@" -- /hello <<'PY'
import subprocess
import sys
import time

prefix = sys.argv[1]
start = time.monotonic()
with open(prefix + ".stdout", "wb") as out, open(prefix + ".stderr", "wb") as err:
    status = subprocess.run(sys.argv[2:], stdout=out, stderr=err).returncode
with open(prefix + ".ms", "w", encoding="utf-8") as f:
    f.write(f"{round((time.monotonic() - start) * 1000)}\n")
sys.exit(status if status >= 0 else 128 - status)
PY
}

# The same image fully local, for comparison.
run_image local local/remote-lazy:1 || require_success $? "local run" "${workdir}/local.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/local.stdout")" "local run output"

export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/consumer-cache"
run_image cold "${store_ref}" || require_success $? "cold remote run" "${workdir}/cold.stderr"
cold_ms="$(cat "${workdir}/cold.ms")"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/cold.stdout")" "cold remote run output"
cold_fetches="$(trace_field "${workdir}/cold.trace.jsonl" remote_fetches)"
cold_bytes="$(trace_field "${workdir}/cold.trace.jsonl" remote_bytes)"
expect_eq 0 "$(trace_field "${workdir}/cold.trace.jsonl" remote_errors)" "cold remote fetch errors"
((cold_fetches > 0)) || die "cold run fetched no objects"
((cold_fetches < objects_total / 10)) || die "cold run fetched ${cold_fetches} of ${objects_total} objects"
served="$(grep -c '"GET /objects/blake3/' "${workdir}/server.err" || true)"
expect_eq "${cold_fetches}" "${served}" "objects the store served"

run_image warm "${store_ref}" || require_success $? "warm remote run" "${workdir}/warm.stderr"
warm_ms="$(cat "${workdir}/warm.ms")"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/warm.stdout")" "warm remote run output"
expect_eq 0 "$(trace_field "${workdir}/warm.trace.jsonl" remote_fetches)" "warm remote fetches"

if run_image save "${store_ref}" --save "${workdir}/saved.spore"; then
  die "--save from a partially local image succeeded"
fi
grep -Fq "refused for images run from a store" "${workdir}/save.stderr" || {
  cat "${workdir}/save.stderr" >&2
  die "--save from a partially local image did not explain the failure"
}

# A named VM boots from the store the same way.
named() {
  SPOREVM_ROOTFS_CACHE_DIR="${workdir}/named-cache" SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" "$@"
}
run_capture "${workdir}/create.stdout" "${workdir}/create.stderr" \
  named create "${vm_name}" --backend "${backend}" --image "${store_ref}" -- /hello ||
  require_success $? "create from the store" "${workdir}/create.stderr"
vm_created=1
run_capture "${workdir}/exec.stdout" "${workdir}/exec.stderr" named exec "${vm_name}" -- /hello ||
  require_success $? "exec in a VM created from the store" "${workdir}/exec.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/exec.stdout")" "named exec output"
# Saving it, with or without --stop, is refused and the VM keeps running.
for stop in "" --stop; do
  if run_capture "${workdir}/named-save${stop}.stdout" "${workdir}/named-save${stop}.stderr" \
    named save "${vm_name}" --out "${workdir}/named${stop}.spore" ${stop}; then
    die "spore save ${stop} of a VM created from the store succeeded"
  fi
  grep -Fq "runs an image from a store" "${workdir}/named-save${stop}.stderr" || {
    cat "${workdir}/named-save${stop}.stderr" >&2
    die "spore save ${stop} of a VM created from the store did not explain the failure"
  }
  run_capture "${workdir}/exec-after-save${stop}.stdout" "${workdir}/exec-after-save${stop}.stderr" named exec "${vm_name}" -- /hello ||
    require_success $? "exec after a refused spore save ${stop}" "${workdir}/exec-after-save${stop}.stderr"
  expect_eq "remote-lazy-ok" "$(cat "${workdir}/exec-after-save${stop}.stdout")" "exec after a refused spore save ${stop}"
done
run_capture "${workdir}/rm.stdout" "${workdir}/rm.stderr" named rm "${vm_name}" ||
  require_success $? "rm of a VM created from the store" "${workdir}/rm.stderr"
vm_created=0

# Without its objects the image cannot boot, and the run fails instead of hanging.
mv "${workdir}/store/objects" "${workdir}/objects.hidden"
set +e
SPOREVM_ROOTFS_CACHE_DIR="${workdir}/missing-cache" with_timeout 60 \
  "${spore_bin}" run --backend "${backend}" --image "${store_ref}" -- /hello \
  >"${workdir}/missing.stdout" 2>"${workdir}/missing.stderr"
missing_status=$?
set -e
((missing_status != 0)) || die "run without store objects succeeded"
((missing_status != 142)) || die "run without store objects hung"
[[ ! -s "${workdir}/missing.stdout" ]] || die "run without store objects printed guest output"

python3 - <<PY
object_bytes = ${object_bytes}
cold_bytes = ${cold_bytes}
print(f"remote-lazy: image ${image_digest}: ${objects_total} objects, {object_bytes} object bytes, ${index_bytes} index bytes")
print(f"remote-lazy: cold run ${cold_ms} ms, fetched ${cold_fetches} objects, {cold_bytes} bytes ({100 * cold_bytes / object_bytes:.2f}% of object bytes)")
print(f"remote-lazy: warm run ${warm_ms} ms; fully local run $(cat "${workdir}/local.ms") ms")
PY
echo "smoke:remote-lazy ok"
