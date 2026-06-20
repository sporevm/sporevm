#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/make-minimal-exec-initrd.sh <out.cpio>

Build a tiny aarch64 Linux initrd for the SporeVM minimal boot/run path. The
init process listens on AF_VSOCK, accepts one-line JSON run-session requests,
runs the requested binary, streams stdout/stderr frames, and finishes with an
exit-status frame.

Environment:
  CC   C compiler command. Defaults to `zig cc -target aarch64-linux-musl`
       when zig is available, otherwise `cc`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0 || exit 2
fi

if ! command -v cpio >/dev/null 2>&1; then
  echo "error: cpio is required to build the minimal exec initrd" >&2
  exit 1
fi

out="$1"
if [[ "${out}" != /* ]]; then
  out="${PWD}/${out}"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${REPO_ROOT}/mise.toml}"
fi
if [[ -n "${CC:-}" ]]; then
  read -r -a cc_cmd <<<"${CC}"
elif command -v zig >/dev/null 2>&1; then
  cc_cmd=(zig cc -target aarch64-linux-musl)
elif command -v mise >/dev/null 2>&1; then
  cc_cmd=(mise exec -- zig cc -target aarch64-linux-musl)
else
  cc_cmd=(cc)
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-minimal-initrd.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/root/bin" "${workdir}/root/dev" "${workdir}/root/proc" "${workdir}/root/run" "${workdir}/root/tmp"

source_dir="${REPO_ROOT}/guest/minimal-initrd"
sources=(agent true false writeout sleeper counter netcheck nslookup wget)
for src in "${sources[@]}"; do
  if [[ ! -f "${source_dir}/${src}.c" ]]; then
    echo "error: missing minimal initrd source: ${source_dir}/${src}.c" >&2
    exit 1
  fi
done

compile_static() {
  local src="$1"
  local dst="$2"
  "${cc_cmd[@]}" -static -Os -s "${source_dir}/${src}.c" -o "${dst}"
}

compile_static agent "${workdir}/root/init"
compile_static true "${workdir}/root/bin/true"
compile_static false "${workdir}/root/bin/false"
compile_static writeout "${workdir}/root/bin/writeout"
compile_static sleeper "${workdir}/root/bin/sleeper"
compile_static counter "${workdir}/root/bin/counter"
compile_static netcheck "${workdir}/root/bin/netcheck"
compile_static nslookup "${workdir}/root/bin/nslookup"
compile_static wget "${workdir}/root/bin/wget"
chmod 0755 "${workdir}/root/init" "${workdir}/root/bin/true" "${workdir}/root/bin/false" "${workdir}/root/bin/writeout" "${workdir}/root/bin/sleeper" "${workdir}/root/bin/counter" "${workdir}/root/bin/netcheck" "${workdir}/root/bin/nslookup" "${workdir}/root/bin/wget"
chmod 1777 "${workdir}/root/tmp"

mkdir -p "$(dirname "${out}")"
(
  cd "${workdir}/root"
  find . -print | LC_ALL=C sort | cpio -o -H newc >"${out}"
)

echo "wrote ${out}"
