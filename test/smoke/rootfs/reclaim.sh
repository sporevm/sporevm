#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# Evict ext4's block-allocator (buddy) cache between fsynced writes on the
# guest's ext4 root, then require that the kernel never oopsed. Linux 6.1.191
# dereferenced NULL on the first allocation after such an eviction (managed
# kernels v0.7.1 and v0.7.2), and nothing else in the smokes reloads that cache.
# SPOREVM_KERNEL_IMAGE runs the probe against another kernel.
backend="$(infer_backend)"
require_spore_bin
image_ref="${SPORE_SMOKE_IMAGE:-docker.io/library/alpine:3.20}"
if [[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]]; then
  default_smoke_memory="512mib"
else
  default_smoke_memory="256mib"
fi
smoke_memory="${SPORE_SMOKE_MEMORY:-${default_smoke_memory}}"
smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-rootfs-reclaim"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"

probe='set -eu
test "$(awk "\$2 == \"/\" { fs = \$3 } END { print fs }" /proc/mounts)" = ext4
for round in 1 2 3; do
  dd if=/dev/zero of="/reclaim-a${round}" bs=1M count=4 conv=fsync 2>/dev/null
  sync
  echo 3 >/proc/sys/vm/drop_caches
  dd if=/dev/zero of="/reclaim-b${round}" bs=1M count=4 conv=fsync 2>/dev/null
done
test "$(( $(cat /proc/sys/kernel/tainted) & 128 ))" -eq 0
echo reclaim-ok'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --console-log "${workdir}/console.log" \
  -- /bin/sh -c "${probe}" \
  >"${workdir}/stdout" 2>"${workdir}/stderr" || {
  cat "${workdir}/stdout" "${workdir}/stderr" >&2 || true
  grep -a -E 'Internal error|Unable to handle|pc : |RIP: ' "${workdir}/console.log" >&2 || true
  die "guest failed to write after evicting the ext4 buddy cache"
}
grep -Fxq reclaim-ok "${workdir}/stdout" || {
  cat "${workdir}/stdout" "${workdir}/stderr" >&2 || true
  die "reclaim probe did not report success"
}

echo "smoke:rootfs-reclaim ok backend=${backend} image=${image_ref}"
