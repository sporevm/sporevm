#!/usr/bin/env bash
# Pushes a local image holding a large random file to a directory store, serves
# the store over loopback HTTP, and runs the image with an empty rootfs cache.
# The run must fetch only the objects the guest reads, and a warm rerun fetches
# nothing. A named VM boots the same way; `spore save` fails and leaves it
# running while the store lacks an object, then succeeds. `run --save` fails
# without leaving a save directory while the store lacks an object; from an
# empty cache it fetches the rest of the image, so the saved spore runs after
# the store is gone, and a store without its objects fails the run. Prints run
# times and the bytes fetched against the image's object bytes. Needs zig (to
# build the guest program) and python3, but no registry.
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
const linux = std.os.linux;

/// `hello PATH BYTES` first reads the first BYTES bytes of PATH in order.
pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len == 3) {
        var left = std.fmt.parseInt(usize, std.mem.span(argv[2]), 10) catch return 2;
        const fd = linux.open(argv[1], .{}, 0);
        if (linux.errno(fd) != .SUCCESS) return 1;
        var buf: [1 << 16]u8 = undefined;
        while (left > 0) {
            const n = linux.read(@intCast(fd), &buf, @min(buf.len, left));
            if (linux.errno(n) != .SUCCESS or n == 0) return 1;
            left -= n;
        }
    }
    const message = "remote-lazy-ok\n";
    _ = linux.write(1, message, message.len);
    return 0;
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

# `python3 -m http.server` with a listen backlog above its 5: a fault opens 8
# connections at once and a save 16, and Linux retries connections past the
# backlog a second later.
python3 -u - "${workdir}/store" >"${workdir}/server.out" 2>"${workdir}/server.err" <<'PY' &
import functools
import http.server
import sys


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 128


handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with Server(("127.0.0.1", 0), handler) as server:
    print(f"port {server.server_address[1]}")
    server.serve_forever()
PY
server_pid=$!
port=""
for _ in $(seq 1 100); do
  port="$(sed -n 's/^port \([0-9][0-9]*\)$/\1/p' "${workdir}/server.out")"
  [[ -n "${port}" ]] && break
  sleep 0.1
done
[[ -n "${port}" ]] || die "image store server did not start"
store_ref="http://127.0.0.1:${port}/demo"

# Warm the managed kernel so the timings below measure the rootfs alone.
"${spore_bin}" run --backend "${backend}" -- /bin/true

# run_image NAME IMAGE [RUN FLAGS...] -- COMMAND... runs COMMAND from IMAGE
# with a rootfs trace, writes NAME.stdout, NAME.stderr and NAME.ms (wall time),
# and returns the run's status.
run_image() {
  local name="$1" image="$2"
  shift 2
  SPOREVM_ROOTFS_TRACE="${workdir}/${name}.trace.jsonl" SPOREVM_ROOTFS_TRACE_SUMMARY_ONLY=1 \
    python3 - "${workdir}/${name}" "${spore_bin}" run --backend "${backend}" --image "${image}" "$@" <<'PY'
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
run_image local local/remote-lazy:1 -- /hello || require_success $? "local run" "${workdir}/local.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/local.stdout")" "local run output"

export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/consumer-cache"
run_image cold "${store_ref}" -- /hello || require_success $? "cold remote run" "${workdir}/cold.stderr"
cold_ms="$(cat "${workdir}/cold.ms")"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/cold.stdout")" "cold remote run output"
cold_fetches="$(trace_field "${workdir}/cold.trace.jsonl" remote_fetches)"
cold_bytes="$(trace_field "${workdir}/cold.trace.jsonl" remote_bytes)"
cold_window_fetches="$(trace_field "${workdir}/cold.trace.jsonl" remote_window_fetches)"
cold_window_unused="$(trace_field "${workdir}/cold.trace.jsonl" remote_window_unused)"
expect_eq 0 "$(trace_field "${workdir}/cold.trace.jsonl" remote_errors)" "cold remote fetch errors"
((cold_fetches > 0)) || die "cold run fetched no objects"
((cold_fetches < objects_total / 10)) || die "cold run fetched ${cold_fetches} of ${objects_total} objects"
served="$(grep -c '"GET /objects/blake3/' "${workdir}/server.err" || true)"
expect_eq "${cold_fetches}" "${served}" "objects the store served"

run_image warm "${store_ref}" -- /hello || require_success $? "warm remote run" "${workdir}/warm.stderr"
warm_ms="$(cat "${workdir}/warm.ms")"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/warm.stdout")" "warm remote run output"
expect_eq 0 "$(trace_field "${workdir}/warm.trace.jsonl" remote_fetches)" "warm remote fetches"

# A cold sequential read of the blob's first 32 MiB: the case fault windows
# are for.
seq_mib=$((blob_mib < 32 ? blob_mib : 32))
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/seq-cache"
run_image seq "${store_ref}" -- /hello /data/blob $((seq_mib * 1024 * 1024)) ||
  require_success $? "cold sequential read" "${workdir}/seq.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/seq.stdout")" "cold sequential read output"
expect_eq 0 "$(trace_field "${workdir}/seq.trace.jsonl" remote_errors)" "cold sequential read fetch errors"
seq_ms="$(cat "${workdir}/seq.ms")"
seq_fetches="$(trace_field "${workdir}/seq.trace.jsonl" remote_fetches)"
seq_window_fetches="$(trace_field "${workdir}/seq.trace.jsonl" remote_window_fetches)"
seq_window_unused="$(trace_field "${workdir}/seq.trace.jsonl" remote_window_unused)"

# A named VM boots from the store the same way.
named() {
  SPOREVM_ROOTFS_CACHE_DIR="${workdir}/named-cache" SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" "$@"
}
named_exec() {
  run_capture "${workdir}/$1.stdout" "${workdir}/$1.stderr" named exec "${vm_name}" -- /hello ||
    require_success $? "$1" "${workdir}/$1.stderr"
  expect_eq "remote-lazy-ok" "$(cat "${workdir}/$1.stdout")" "$1 output"
}
run_capture "${workdir}/create.stdout" "${workdir}/create.stderr" \
  named create "${vm_name}" --backend "${backend}" --image "${store_ref}" -- /hello ||
  require_success $? "create from the store" "${workdir}/create.stderr"
vm_created=1
named_exec exec
# While the store lacks an object the guest has not read, the save fails
# before the guest pauses and the VM keeps running.
unread=""
for object in "${workdir}"/store/objects/blake3/*; do
  if [[ ! -e "${workdir}/named-cache/cas/rootfs/blake3/objects/$(basename "${object}").chunk" ]]; then
    unread="${object}"
    break
  fi
done
[[ -n "${unread}" ]] || die "the named VM read every object of the image"
mv "${unread}" "${workdir}/unread.hidden"
if run_capture "${workdir}/named-save-lost.stdout" "${workdir}/named-save-lost.stderr" \
  named save "${vm_name}" --out "${workdir}/named-lost.spore"; then
  die "spore save succeeded while the store lacked an object"
fi
grep -Fq "was not saved" "${workdir}/named-save-lost.stderr" || {
  cat "${workdir}/named-save-lost.stderr" >&2
  die "spore save without a store object did not explain the failure"
}
named_exec exec-after-failed-save
mv "${workdir}/unread.hidden" "${unread}"
# With the object back, both kinds of save fetch the rest and succeed.
run_capture "${workdir}/named-save.stdout" "${workdir}/named-save.stderr" \
  named save "${vm_name}" --out "${workdir}/named.spore" ||
  require_success $? "spore save of a VM created from the store" "${workdir}/named-save.stderr"
named_exec exec-after-save
run_capture "${workdir}/named-save-stop.stdout" "${workdir}/named-save-stop.stderr" \
  named save "${vm_name}" --out "${workdir}/named-stop.spore" --stop ||
  require_success $? "spore save --stop of a VM created from the store" "${workdir}/named-save-stop.stderr"
vm_created=0

# A save the store cannot complete fails and leaves no save directory.
mv "${unread}" "${workdir}/unread.hidden"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/lost-save-cache"
if run_image lost-save "${store_ref}" --save "${workdir}/lost.spore" -- /hello; then
  die "run --save succeeded while the store lacked an object"
fi
grep -Fq "nothing was saved" "${workdir}/lost-save.stderr" || {
  cat "${workdir}/lost-save.stderr" >&2
  die "run --save without a store object did not explain the failure"
}
[[ ! -e "${workdir}/lost.spore" ]] || die "run --save left a save directory after the store failed"
mv "${workdir}/unread.hidden" "${unread}"

# A save from an empty cache fetches the rest of the image. The save path
# is relative, as users type it.
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/save-cache"
(cd "${workdir}" && run_image save "${store_ref}" --save saved.spore -- /hello) ||
  require_success $? "run --save from the store" "${workdir}/save.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/save.stdout")" "run --save output"
save_ms="$(cat "${workdir}/save.ms")"
expect_eq "${objects_total}" "$(trace_field "${workdir}/save.trace.jsonl" remote_fetches)" "objects fetched by run --save"

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

# The saved spore needs nothing from the store.
kill "${server_pid}"
wait "${server_pid}" 2>/dev/null || true
server_pid=""
run_capture "${workdir}/from.stdout" "${workdir}/from.stderr" \
  "${spore_bin}" run --backend "${backend}" --from "${workdir}/saved.spore" -- /hello ||
  require_success $? "run --from a spore saved from the store" "${workdir}/from.stderr"
expect_eq "remote-lazy-ok" "$(cat "${workdir}/from.stdout")" "run --from output"
(cd "${workdir}" && "${spore_bin}" fork saved.spore --count 1 --out children >fork.stdout 2>fork.stderr) ||
  require_success $? "fork with a relative --out" "${workdir}/fork.stderr"
[[ -f "${workdir}/children/000000/manifest.json" ]] || die "fork with a relative --out wrote no child"

python3 - <<PY
object_bytes = ${object_bytes}
cold_bytes = ${cold_bytes}
print(f"remote-lazy: image ${image_digest}: ${objects_total} objects, {object_bytes} object bytes, ${index_bytes} index bytes")
print(f"remote-lazy: cold run ${cold_ms} ms, fetched ${cold_fetches} objects, {cold_bytes} bytes ({100 * cold_bytes / object_bytes:.2f}% of object bytes)")
print(f"remote-lazy: cold run windows fetched ${cold_window_fetches} objects, ${cold_window_unused} never read")
print(f"remote-lazy: warm run ${warm_ms} ms; fully local run $(cat "${workdir}/local.ms") ms")
print(f"remote-lazy: cold ${seq_mib} MiB sequential read ${seq_ms} ms, fetched ${seq_fetches} objects; windows fetched ${seq_window_fetches}, ${seq_window_unused} never read")
print(f"remote-lazy: run --save from an empty cache ${save_ms} ms, fetching all ${objects_total} objects")
PY
echo "smoke:remote-lazy ok"
