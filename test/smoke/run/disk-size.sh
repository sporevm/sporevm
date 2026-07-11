#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
    *) die "cannot infer a supported backend; set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
  esac
}

authoritative_cache_state() {
  local cache_root="$1"
  {
    for rel in refs/local build/steps cas/rootfs/blake3/indexes cas/rootfs/blake3/objects cas/rootfs/blake3/complete; do
      if [[ -d "${cache_root}/${rel}" ]]; then
        find "${cache_root}/${rel}" -type f -print
      fi
    done | LC_ALL=C sort | while IFS= read -r path; do
      cksum "${path}"
    done
  } | cksum | awk '{ print $1 ":" $2 }'
}

backend="$(infer_backend)"
image_ref="${SPORE_SMOKE_IMAGE:-docker.io/library/alpine:3.20}"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-run-disk-size.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"

if "${spore_bin}" run --image "${image_ref}" --disk-size 2gb -- /bin/true >"${workdir}/invalid.stdout" 2>"${workdir}/invalid.stderr"; then
  die "--disk-size was accepted without --commit"
fi

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --commit local/run-disk-size:base \
  -- /bin/true

base_before="$("${spore_bin}" rootfs resolve local/run-disk-size:base)"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --vcpus 2 \
  --image local/run-disk-size:base \
  --pull=never \
  --disk-size 2gb \
  --commit local/run-disk-size:grown \
  -- /bin/sh -lc 'test ! -x /sbin/resize2fs && test ! -x /usr/sbin/resize2fs && test "$(cat /sys/class/block/vda/size)" -eq 4194304 && test "$(df -k / | awk "NR == 2 { print \$2 }")" -gt 1500000 && echo ready >/grown-marker'

base_after="$("${spore_bin}" rootfs resolve local/run-disk-size:base)"
[[ "${base_before}" == "${base_after}" ]] || die "successful growth changed the source ref"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:grown \
  --pull=never \
  -- /bin/sh -lc 'test "$(cat /sys/class/block/vda/size)" -eq 4194304 && grep -Fxq ready /grown-marker'

grown_before="$("${spore_bin}" rootfs resolve local/run-disk-size:grown)"

failure_context="${workdir}/failure-context"
mkdir -p "${failure_context}"
printf 'FROM local/run-disk-size:base\nRUN /bin/true\n' >"${failure_context}/Dockerfile"
cache_before="$(authoritative_cache_state "${SPOREVM_ROOTFS_CACHE_DIR}")"
if SPOREVM_ROOTFS_GROWTH_EXPERIMENTS=1 \
  SPOREVM_WRITE_ZEROES_FORCE_BACKEND_FAILURE_EXPERIMENT=1 \
  "${spore_bin}" --debug build \
    --network none \
    --no-cache \
    -t local/run-disk-size:grown \
    "${failure_context}" >"${workdir}/forced-failure.stdout" 2>"${workdir}/forced-failure.stderr"; then
  failure_status=0
else
  failure_status=$?
fi
if [[ "${failure_status}" -ne 2 ]]; then
  cat "${workdir}/forced-failure.stderr" >&2
  die "forced rootfs growth failure exited with status ${failure_status}, expected 2"
fi
if ! grep -Fq 'rootfs storage failed after a validated write; unpublished state was discarded' "${workdir}/forced-failure.stderr"; then
  cat "${workdir}/forced-failure.stderr" >&2
  die "forced growth failure did not reach the validated storage failure path"
fi
if ! grep -Eq 'write_zeroes_backend_failures=[1-9][0-9]*' "${workdir}/forced-failure.stderr"; then
  cat "${workdir}/forced-failure.stderr" >&2
  die "forced growth failure did not report a poisoned backend mutation"
fi
grown_after_failure="$("${spore_bin}" rootfs resolve local/run-disk-size:grown)"
[[ "${grown_before}" == "${grown_after_failure}" ]] || die "growth failure changed the destination ref"
cache_after="$(authoritative_cache_state "${SPOREVM_ROOTFS_CACHE_DIR}")"
[[ "${cache_before}" == "${cache_after}" ]] || die "growth failure published authoritative cache state"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:grown \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq ready /grown-marker'

if "${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:grown \
  --pull=never \
  --disk-size 1gb \
  --commit local/run-disk-size:grown \
  -- /bin/true >"${workdir}/shrink.stdout" 2>"${workdir}/shrink.stderr"; then
  die "shrinking --disk-size unexpectedly succeeded"
fi
grown_after="$("${spore_bin}" rootfs resolve local/run-disk-size:grown)"
[[ "${grown_before}" == "${grown_after}" ]] || die "shrink failure changed the destination ref"

echo "smoke:run-disk-size ok backend=${backend} image=${image_ref}"
