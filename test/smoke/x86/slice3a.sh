#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
asset="sporevm-x86_64-linux-6.1.155-bzImage"
slice2a_bin="${SPOREVM_X86_SLICE2A_BIN:-${repo_root}/zig-out/bin/x86-slice2a-smoke}"

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || {
  echo "error: x86 Slice 3a smoke requires Linux/x86_64" >&2
  exit 1
}
[[ -n "${seed_dir}" ]] || {
  echo "error: set SPOREVM_X86_MANAGED_KERNEL_SEED_DIR" >&2
  exit 1
}
[[ -x "${slice2a_bin}" ]] || {
  echo "error: Slice 2a smoke binary not executable: ${slice2a_bin}" >&2
  exit 1
}

# The frozen-board smoke proves generation acknowledgement, root block
# read/write, immutable block reads and host-proven write rejection, RNG, and exact
# virtio0..virtio7 enumeration. The product smokes
# then prove one-shot and named lifecycle behavior plus all deferred gates.
"${slice2a_bin}" "${seed_dir}/${asset}"
"${repo_root}/test/smoke/x86/fresh-product.sh"
"${repo_root}/test/smoke/x86/fail-closed.sh"

echo "smoke:x86-slice3a ok"
