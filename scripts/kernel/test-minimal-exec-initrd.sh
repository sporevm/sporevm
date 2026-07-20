#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
generator="${script_dir}/make-minimal-exec-initrd.sh"

fail() {
  echo "minimal exec initrd test: $*" >&2
  exit 1
}

toybox_source=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toybox-source)
      [[ $# -ge 2 ]] || fail "--toybox-source requires a value"
      toybox_source="${2:-}"
      shift 2
      ;;
    --toybox-source=*)
      toybox_source="${1#--toybox-source=}"
      shift
      ;;
    *)
      fail "unexpected argument: $1"
      ;;
  esac
done
[[ -d "${toybox_source}" ]] || fail "--toybox-source must name the pinned Toybox source directory"

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

build_arch() {
  local arch="$1"
  local triple="$2"
  local generation_base="$3"
  local first="${task_tmp}/${arch}-first.cpio"
  local second="${task_tmp}/${arch}-second.cpio"
  local compiler_log="${task_tmp}/${arch}-cc.log"
  local compiler_wrapper="${task_tmp}/${arch}-cc"

  (
    umask 0022
    SOURCE_DATE_EPOCH=123 "${generator}" \
      --arch "${arch}" \
      --generation-base "${generation_base}" \
      --toybox-source "${toybox_source}" \
      "${first}" >/dev/null
  )

  cat >"${compiler_wrapper}" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"${compiler_log}"
exec zig cc -target ${triple} "\$@"
EOF
  chmod 0755 "${compiler_wrapper}"
  (
    umask 0077
    CC="${compiler_wrapper}" SOURCE_DATE_EPOCH=456 "${generator}" \
      --arch "${arch}" \
      --generation-base "${generation_base}" \
      --toybox-source "${toybox_source}" \
      "${second}" >/dev/null
  )

  cmp -s "${first}" "${second}" || fail "${arch} archive changed across compiler selection, umask, or ambient timestamp"
  grep -Fq -- "-DSPORE_GENERATION_BASE=${generation_base}ULL" "${compiler_log}" || fail "${arch} compiler did not receive the selected board GPA"
  python3 - "${first}" "${arch}" "${generation_base}" <<'PY'
import pathlib
import stat
import struct
import sys

archive = pathlib.Path(sys.argv[1]).read_bytes()
arch = sys.argv[2]
generation_base = int(sys.argv[3], 0)
machine = {"aarch64": 183, "x86_64": 62}[arch]
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
        if len(payload) < 64 or payload[:6] != b"\x7fELF\x02\x01":
            raise SystemExit(f"error: executable is not little-endian ELF64: {name}")
        if struct.unpack_from("<H", payload, 18)[0] != machine:
            raise SystemExit(f"error: executable has wrong machine: {name}")
        phoff = struct.unpack_from("<Q", payload, 32)[0]
        phentsize = struct.unpack_from("<H", payload, 54)[0]
        phnum = struct.unpack_from("<H", payload, 56)[0]
        if phentsize < 4 or phoff + phentsize * phnum > len(payload):
            raise SystemExit(f"error: malformed ELF program headers: {name}")
        if any(struct.unpack_from("<I", payload, phoff + index * phentsize)[0] == 3 for index in range(phnum)):
            raise SystemExit(f"error: dynamically linked executable: {name}")
    else:
        raise SystemExit(f"error: unsupported newc entry type: {name}")

required = {".", "bin", "dev", "proc", "run", "tmp", "usr", "usr/bin", "init", "bin/toybox"}
missing = required.difference(entries)
if missing:
    raise SystemExit(f"error: missing newc entries: {sorted(missing)}")
if generation_base not in (0x0c001000, 0xd0001000):
    raise SystemExit("error: test was given a non-board generation GPA")
PY
}

build_arch aarch64 aarch64-linux-musl 0xc001000
build_arch x86_64 x86_64-linux-musl 0xd0001000

echo "minimal exec initrd test: passed"
