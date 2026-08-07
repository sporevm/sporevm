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

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 Slice 3c smoke requires Linux/x86_64"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-slice3c.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
export SPOREVM_KERNEL_CACHE_DIR="${workdir}/kernel-cache"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
export SPORE_BACKEND=kvm
export SPORE_SMOKE_MEMORY_MIB=512
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
FROM --platform=$TARGETPLATFORM docker.io/library/alpine:3.20
ARG TARGETARCH
COPY payload.txt /slice3c-context
RUN --mount=type=cache,target=/cache,id=slice3c-$TARGETARCH test "$TARGETARCH" = amd64 && grep -Fxq 'native context payload' /slice3c-context && printf '%s\n' "$TARGETARCH" >/slice3c-arch
CMD ["/bin/true"]
EOF

build_tag="local/x86-slice3c:conformance"
"${spore_bin}" build --network none --tag "${build_tag}" "${build_context}" \
  >"${workdir}/build-first.log"
"${spore_bin}" build --network none --tag "${build_tag}" "${build_context}" \
  >"${workdir}/build-warm.log"
grep -Fq 'executed_steps=0 boot_count=0' "${workdir}/build-warm.log" || \
  die "warm native build did not reuse the complete Dockerfile cache"
"${spore_bin}" run --backend kvm --memory 512mib --image "${build_tag}" --pull=never -- \
  /bin/sh -lc 'test "$(cat /slice3c-arch)" = amd64 && grep -Fxq "native context payload" /slice3c-context'

run_path="/usr/bin:/bin:/usr/sbin:/sbin"
if env -i PATH="${run_path}" /bin/sh -c 'command -v spore >/dev/null 2>&1'; then
  die "test PATH unexpectedly resolves spore"
fi

consumer_env=(env -i
  HOME="${HOME:-/tmp}"
  TMPDIR="${TMPDIR:-/tmp}"
  PATH="${run_path}"
  SPOREVM_KERNEL_CACHE_DIR="${SPOREVM_KERNEL_CACHE_DIR}"
  SPOREVM_ROOTFS_CACHE_DIR="${SPOREVM_ROOTFS_CACHE_DIR}"
  SPOREVM_RUNTIME_DIR="${SPOREVM_RUNTIME_DIR}")

"${consumer_env[@]}" "${repo_root}/zig-out/bin/libspore-zig-fresh-smoke"
"${consumer_env[@]}" "${repo_root}/zig-out/bin/libspore-c-smoke" \
  --fresh-run "c-standalone-kvm-$$"
"${repo_root}/test/smoke/libspore/standalone-go.sh"
"${repo_root}/test/smoke/x86/fail-closed.sh"

if find "${SPOREVM_RUNTIME_DIR}" -mindepth 2 -print -quit | grep -q .; then
  find "${SPOREVM_RUNTIME_DIR}" -mindepth 2 -maxdepth 3 -print >&2
  die "Slice 3c checks left runtime residue"
fi

echo "smoke:x86-slice3c ok"
