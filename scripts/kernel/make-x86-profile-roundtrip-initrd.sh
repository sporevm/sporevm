#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/kernel/make-x86-profile-roundtrip-initrd.sh <out.cpio>

Build the deterministic static x86-64 Stage 0b.2 profile roundtrip guest. The
archive contains only fixed directories and /init. It uses the task-owned
mailbox at GPA 0xcffff000 and the CAPT/RSTR doorbells on GPA 0xd0001000.

Environment:
  SPOREVM_X86_64_LINUX_CC
      Optional x86_64 Linux-musl C compiler command. When absent, the script
      requires the repository-pinned Zig compiler through mise. Ambient CC is
      deliberately ignored.
  SOURCE_DATE_EPOCH
      Archive timestamp. Defaults to 0 and must fit in an unsigned 32-bit
      newc timestamp.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to build the deterministic newc archive" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
source_dir="${repo_root}/guest/x86-profile-roundtrip"
for source in init.c profile_state.S mailbox_abi.h; do
  if [[ ! -f "${source_dir}/${source}" ]]; then
    echo "error: missing x86 profile roundtrip source: ${source_dir}/${source}" >&2
    exit 1
  fi
done

if [[ -n "${SPOREVM_X86_64_LINUX_CC:-}" ]]; then
  read -r -a cc_cmd <<<"${SPOREVM_X86_64_LINUX_CC}"
else
  if ! command -v mise >/dev/null 2>&1; then
    echo "error: mise is required to locate the repo-pinned Zig compiler" >&2
    exit 1
  fi
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${repo_root}/mise.toml}"
  zig_path="$(cd "${repo_root}" && mise which zig 2>/dev/null || true)"
  if [[ -z "${zig_path}" ]]; then
    echo "error: mise could not locate the repo-pinned Zig compiler" >&2
    exit 1
  fi
  cc_cmd=("${zig_path}" cc -target x86_64-linux-musl)
fi

source_date_epoch="${SOURCE_DATE_EPOCH:-0}"
if [[ ! "${source_date_epoch}" =~ ^[0-9]+$ ]]; then
  echo "error: SOURCE_DATE_EPOCH must be an unsigned 32-bit integer" >&2
  exit 2
fi
if ! source_date_epoch="$({
  python3 -c \
    'import sys; value = int(sys.argv[1]); assert value <= 0xffffffff; print(value)' \
    "${source_date_epoch}"
} 2>/dev/null)"; then
  echo "error: SOURCE_DATE_EPOCH must be an unsigned 32-bit integer" >&2
  exit 2
fi

out="$1"
mkdir -p "$(dirname "${out}")"
out_dir="$(cd "$(dirname "${out}")" && pwd)"
out="${out_dir}/$(basename "${out}")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-profile-roundtrip.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/root/dev" "${workdir}/root/proc"

"${cc_cmd[@]}" -static -Os -s -Wall -Wextra -Werror \
  "${source_dir}/init.c" "${source_dir}/profile_state.S" \
  -o "${workdir}/root/init"
chmod 0755 "${workdir}/root/init"

python3 - "${workdir}/root/init" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
if len(data) < 64 or data[:4] != b"\x7fELF":
    raise SystemExit("error: profile roundtrip /init is not an ELF binary")
if data[4] != 2 or data[5] != 1:
    raise SystemExit("error: profile roundtrip /init must be little-endian ELF64")
if struct.unpack_from("<H", data, 18)[0] != 62:
    raise SystemExit("error: profile roundtrip /init must target x86-64")
program_offset = struct.unpack_from("<Q", data, 32)[0]
program_size = struct.unpack_from("<H", data, 54)[0]
program_count = struct.unpack_from("<H", data, 56)[0]
if program_size < 4 or program_offset + program_size * program_count > len(data):
    raise SystemExit("error: profile roundtrip /init has malformed program headers")
for index in range(program_count):
    if struct.unpack_from("<I", data, program_offset + index * program_size)[0] == 3:
        raise SystemExit("error: profile roundtrip /init is dynamically linked")
PY

python3 - "${workdir}/root/init" "${out}" "${source_date_epoch}" <<'PY'
import pathlib
import sys

init_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
mtime = int(sys.argv[3])
entries = [
    (".", 0o040755, b"", 2),
    ("dev", 0o040755, b"", 2),
    ("init", 0o100755, init_path.read_bytes(), 1),
    ("proc", 0o040755, b"", 2),
]

def pad4(stream, size):
    padding = (-size) % 4
    if padding:
        stream.write(b"\0" * padding)

def write_entry(stream, inode, name, mode, payload, links):
    encoded_name = name.encode("ascii") + b"\0"
    fields = (inode, mode, 0, 0, links, mtime, len(payload),
              0, 0, 0, 0, len(encoded_name), 0)
    header = b"070701" + b"".join(
        f"{value:08x}".encode("ascii") for value in fields)
    stream.write(header)
    stream.write(encoded_name)
    pad4(stream, len(header) + len(encoded_name))
    stream.write(payload)
    pad4(stream, len(payload))

temporary = out_path.with_name(out_path.name + ".tmp")
with temporary.open("wb") as stream:
    for inode, (name, mode, payload, links) in enumerate(entries, start=1):
        write_entry(stream, inode, name, mode, payload, links)
    write_entry(stream, len(entries) + 1, "TRAILER!!!", 0, b"", 1)
    padding = (-stream.tell()) % 512
    if padding:
        stream.write(b"\0" * padding)
temporary.replace(out_path)
PY

echo "wrote ${out}"
