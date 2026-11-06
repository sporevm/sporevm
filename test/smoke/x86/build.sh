#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
# shellcheck source=src/managed_kernel.env
source "${repo_root}/src/managed_kernel.env"
release="${SPOREVM_KERNEL_RELEASE:-${managed_kernel_release}}"
asset="sporevm-x86_64-linux-${managed_kernel_linux_version}-bzImage"

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 build smoke requires Linux/x86_64"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-x86-build"
export SPOREVM_KERNEL_CACHE_DIR="${workdir}/kernel-cache"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
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

python3 "${repo_root}/scripts/spore-build-conformance.py" --self-test-schema

build_context="${workdir}/build-context"
mkdir -p "${build_context}"
printf 'native context payload\n' >"${build_context}/payload.txt"
# x32 syscalls report the x86_64 audit arch with bit 30 set in the number, so
# the RUN seccomp filter must kill them instead of letting x32 socket(AF_VSOCK)
# slip past its socket check.
cat >"${workdir}/x32-probe.zig" <<'EOF'
const std = @import("std");
const linux = std.os.linux;

pub fn main() u8 {
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return 1;
    if (fork_rc == 0) {
        const rc = asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (0x40000000 | @backingInt(linux.SYS.socket)),
              [family] "{rdi}" (@as(usize, linux.AF.VSOCK)),
              [kind] "{rsi}" (@as(usize, linux.SOCK.STREAM)),
              [protocol] "{rdx}" (@as(usize, 0)),
            : .{ .rcx = true, .r11 = true, .memory = true });
        linux.exit_group(@backingInt(linux.errno(rc)));
    }
    var raw_status: i32 = 0;
    if (linux.errno(linux.waitpid(@intCast(fork_rc), &raw_status, 0)) != .SUCCESS) return 1;
    const status: u32 = @bitCast(raw_status);
    if (linux.W.IFSIGNALED(status) and linux.W.TERMSIG(status) == .SYS) return 0;
    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "x32 socket(AF_VSOCK) survived the RUN seccomp filter: wait status {d}\n", .{status}) catch unreachable;
    _ = linux.write(2, message.ptr, message.len);
    return 1;
}
EOF
zig build-exe "${workdir}/x32-probe.zig" -target x86_64-linux -O ReleaseSmall -fstrip \
  --cache-dir "${workdir}/zig-cache" -femit-bin="${build_context}/x32-probe" >/dev/null
cat >"${build_context}/Dockerfile" <<'EOF'
FROM --platform=$TARGETPLATFORM docker.io/library/alpine:3.20 AS native
ARG TARGETARCH
COPY payload.txt /build-context
COPY x32-probe /x32-probe
RUN /x32-probe
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
