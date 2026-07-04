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

backend="$(infer_backend)"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-lifecycle-copy.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-copy.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

vm_name="copy-${backend}-$$"
created=0
cleanup() {
  if [[ "${created}" == "1" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${runtime_dir}" "${workdir}"
}
trap cleanup EXIT

printf 'spore copy smoke\n' >"${workdir}/source.txt"
mkdir -p "${workdir}/source-dir/nested" "${workdir}/source-dir/empty"
printf 'alpha\n' >"${workdir}/source-dir/root.txt"
printf '#!/bin/sh\necho copied\n' >"${workdir}/source-dir/nested/run.sh"
chmod 755 "${workdir}/source-dir/nested/run.sh"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --backend "${backend}" \
    --memory "${SPORE_SMOKE_MEMORY:-256mib}" \
    --timeout-ms "${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}" \
    --console-log "${workdir}/console.log"
created=1

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/source.txt" /tmp/spore-copy-smoke.txt

if env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/source.txt" /tmp/spore-copy-smoke.txt \
  >"${workdir}/overwrite.out" 2>"${workdir}/overwrite.err"; then
  die "copy-in overwrote existing guest path"
fi

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" /tmp/spore-copy-smoke.txt "${workdir}/roundtrip.txt"

if env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" /tmp/spore-copy-smoke.txt "${workdir}/roundtrip.txt" \
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
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/collision-guard-old" "${collision_tmp_old}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/collision-guard-new" "${collision_tmp_new}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/source.txt" "${collision_guest}"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" "${collision_tmp_old}" "${workdir}/collision-guard-old-roundtrip"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" "${collision_tmp_new}" "${workdir}/collision-guard-new-roundtrip"
diff -r "${workdir}/collision-guard-old" "${workdir}/collision-guard-old-roundtrip" >/dev/null || die "copy-in removed pre-existing old guest temp collision path"
diff -r "${workdir}/collision-guard-new" "${workdir}/collision-guard-new-roundtrip" >/dev/null || die "copy-in removed pre-existing guest temp collision path"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" "${collision_guest}" "${workdir}/collision-roundtrip.txt"
cmp -s "${workdir}/source.txt" "${workdir}/collision-roundtrip.txt" || die "copy-in temp collision roundtrip mismatch"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/source-dir" /tmp/spore-copy-smoke-dir

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" /tmp/spore-copy-smoke-dir "${workdir}/roundtrip-dir"

diff -r "${workdir}/source-dir" "${workdir}/roundtrip-dir" >/dev/null || die "copy directory roundtrip mismatch"
[[ -x "${workdir}/roundtrip-dir/nested/run.sh" ]] || die "copy directory did not preserve executable file mode"

# Bulk transfers: over 1MiB must round-trip byte-exact through copy-in and
# copy-out. Historically the SPIO transport broke above one vsock packet, so
# tiny fixtures cannot cover this path. Bulk exec stdio coverage lives in
# smoke-lifecycle-tty.sh, which boots an image with a shell.
bulk_bytes=$((1536 * 1024))
head -c "${bulk_bytes}" /dev/urandom >"${workdir}/bulk.bin"

env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-in "${vm_name}" "${workdir}/bulk.bin" /tmp/spore-copy-bulk.bin
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" copy-out "${vm_name}" /tmp/spore-copy-bulk.bin "${workdir}/bulk-roundtrip.bin"
cmp -s "${workdir}/bulk.bin" "${workdir}/bulk-roundtrip.bin" || die "bulk copy-in/copy-out roundtrip mismatch"

cat >"${workdir}/copy-api.c" <<'C'
#include <stdio.h>
#include <string.h>

#include "spore.h"

static SporeString str_arg(const char *value) {
  return (SporeString){ .ptr = value, .len = strlen(value) };
}

int main(int argc, char **argv) {
  if (argc != 6) return 2;
  SporeContext context = 0;
  if (spore_context_new(&context) != SPORE_SUCCESS) return 1;

  SporeResult result = spore_context_set_env(context, str_arg("SPOREVM_RUNTIME_DIR"), str_arg(argv[1]));
  if (result == SPORE_SUCCESS) {
    SporeCopyNamedOptions copy;
    spore_copy_named_options_init(&copy);
    copy.name = str_arg(argv[2]);
    copy.host_path = str_arg(argv[3]);
    copy.guest_path = str_arg(argv[4]);
    result = spore_copy_in_named(context, &copy);
    if (result == SPORE_SUCCESS) {
      copy.host_path = str_arg(argv[5]);
      result = spore_copy_out_named(context, &copy);
    }
  }

  if (result != SPORE_SUCCESS) {
    SporeString message = spore_context_last_error(context);
    fprintf(stderr, "libspore copy failed: %.*s\n", (int)message.len, message.ptr ? message.ptr : "");
  }
  spore_context_free(context);
  return result == SPORE_SUCCESS ? 0 : 1;
}
C

cc -std=c11 -Wall -Wextra -Werror \
  -I"${repo_root}/include" \
  "${workdir}/copy-api.c" \
  -L"${repo_root}/zig-out/lib" -lspore \
  -o "${workdir}/copy-api"

env DYLD_LIBRARY_PATH="${repo_root}/zig-out/lib:${DYLD_LIBRARY_PATH:-}" \
  LD_LIBRARY_PATH="${repo_root}/zig-out/lib:${LD_LIBRARY_PATH:-}" \
  "${workdir}/copy-api" "${runtime_dir}" "${vm_name}" \
    "${workdir}/source-dir" /tmp/spore-copy-api-dir "${workdir}/api-roundtrip-dir"

diff -r "${workdir}/source-dir" "${workdir}/api-roundtrip-dir" >/dev/null || die "libspore copy directory roundtrip mismatch"
echo "smoke:lifecycle-copy ok"
