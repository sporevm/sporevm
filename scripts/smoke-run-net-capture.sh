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

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net-capture.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

capture_dir="${workdir}/captured-net.spore"
capture_stdout="${workdir}/capture.stdout"
capture_stderr="${workdir}/capture.stderr"
from_stdout="${workdir}/from.stdout"
from_stderr="${workdir}/from.stderr"
deny_stdout="${workdir}/deny.stdout"
deny_stderr="${workdir}/deny.stderr"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory-mib "${SPORE_SMOKE_MEMORY_MIB:-256}" \
  --net \
  --allow-host example.com \
  --capture "${capture_dir}" \
  -- /bin/true \
  >"${capture_stdout}" 2>"${capture_stderr}"

manifest="${capture_dir}/manifest.json"
[[ -f "${manifest}" ]] || die "network capture did not write ${manifest}"
grep -Fq "spore-net-v0" "${manifest}" || die "captured manifest did not record spore-net-v0"
grep -Fq "example.com" "${manifest}" || die "captured manifest did not record allow-host policy"

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${capture_dir}" \
  -- /bin/wget -qO- http://example.com/ \
  >"${from_stdout}" 2>"${from_stderr}"

grep -Fq "Example Domain" "${from_stdout}" || {
  cat "${from_stdout}" >&2 || true
  cat "${from_stderr}" >&2 || true
  die "spore run --from did not reattach network policy for example.com"
}

set +e
"${spore_bin}" --debug run \
  --backend "${backend}" \
  --from "${capture_dir}" \
  -- /bin/wget -qO- http://169.254.169.254/ \
  >"${deny_stdout}" 2>"${deny_stderr}"
deny_rc="$?"
set -e

if [[ "${deny_rc}" == "0" ]]; then
  cat "${deny_stdout}" >&2 || true
  cat "${deny_stderr}" >&2 || true
  die "spore run --from unexpectedly reached a hard-floor destination"
fi

grep -Fq "denied egress" "${deny_stderr}" || {
  cat "${deny_stderr}" >&2 || true
  die "resumed network policy did not log denied egress"
}

echo "smoke:run-net-capture ok backend=${backend}"
