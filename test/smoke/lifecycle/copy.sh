#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle-copy"
smoke_tempdir runtime_dir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-copy"

vm_name="copy-${backend}-$$"
created=0
cleanup() {
  if [[ "${created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" vm rm "${vm_name}" >/dev/null 2>&1 || true
  fi
}

printf 'spore copy smoke\n' >"${workdir}/source.txt"
mkdir -p "${workdir}/source-dir/nested" "${workdir}/source-dir/empty"
printf 'alpha\n' >"${workdir}/source-dir/root.txt"
printf '#!/bin/sh\necho copied\n' >"${workdir}/source-dir/nested/run.sh"
chmod 755 "${workdir}/source-dir/nested/run.sh"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm create "${vm_name}" \
    --backend "${backend}" \
    --memory "${SPORE_SMOKE_MEMORY:-256mib}" \
    --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}ms" \
    --console-log "${workdir}/console.log"
created=1

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/source.txt" /tmp/spore-copy-smoke.txt

if env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/source.txt" /tmp/spore-copy-smoke.txt \
  >"${workdir}/overwrite.out" 2>"${workdir}/overwrite.err"; then
  die "copy-in overwrote existing guest path"
fi

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" /tmp/spore-copy-smoke.txt "${workdir}/roundtrip.txt"

if env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" /tmp/spore-copy-smoke.txt "${workdir}/roundtrip.txt" \
  >"${workdir}/overwrite-out.out" 2>"${workdir}/overwrite-out.err"; then
  die "copy-out overwrote existing host path"
fi

cmp -s "${workdir}/source.txt" "${workdir}/roundtrip.txt" || die "copy-in/copy-out roundtrip mismatch"

collision_guest="/tmp/spore-copy-collision.txt"
collision_tmp_old="/tmp/.spore-copy-collision.txt.spore-copy.1.tmp"
collision_tmp_new="/tmp/.spore-copy-collision.txt.spore-copy.1.0.tmp"
mkdir -p "${workdir}/collision-guard-old" "${workdir}/collision-guard-new"
printf keep >"${workdir}/collision-guard-old/keep"
printf keep >"${workdir}/collision-guard-new/keep"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/collision-guard-old" "${collision_tmp_old}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/collision-guard-new" "${collision_tmp_new}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/source.txt" "${collision_guest}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" "${collision_tmp_old}" "${workdir}/collision-guard-old-roundtrip"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" "${collision_tmp_new}" "${workdir}/collision-guard-new-roundtrip"
diff -r "${workdir}/collision-guard-old" "${workdir}/collision-guard-old-roundtrip" >/dev/null || die "copy-in removed pre-existing old guest temp collision path"
diff -r "${workdir}/collision-guard-new" "${workdir}/collision-guard-new-roundtrip" >/dev/null || die "copy-in removed pre-existing guest temp collision path"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" "${collision_guest}" "${workdir}/collision-roundtrip.txt"
cmp -s "${workdir}/source.txt" "${workdir}/collision-roundtrip.txt" || die "copy-in temp collision roundtrip mismatch"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/source-dir" /tmp/spore-copy-smoke-dir

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" /tmp/spore-copy-smoke-dir "${workdir}/roundtrip-dir"

diff -r "${workdir}/source-dir" "${workdir}/roundtrip-dir" >/dev/null || die "copy directory roundtrip mismatch"
[[ -x "${workdir}/roundtrip-dir/nested/run.sh" ]] || die "copy directory did not preserve executable file mode"

# Bulk transfers: over 1MiB must round-trip byte-exact through copy-in and
# copy-out. Historically the SPIO transport broke above one vsock packet, so
# tiny fixtures cannot cover this path. Bulk exec stdio coverage lives in
# smoke-lifecycle-tty.sh, which boots an image with a shell.
bulk_bytes=$((1536 * 1024))
head -c "${bulk_bytes}" /dev/urandom >"${workdir}/bulk.bin"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/bulk.bin" /tmp/spore-copy-bulk.bin
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" vm copy-out "${vm_name}" /tmp/spore-copy-bulk.bin "${workdir}/bulk-roundtrip.bin"
cmp -s "${workdir}/bulk.bin" "${workdir}/bulk-roundtrip.bin" || die "bulk copy-in/copy-out roundtrip mismatch"

echo "smoke:lifecycle-copy ok"
