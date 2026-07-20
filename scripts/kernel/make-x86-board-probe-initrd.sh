#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/kernel/make-x86-board-probe-initrd.sh <out.cpio>

Build the deterministic static x86-64 /init used by the Stage 0a.3 host-only
board and lifecycle probe, then package it in a deterministic newc initrd. The
guest prints parseable CPU, virtio, hvc0/stdout, generation-device, and selected
lifecycle evidence. It expects the generation device at provisional GPA
0xd0001000.

Environment:
  CC  x86_64 Linux-musl C compiler command, including any target-selection
      arguments. Defaults to the repo-pinned Zig compiler invoked as
      `zig cc -target x86_64-linux-musl` through mise when available.
  SOURCE_DATE_EPOCH
      Archive timestamp. Defaults to 0 and must fit in an unsigned 32-bit
      newc timestamp.

Example:
  scripts/kernel/make-x86-board-probe-initrd.sh /tmp/x86-board-probe.cpio
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
source_file="${repo_root}/guest/x86-board-probe/init.c"
archive_builder="${script_dir}/make-x86-initrd.py"
if [[ ! -f "${source_file}" ]]; then
  echo "error: missing x86 board-probe source: ${source_file}" >&2
  exit 1
fi
if [[ -f "${repo_root}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${repo_root}/mise.toml}"
fi

if [[ -n "${CC:-}" ]]; then
  read -r -a cc_cmd <<<"${CC}"
elif command -v mise >/dev/null 2>&1; then
  zig_path="$(mise which zig 2>/dev/null || true)"
  if [[ -z "${zig_path}" ]]; then
    echo "error: mise could not locate the repo-pinned Zig compiler" >&2
    exit 1
  fi
  cc_cmd=("${zig_path}" cc -target x86_64-linux-musl)
elif command -v zig >/dev/null 2>&1; then
  cc_cmd=(zig cc -target x86_64-linux-musl)
else
  echo "error: set CC to a static x86_64 Linux-musl compiler command" >&2
  exit 1
fi

if ! source_date_epoch="$(python3 "${archive_builder}" validate-epoch "${SOURCE_DATE_EPOCH:-0}" 2>/dev/null)"; then
  echo "error: SOURCE_DATE_EPOCH must be an unsigned 32-bit integer" >&2
  exit 2
fi

out="$1"
out_dir="$(dirname "${out}")"
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
out="${out_dir}/$(basename "${out}")"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-board-probe.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/root/dev" "${workdir}/root/proc" "${workdir}/root/sys"

export SOURCE_DATE_EPOCH="${source_date_epoch}"
"${cc_cmd[@]}" -static -Os -s -Wall -Wextra -Werror \
  "${source_file}" -o "${workdir}/root/init"
chmod 0755 "${workdir}/root/init"

# Write newc directly so inode allocation, host uid/gid, and cpio implementation
# cannot perturb the initrd digest. Only the fixed directories and /init belong
# in this purpose-built host-probe archive.
python3 "${archive_builder}" build \
  --label board-probe \
  --mtime "${source_date_epoch}" \
  --directory dev --directory proc --directory sys \
  "${workdir}/root/init" "${out}"

echo "wrote ${out}"
