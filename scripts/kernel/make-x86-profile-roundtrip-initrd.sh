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
archive_builder="${script_dir}/make-x86-initrd.py"
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

if ! source_date_epoch="$(python3 "${archive_builder}" validate-epoch "${SOURCE_DATE_EPOCH:-0}" 2>/dev/null)"; then
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

python3 "${archive_builder}" build \
  --label "profile roundtrip" \
  --mtime "${source_date_epoch}" \
  --directory dev --directory proc \
  "${workdir}/root/init" "${out}"

echo "wrote ${out}"
