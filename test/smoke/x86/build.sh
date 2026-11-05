#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
release="${SPOREVM_KERNEL_RELEASE:-v0.7.1}"
asset="sporevm-x86_64-linux-6.1.191-bzImage"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 build smoke requires Linux/x86_64"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-build.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
export SPOREVM_KERNEL_CACHE_DIR="${workdir}/kernel-cache"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
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

python3 "${repo_root}/scripts/spore-build-conformance.py" --self-test-schema

build_context="${workdir}/build-context"
mkdir -p "${build_context}"
printf 'native context payload\n' >"${build_context}/payload.txt"
cat >"${build_context}/Dockerfile" <<'EOF'
FROM --platform=$TARGETPLATFORM docker.io/library/alpine:3.20 AS native
ARG TARGETARCH
COPY payload.txt /build-context
RUN --mount=type=cache,target=/cache,id=build-$TARGETARCH test "$TARGETARCH" = amd64 && grep -Fxq 'native context payload' /build-context && printf '%s\n' "$TARGETARCH" >/build-arch

FROM --platform=$TARGETPLATFORM docker.io/library/alpine:3.20 AS second
RUN printf '%s\n' second >/build-second

FROM --platform=$TARGETPLATFORM docker.io/library/alpine:3.20
COPY --from=native /build-context /build-context
COPY --from=native /build-arch /build-arch
COPY --from=second /build-second /build-second
RUN test "$(cat /build-arch)" = amd64 && grep -Fxq 'native context payload' /build-context && grep -Fxq second /build-second
CMD ["/bin/true"]
EOF

build_tag="local/x86-build:conformance"
"${spore_bin}" build --network none --tag "${build_tag}" "${build_context}" \
  >"${workdir}/build-first.log"
"${spore_bin}" build --network none --tag "${build_tag}" "${build_context}" \
  >"${workdir}/build-warm.log"
grep -Fq 'executed_steps=0 boot_count=0' "${workdir}/build-warm.log" || \
  die "warm native build did not reuse the complete Dockerfile cache"
"${spore_bin}" run --backend kvm --memory 512mib --image "${build_tag}" --pull=never -- \
  /bin/sh -lc 'test "$(cat /build-arch)" = amd64 && grep -Fxq "native context payload" /build-context'

"${repo_root}/test/smoke/x86/fail-closed.sh"

if find "${SPOREVM_RUNTIME_DIR}" -mindepth 2 -print -quit | grep -q .; then
  find "${SPOREVM_RUNTIME_DIR}" -mindepth 2 -maxdepth 3 -print >&2
  die "x86 build checks left runtime residue"
fi

echo "smoke:x86-build ok"
