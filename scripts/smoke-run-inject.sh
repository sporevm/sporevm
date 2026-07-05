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

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-run-inject.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

rootfs_cache="${workdir}/rootfs-cache"
payload="${workdir}/payload.txt"
stdout_path="${workdir}/run.stdout"
stderr_path="${workdir}/run.stderr"
capture_stderr="${workdir}/capture.stderr"
image_ref="${SPORE_SMOKE_INJECT_IMAGE:-docker.io/library/alpine:3.20}"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
token="spore-run-inject-${RANDOM}-${RANDOM}"

mkdir -p "${rootfs_cache}"
printf '%s\n' "${token}" >"${payload}"

SPOREVM_ROOTFS_CACHE_DIR="${rootfs_cache}" "${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --inject payload="${payload}" \
  -- /bin/cat /run/sporevm/injected/payload \
  >"${stdout_path}" 2>"${stderr_path}" || {
  cat "${stdout_path}" >&2 || true
  cat "${stderr_path}" >&2 || true
  die "spore run with injected file failed"
}

grep -Fxq "${token}" "${stdout_path}" || {
  cat "${stdout_path}" >&2 || true
  cat "${stderr_path}" >&2 || true
  die "injected file was not readable in the guest"
}

if grep -R -a -F -q "${token}" "${rootfs_cache}"; then
  die "injected file leaked into the rootfs cache"
fi

if "${spore_bin}" run --inject payload="${payload}" --save "${workdir}/bad.spore" -- /bin/true >"${workdir}/capture.stdout" 2>"${capture_stderr}"; then
  die "spore run accepted --inject with --save"
fi
grep -Fq "injected files are intentionally not persisted" "${capture_stderr}" || {
  cat "${capture_stderr}" >&2 || true
  die "capture rejection did not explain injected file persistence"
}

echo "smoke:run-inject ok backend=${backend} image=${image_ref}"
