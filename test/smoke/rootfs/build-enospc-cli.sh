#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mode="${1:-}"
spore_bin="${2:-${SPORE_BIN:-${repo_root}/zig-out/bin/spore}}"
harness_bin="${3:-${repo_root}/zig-out/bin/spore-build-run-smoke}"
helper_bin="${4:-${repo_root}/zig-out/bin/spore-build-smoke-sh}"
tmp=""

die() {
  echo "error: $*" >&2
  exit 1
}

authoritative_cache_state() {
  local cache_root="$1"
  {
    {
      if [[ -d "${cache_root}" ]]; then
        find "${cache_root}" -maxdepth 1 -type f -name '*.json' -print
      fi
      for rel in refs/local build/steps cas/rootfs/blake3/indexes cas/rootfs/blake3/objects cas/rootfs/blake3/complete; do
        if [[ -d "${cache_root}/${rel}" ]]; then
          find "${cache_root}/${rel}" -type f -print
        fi
      done
    } | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s\n' "${path#"${cache_root}"/}"
      cksum <"${path}"
    done
  } | cksum | awk '{ print $1 ":" $2 }'
}

cleanup() {
  if [[ -z "${tmp}" || ! -d "${tmp}" ]]; then
    return
  fi
  case "$(basename "${tmp}")" in
    "sporevm-build-${mode}-enospc."*) rm -rf -- "${tmp}" ;;
    *) echo "warning: refusing to remove unexpected smoke workspace: ${tmp}" >&2 ;;
  esac
}
trap cleanup EXIT

case "${mode}" in
  block)
    destination="local/build-smoke-block-enospc:dev"
    marker="SPORE_BUILD_ENOSPC block"
    ;;
  inode)
    destination="local/build-smoke-inode-enospc:dev"
    marker="SPORE_BUILD_ENOSPC inode"
    ;;
  *) die "usage: build-enospc-cli.sh block|inode [spore-bin] [harness-bin] [helper-bin]" ;;
esac

for executable in "${spore_bin}" "${harness_bin}" "${helper_bin}"; do
  [[ -x "${executable}" ]] || die "required smoke executable is missing or not executable: ${executable}"
done

temp_parent="${TMPDIR:-/tmp}"
[[ "${temp_parent}" == /* ]] || die "TMPDIR must be absolute"
tmp="$(mktemp -d "${temp_parent%/}/sporevm-build-${mode}-enospc.XXXXXX")"
"${harness_bin}" "${helper_bin}" "--${mode}-enospc" "${tmp}"

cache_root="${tmp}/rootfs-cache"
runtime_dir="${tmp}/runtime"
context_dir="${tmp}/context"
[[ -f "${context_dir}/Dockerfile" ]] || die "${mode} ENOSPC VM smoke did not preserve its CLI workspace"

before_ref="$(SPOREVM_ROOTFS_CACHE_DIR="${cache_root}" "${spore_bin}" rootfs resolve "${destination}")"
before_state="$(authoritative_cache_state "${cache_root}")"
stdout="${tmp}/cli.stdout"
stderr="${tmp}/cli.stderr"

set +e
TMPDIR="${tmp}" \
SPOREVM_ROOTFS_CACHE_DIR="${cache_root}" \
SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" build --network none --no-cache -t "${destination}" "${context_dir}" \
    >"${stdout}" 2>"${stderr}"
status=$?
set -e

if [[ "${status}" -ne 2 ]]; then
  cat "${stdout}" >&2 || true
  cat "${stderr}" >&2 || true
  die "${mode} ENOSPC CLI build exited ${status}, expected 2"
fi
grep -Fq "${marker}" "${stderr}" || die "${mode} ENOSPC CLI output omitted its single-execution marker"
[[ "$(grep -Fc "${marker}" "${stderr}")" == "1" ]] || die "${mode} ENOSPC CLI output repeated its execution marker"
grep -Fq 'spore build: build rootfs ran out of block or inode space' "${stderr}" || die "${mode} ENOSPC CLI output omitted the actionable capacity diagnostic"
grep -Fq 'failed steps are not retried' "${stderr}" || die "${mode} ENOSPC CLI output omitted the no-retry contract"

after_ref="$(SPOREVM_ROOTFS_CACHE_DIR="${cache_root}" "${spore_bin}" rootfs resolve "${destination}")"
[[ "${after_ref}" == "${before_ref}" ]] || die "${mode} ENOSPC CLI build changed the destination ref"
after_state="$(authoritative_cache_state "${cache_root}")"
[[ "${after_state}" == "${before_state}" ]] || die "${mode} ENOSPC CLI build published authoritative cache state"

echo "smoke:build-${mode}-enospc-cli ok status=2 ref=${after_ref}"
