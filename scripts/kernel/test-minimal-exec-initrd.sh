#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
generator="${script_dir}/make-minimal-exec-initrd.sh"

fail() {
  echo "minimal exec initrd test: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || fail "usage: $0 TOYBOX_SOURCE AARCH64_CPIO X86_64_CPIO"
toybox_source="$1"
aarch64_cpio="$2"
x86_64_cpio="$3"
[[ -d "${toybox_source}" ]] || fail "TOYBOX_SOURCE must name the pinned Toybox source directory"

bash -n "${generator}"
bash -n "$0"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${generator}" "$0"
fi

help="$(${generator} --help)"
[[ "${help}" == *"aarch64|x86_64"* ]] || fail "help omits supported architectures"
[[ "${help}" == *"mtime is pinned to zero"* ]] || fail "help omits pinned archive timestamp contract"

grep -Fq 'const aarch64_board = @import("src/aarch64/board.zig");' "${repo_root}/build.zig" || fail "build does not source the ARM generation GPA from its board"
grep -Fq 'const x86_64_board = @import("src/x86_64/board.zig");' "${repo_root}/build.zig" || fail "build does not source the x86 generation GPA from its board"
grep -Fq '#error "SPORE_GENERATION_BASE must come from the selected SporeVM board"' "${repo_root}/guest/minimal-initrd/agent.c" || fail "agent permits an implicit generation GPA"
if grep -Fq '#define GEN_BASE 0x0c001000ULL' "${repo_root}/guest/minimal-initrd/agent.c"; then
  fail "agent still hardcodes the ARM generation GPA"
fi

task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-minimal-initrd-test.XXXXXX")"
trap 'rm -rf "${task_tmp}"' EXIT
if "${generator}" --arch x86_64 --generation-base 0xc001000 --toybox-source "${task_tmp}" "${task_tmp}/bad.cpio" >"${task_tmp}/stdout" 2>"${task_tmp}/stderr"; then
  fail "accepted the ARM generation GPA for x86_64"
fi
grep -Fq 'generation GPA does not match the x86_64 SporeVM board' "${task_tmp}/stderr" || fail "mismatch did not report the board contract"

check_archive() {
  python3 - "$1" <<'PY'
import pathlib
import stat
import sys

archive = pathlib.Path(sys.argv[1]).read_bytes()
offset = 0
entries = {}
while True:
    if archive[offset:offset + 6] != b"070701":
        raise SystemExit(f"error: malformed newc magic at {offset}")
    header = archive[offset:offset + 110]
    if len(header) != 110:
        raise SystemExit("error: truncated newc header")
    fields = [int(header[index:index + 8], 16) for index in range(6, 110, 8)]
    mode, mtime, size, name_size = fields[1], fields[5], fields[6], fields[11]
    offset += 110
    encoded_name = archive[offset:offset + name_size]
    if len(encoded_name) != name_size or not encoded_name.endswith(b"\0"):
        raise SystemExit("error: malformed newc name")
    name = encoded_name[:-1].decode("utf-8")
    offset = (offset + name_size + 3) & ~3
    payload = archive[offset:offset + size]
    if len(payload) != size:
        raise SystemExit(f"error: truncated newc payload: {name}")
    offset = (offset + size + 3) & ~3
    if name == "TRAILER!!!":
        break
    if name in entries:
        raise SystemExit(f"error: duplicate newc entry: {name}")
    if mtime != 0:
        raise SystemExit(f"error: unpinned newc mtime: {name}")
    entries[name] = (mode, payload)

if any(archive[offset:]):
    raise SystemExit("error: nonzero bytes after newc trailer")
for name, (mode, payload) in entries.items():
    kind = stat.S_IFMT(mode)
    permissions = stat.S_IMODE(mode)
    if kind == stat.S_IFDIR:
        expected = 0o1777 if name == "tmp" else 0o755
        if permissions != expected or payload:
            raise SystemExit(f"error: noncanonical directory entry: {name}")
    elif kind == stat.S_IFLNK:
        if permissions != 0o777 or not payload:
            raise SystemExit(f"error: noncanonical symlink entry: {name}")
    elif kind == stat.S_IFREG:
        if permissions != 0o755:
            raise SystemExit(f"error: noncanonical executable mode: {name}")
    else:
        raise SystemExit(f"error: unsupported newc entry type: {name}")

# The shipped initrd holds the agent, the Toybox shell environment, true and
# false. Smoke helpers belong only in -Dsmoke-helpers test builds.
expected = {".", "bin", "dev", "proc", "run", "tmp", "usr", "usr/bin", "usr/bin/env", "init",
            "bin/sh", "bin/toybox", "bin/true", "bin/false"}
expected.update(f"bin/{applet}" for applet in
                ("echo", "cat", "env", "ls", "mkdir", "printf", "pwd", "rm", "sleep", "test", "touch", "uname"))
if set(entries) != expected:
    raise SystemExit(f"error: initrd entries differ: missing {sorted(expected - set(entries))}, "
                     f"unexpected {sorted(set(entries) - expected)}")
PY
}

check_archive "${aarch64_cpio}"
check_archive "${x86_64_cpio}"

# The embedded initrd's digest is part of every `spore build` cache key, so
# rebuild each archive under a different umask, temporary directory, ambient
# timestamp, and compiler command, and require the same bytes.
rebuild_arch() {
  local arch="$1"
  local triple="$2"
  local generation_base="$3"
  local expected="$4"
  local rebuilt="${task_tmp}/${arch}.cpio"

  mkdir "${task_tmp}/${arch}-tmp"
  (
    umask 0077
    TMPDIR="${task_tmp}/${arch}-tmp" CC="zig cc -target ${triple}" SOURCE_DATE_EPOCH=456 "${generator}" \
      --arch "${arch}" \
      --generation-base "${generation_base}" \
      --toybox-source "${toybox_source}" \
      "${rebuilt}" >/dev/null
  )
  cmp -s "${expected}" "${rebuilt}" || fail "${arch} archive changed across umask, TMPDIR, SOURCE_DATE_EPOCH, or CC"
}

rebuild_arch aarch64 aarch64-linux-musl 0xc001000 "${aarch64_cpio}" &
aarch64_rebuild=$!
rebuild_arch x86_64 x86_64-linux-musl 0xd0001000 "${x86_64_cpio}" &
x86_64_rebuild=$!
rebuild_status=0
wait "${aarch64_rebuild}" || rebuild_status=1
wait "${x86_64_rebuild}" || rebuild_status=1
[[ "${rebuild_status}" -eq 0 ]] || exit 1

echo "minimal exec initrd test: passed"
