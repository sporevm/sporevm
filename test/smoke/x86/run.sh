#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
board_smoke_bin="${SPOREVM_X86_BOARD_SMOKE_BIN:-${repo_root}/zig-out/bin/x86-board-smoke}"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
# shellcheck source=src/managed_kernel.env
source "${repo_root}/src/managed_kernel.env"
release="${SPOREVM_KERNEL_RELEASE:-${managed_kernel_release}}"
asset="sporevm-x86_64-linux-${managed_kernel_linux_version}-bzImage"

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 run smoke requires Linux/x86_64"
require_spore_bin
[[ -x "${board_smoke_bin}" ]] || die "board smoke binary not executable: ${board_smoke_bin}"
[[ -z "${SPOREVM_KERNEL_IMAGE:-}" && -z "${SPOREVM_RUN_INITRD:-}" ]] || die "boot artifact overrides must be unset"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-x86-run"
if [[ -n "${seed_dir}" ]]; then
  kernel_path="${seed_dir}/${asset}"
  [[ -f "${kernel_path}" ]] || die "missing managed seed asset: ${kernel_path}"
else
  kernel_path="$(env SPOREVM_KERNEL_ARCH=x86_64 SPOREVM_KERNEL_CACHE_DIR="${workdir}/board-kernel-cache" \
    "${repo_root}/scripts/kernel/ensure-managed-kernel.sh")"
fi

# The frozen-board smoke proves generation acknowledgement, root block
# read/write, immutable block reads and host-proven write rejection, RNG, and
# exact virtio0..virtio7 enumeration. The product smokes then prove one-shot and
# named lifecycle behavior and that unavailable features fail closed.
"${board_smoke_bin}" "${kernel_path}"
"${repo_root}/test/smoke/x86/fresh-product.sh"
"${repo_root}/test/smoke/x86/fail-closed.sh"

export SPOREVM_KERNEL_CACHE_DIR="${workdir}/kernel-cache"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
export SPORE_BACKEND=kvm
export SPORE_SMOKE_MEMORY=512mib
export SPORE_SMOKE_PLATFORM=linux/amd64
mkdir -p "${SPOREVM_RUNTIME_DIR}"
chmod 0700 "${SPOREVM_RUNTIME_DIR}"

if [[ -n "${seed_dir}" ]]; then
  managed_dir="${SPOREVM_KERNEL_CACHE_DIR}/${managed_kernel_repository//\//-}/${release}"
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
"${spore_bin}" run \
  --backend kvm \
  --memory 512mib \
  --image docker.io/library/alpine:3.20 \
  --disk-size 2gb \
  --commit-image local/x86-run:growth \
  -- /bin/sh -lc 'test "$(cat /sys/class/block/vda/size)" -eq 4194304 && test "$(df -k / | awk "NR == 2 { print \$2 }")" -gt 1500000 && echo x86-growth-ok >/x86-growth-marker'
"${spore_bin}" run \
  --backend kvm \
  --memory 512mib \
  --image local/x86-run:growth \
  --pull=never \
  -- /bin/sh -lc 'test "$(cat /sys/class/block/vda/size)" -eq 4194304 && grep -Fxq x86-growth-ok /x86-growth-marker'
"${repo_root}/test/smoke/network/config.sh"
"${repo_root}/test/smoke/network/dns.sh"
"${repo_root}/test/smoke/network/http.sh"
"${repo_root}/test/smoke/network/deny.sh"
"${repo_root}/test/smoke/network/bind-service.sh"
"${repo_root}/test/smoke/network/forward.sh"

echo "smoke:x86 ok"
