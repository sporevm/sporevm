#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

infer_backend() {
  if [[ -n "${SPORE_BACKEND:-}" ]]; then
    echo "${SPORE_BACKEND}"
    return
  fi

  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "hvf" ;;
    Linux-aarch64|Linux-arm64) echo "kvm" ;;
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
  esac
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"
command -v go >/dev/null 2>&1 || die "go not found on PATH"

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac

run_path="/usr/bin:/bin:/usr/sbin:/sbin"
if env -i PATH="${run_path}" /bin/sh -c 'command -v spore >/dev/null 2>&1'; then
  die "test PATH unexpectedly resolves spore"
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-libspore-go.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-libspore-go.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

plain_name="go-standalone-${backend}-$$"
network_name="${plain_name}-net"
cleanup() {
  if [[ -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    echo "smoke:libspore-standalone-go kept workdir=${workdir} runtime_dir=${runtime_dir}" >&2
    return
  fi
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${plain_name}" >/dev/null 2>&1 || true
  env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${network_name}" >/dev/null 2>&1 || true
  rm -rf "${runtime_dir}"
  rm -rf "${workdir}"
}
trap cleanup EXIT

cp "${repo_root}/test/go/standalone-libspore/main.go" "${workdir}/main.go"
cat >"${workdir}/go.mod" <<EOF
module standalone-libspore-smoke

go 1.26

require github.com/sporevm/sporevm/bindings/go v0.0.0

replace github.com/sporevm/sporevm/bindings/go => ${repo_root}/bindings/go
EOF

embedder="${workdir}/standalone-libspore"
(
  cd "${workdir}"
  env \
    PKG_CONFIG_PATH="${repo_root}/zig-out/lib/pkgconfig" \
    CGO_ENABLED=1 \
    go build -o "${embedder}" .
)

if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! codesign --sign - --force --entitlements "${repo_root}/spore.entitlements" "${embedder}" >/dev/null 2>&1; then
    echo "smoke:libspore-standalone-go skipped: codesign with hypervisor entitlement failed" >&2
    exit 0
  fi
fi

run_embedder() {
  env -i \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PATH="${run_path}" \
    SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    DYLD_LIBRARY_PATH="${repo_root}/zig-out/lib" \
    LD_LIBRARY_PATH="${repo_root}/zig-out/lib" \
    "$@"
}

timeout_ms="${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}"
memory_mib="${SPORE_SMOKE_MEMORY_MIB:-256}"

run_embedder "${embedder}" \
  -name "${plain_name}" \
  -backend "${backend}" \
  -memory-mib "${memory_mib}" \
  -timeout-ms "${timeout_ms}"

run_embedder "${embedder}" \
  -name "${network_name}" \
  -backend "${backend}" \
  -memory-mib "${memory_mib}" \
  -timeout-ms "${timeout_ms}" \
  -network

echo "smoke:libspore-standalone-go ok backend=${backend}"
