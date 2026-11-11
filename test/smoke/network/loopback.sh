#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
backend="$(infer_backend)"
require_spore_bin
smoke_tempdir workdir "${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}/svm-lo"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
mkdir -m 700 "${SPOREVM_RUNTIME_DIR}"
cleanup() {
  for name in source restored child-0 child-1; do
    "${spore_bin}" vm rm "${name}" >/dev/null 2>&1 || true
  done
}

# Omitting --net is the disabled-network mode for run/create. Loopback must
# still work; eth0 must not be accidentally enabled along with it.
for mode in none spore; do
  network=()
  [[ "${mode}" != spore ]] || network=(--net)
  "${spore_bin}" run --backend "${backend}" ${network[@]+"${network[@]}"} -- /bin/loopcheck
  "${spore_bin}" vm create source --backend "${backend}" ${network[@]+"${network[@]}"}
  "${spore_bin}" vm exec source -- /bin/loopcheck
  if [[ "${mode}" == none ]]; then
    "${spore_bin}" vm exec source -- /bin/sh -c 'flags=$(cat /sys/class/net/eth0/flags); test "$((flags & 1))" = 0'
  fi
  "${spore_bin}" vm save source --output "${workdir}/${mode}.spore"
  "${spore_bin}" vm restore restored --backend "${backend}" --checkpoint "${workdir}/${mode}.spore"
  "${spore_bin}" vm exec restored -- /bin/loopcheck
  if [[ "${mode}" == none ]]; then
    "${spore_bin}" vm fork restored --count 2 --name-prefix child
  else
    # Networked live named fork is deliberately unsupported. Saved checkpoint
    # forks do support networking and must retain the same local guest state.
    "${spore_bin}" checkpoint fork "${workdir}/${mode}.spore" --count 2 --output "${workdir}/forks"
    "${spore_bin}" vm restore child-0 --backend "${backend}" --checkpoint "${workdir}/forks/000000"
    "${spore_bin}" vm restore child-1 --backend "${backend}" --checkpoint "${workdir}/forks/000001"
  fi
  for name in source restored child-0 child-1; do
    "${spore_bin}" vm exec "${name}" -- /bin/loopcheck
    "${spore_bin}" vm rm "${name}"
  done
done

# The OCI base omits /etc/hosts. Check materialization defaults as well as
# the explicit build --network none path, using the same guest TCP probe.
mkdir "${workdir}/context"
zig cc -target aarch64-linux-musl -static -Os \
  "${repo_root}/guest/smoke-helpers/loopcheck.c" -o "${workdir}/context/loopcheck"
cat >"${workdir}/context/Dockerfile" <<'EOF'
FROM docker.io/library/alpine:3.20
COPY loopcheck /loopcheck
RUN ["/loopcheck"]
EOF
"${spore_bin}" build --network none --tag local/loopback:smoke "${workdir}/context"
"${spore_bin}" run --backend "${backend}" --image local/loopback:smoke -- /loopcheck

echo "smoke:loopback ok backend=${backend}"
