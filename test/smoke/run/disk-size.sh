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
  --net \
  --image "${image_ref}" \
  --commit local/run-disk-size:base \
  -- /bin/sh -lc 'apk add --no-cache e2fsprogs-extra'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:base \
  --pull=never \
  --disk-size 2gb \
  --commit local/run-disk-size:grown \
  -- /bin/sh -lc 'test "$(cat /sys/class/block/vda/size)" -eq 4194304 && echo ready >/grown-marker'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:grown \
  --pull=never \
  -- /bin/sh -lc 'test "$(cat /sys/class/block/vda/size)" -eq 4194304 && grep -Fxq ready /grown-marker'

grown_before="$("${spore_bin}" rootfs resolve local/run-disk-size:grown)"
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

base_before="$("${spore_bin}" rootfs resolve local/run-disk-size:base)"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:base \
  --pull=never \
  --commit local/run-disk-size:no-resize-tool \
  -- /bin/sh -lc 'rm /usr/sbin/resize2fs'
if "${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-disk-size:no-resize-tool \
  --pull=never \
  --disk-size 2gb \
  --commit local/run-disk-size:base \
  -- /bin/true >"${workdir}/resize-failure.stdout" 2>"${workdir}/resize-failure.stderr"; then
  die "image without resize2fs unexpectedly grew"
fi
base_after="$("${spore_bin}" rootfs resolve local/run-disk-size:base)"
[[ "${base_before}" == "${base_after}" ]] || die "resize failure changed the destination ref"

echo "smoke:run-disk-size ok backend=${backend} image=${image_ref}"
