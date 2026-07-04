#!/usr/bin/env bash
set -euo pipefail

# Real public-internet egress smoke: with --net and an allow rule, a named VM
# must fetch an HTTPS URL whose host resolves through a CNAME chain, and a
# host outside the allow rules must stay blocked. Requires internet access,
# so it is gated for offline CI.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

if [[ "${SPORE_SMOKE_EGRESS:-0}" != "1" ]]; then
  echo "smoke:net-egress skipped (set SPORE_SMOKE_EGRESS=1 to run against the public internet)"
  exit 0
fi

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

image="${SPORE_SMOKE_EGRESS_IMAGE:-docker.io/library/alpine:3.20}"
allow_host="${SPORE_SMOKE_EGRESS_HOST:-dl-cdn.alpinelinux.org}"
fetch_url="${SPORE_SMOKE_EGRESS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/APKINDEX.tar.gz}"
min_bytes="${SPORE_SMOKE_EGRESS_MIN_BYTES:-1024}"
denied_host="${SPORE_SMOKE_EGRESS_DENIED_HOST:-example.com}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-net-egress.XXXXXX")"
runtime_parent="${SPORE_SMOKE_RUNTIME_ROOT:-/tmp}"
mkdir -p "${runtime_parent}"
runtime_dir="$(mktemp -d "${runtime_parent%/}/svm-egress.XXXXXX")"
chmod 700 "${runtime_dir}" 2>/dev/null || true

vm_name=""
cleanup() {
  if [[ -n "${vm_name}" ]]; then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${runtime_dir}" "${workdir}"
}
trap cleanup EXIT

fetch_and_assert() {
  local name="$1"
  local label="$2"
  local fetched
  fetched="$(env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    "${spore_bin}" exec "${name}" -- /bin/sh -c "wget -q -T 20 -O - '${fetch_url}' | wc -c")" || {
    die "${label}: HTTPS fetch failed"
  }
  fetched="$(echo "${fetched}" | tr -d '[:space:]')"
  [[ "${fetched}" -ge "${min_bytes}" ]] || die "${label}: fetched ${fetched} bytes, expected at least ${min_bytes}"
}

assert_denied() {
  local name="$1"
  local label="$2"
  if env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
    "${spore_bin}" exec "${name}" -- /bin/sh -c "nc -z -w 4 '${denied_host}' 443" \
    >"${workdir}/denied.out" 2>"${workdir}/denied.err"; then
    cat "${workdir}/denied.out" >&2 || true
    cat "${workdir}/denied.err" >&2 || true
    die "${label}: connect to disallowed host ${denied_host} succeeded; enforcement is broken"
  fi
}

# Exact host-port allow rule.
vm_name="egress-port-$$"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --image "${image}" \
    --net --allow-host-port "${allow_host}:443" \
    --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}ms" >/dev/null
fetch_and_assert "${vm_name}" "allow-host-port"
assert_denied "${vm_name}" "allow-host-port"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null

# Host-only allow rule.
vm_name="egress-host-$$"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" \
  "${spore_bin}" create "${vm_name}" \
    --image "${image}" \
    --net --allow-host "${allow_host}" \
    --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT_MS:-60000}ms" >/dev/null
fetch_and_assert "${vm_name}" "allow-host"
assert_denied "${vm_name}" "allow-host"
env SPOREVM_RUNTIME_DIR="${runtime_dir}" "${spore_bin}" rm "${vm_name}" >/dev/null
vm_name=""

echo "smoke:net-egress ok host=${allow_host}"
