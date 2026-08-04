#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
release="${SPOREVM_KERNEL_RELEASE:-v0.7.0}"
asset="sporevm-x86_64-linux-6.1.155-bzImage"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 Slice 3b smoke requires Linux/x86_64"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-slice3b.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
export SPOREVM_KERNEL_CACHE_DIR="${workdir}/kernel-cache"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
export SPORE_BACKEND=kvm
export SPORE_SMOKE_MEMORY=512mib
export SPORE_SMOKE_PLATFORM=linux/amd64
mkdir -p "${SPOREVM_RUNTIME_DIR}"
chmod 0700 "${SPOREVM_RUNTIME_DIR}"

if [[ -n "${seed_dir}" ]]; then
  managed_dir="${SPOREVM_KERNEL_CACHE_DIR}/sporevm-kernels/${release}"
  mkdir -p "${managed_dir}"
  for suffix in "" .config .sha256; do
    [[ -f "${seed_dir}/${asset}${suffix}" ]] || die "missing managed seed asset: ${seed_dir}/${asset}${suffix}"
    cp "${seed_dir}/${asset}${suffix}" "${managed_dir}/${asset}${suffix}"
    chmod 0444 "${managed_dir}/${asset}${suffix}"
  done
fi

"${repo_root}/test/smoke/rootfs/oci-run.sh" \
  --image docker.io/library/alpine:3.20 \
  --platform linux/amd64 \
  --workdir "${workdir}/oci-rootfs" \
  --spore-bin "${spore_bin}" \
  --no-build \
  -- /bin/sh -lc 'test "$(uname -m)" = x86_64 && printf "x86 rootfs ok\n"'

"${repo_root}/test/smoke/run/image-commit.sh"
"${repo_root}/test/smoke/network/config.sh"
"${repo_root}/test/smoke/network/dns.sh"
"${repo_root}/test/smoke/network/http.sh"
"${repo_root}/test/smoke/network/deny.sh"
"${repo_root}/test/smoke/network/bind-service.sh"
"${repo_root}/test/smoke/network/forward.sh"

echo "smoke:x86-slice3b ok"
