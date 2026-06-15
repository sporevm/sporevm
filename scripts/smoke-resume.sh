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
if [[ -z "${CC:-}" ]]; then
  if command -v mise >/dev/null 2>&1; then
    export CC="mise exec -- zig cc -target aarch64-linux-musl"
  elif command -v zig >/dev/null 2>&1; then
    export CC="zig cc -target aarch64-linux-musl"
  else
    die "CC is unset and neither mise nor zig is available for the aarch64 smoke initrd"
  fi
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-resume.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

initrd="${workdir}/ticker.cpio"
spore_dir="${workdir}/ticker.spore"
resume_log="${workdir}/product-resume.log"

"${repo_root}/scripts/make-smoke-initrd.sh" "${initrd}" >/dev/null
"${repo_root}/scripts/smoke-restore-leg.sh" capture \
  --backend "${backend}" \
  --initrd "${initrd}" \
  --spore-dir "${spore_dir}" \
  --snapshot-after-ms "${SPORE_SMOKE_SNAPSHOT_AFTER_MS:-1000}" \
  --mem-mib "${SPORE_SMOKE_MEM_MIB:-512}" \
  >/dev/null

"${spore_bin}" resume --backend "${backend}" "${spore_dir}" >"${resume_log}" 2>&1 &
resume_pid="$!"
seen_tick=0
for _ in $(seq 1 "${SPORE_SMOKE_RESUME_POLLS:-80}"); do
  if grep -Eaq 'sporevm-initrd-tick [0-9]+' "${resume_log}"; then
    seen_tick=1
    break
  fi
  sleep "${SPORE_SMOKE_RESUME_POLL_INTERVAL:-0.1}"
done

kill -TERM "${resume_pid}" >/dev/null 2>&1 || true
sleep 0.2
kill -KILL "${resume_pid}" >/dev/null 2>&1 || true
wait "${resume_pid}" >/dev/null 2>&1 || true

if [[ "${seen_tick}" != "1" ]]; then
  tail -80 "${resume_log}" >&2 || true
  die "product resume did not stream a ticker line"
fi

echo "smoke:resume ok backend=${backend}"
