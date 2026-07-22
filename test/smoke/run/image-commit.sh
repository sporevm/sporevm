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
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-run-image-commit.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"

expect_rejected() {
  local name="$1"
  shift
  if "${spore_bin}" run "$@" >"${workdir}/${name}.stdout" 2>"${workdir}/${name}.stderr"; then
    die "run --commit accepted incompatible ${name} options"
  fi
}

expect_rejected remote-ref --image "${image_ref}" --commit registry.example/project:tag -- /bin/true
expect_rejected raw-rootfs --rootfs missing.ext4 --commit local/run-commit-smoke:bad -- /bin/true
expect_rejected saved-spore --from missing.spore --commit local/run-commit-smoke:bad -- /bin/true
expect_rejected save --image "${image_ref}" --commit local/run-commit-smoke:bad --save "${workdir}/bad.spore" -- /bin/true
expect_rejected interactive -i --image "${image_ref}" --commit local/run-commit-smoke:bad -- /bin/true

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --commit local/run-commit-smoke:default-command
"${spore_bin}" rootfs resolve local/run-commit-smoke:default-command >/dev/null

payload="${workdir}/payload.txt"
printf 'copied-from-transient-injection\n' >"${payload}"

events="${workdir}/commit.jsonl"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --events=jsonl \
  --image "${image_ref}" \
  --commit local/run-commit-smoke:base \
  --inject payload="${payload}" \
  -- /bin/sh -lc 'cat /run/sporevm/injected/payload >/committed.txt' \
  >"${events}"

grep -Fq '"event":"image_committed"' "${events}" || die "commit did not emit image_committed"
grep -Fq '"ref":"local/run-commit-smoke:base"' "${events}" || die "commit event omitted the mutable ref"
grep -Fq '"resolved_image_ref":"local/run-commit-smoke@blake3:' "${events}" || die "commit event omitted immutable image identity"
grep -Fq '"rootfs_index_digest":"blake3:' "${events}" || die "commit event omitted the rootfs index digest"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq copied-from-transient-injection /committed.txt && test ! -e /run/sporevm/injected/payload'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --commit local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'echo refreshed >/refreshed.txt'
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq refreshed /refreshed.txt'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --vcpus 2 \
  --image local/run-commit-smoke:base \
  --commit local/run-commit-smoke:multi-vcpu \
  --pull=never \
  -- /bin/sh -lc 'echo multi-vcpu >/multi-vcpu.txt'
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:multi-vcpu \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq multi-vcpu /multi-vcpu.txt'

before="$("${spore_bin}" rootfs resolve local/run-commit-smoke:base)"
if "${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --commit local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'echo discarded >/failed.txt; exit 23'; then
  die "nonzero guest command unexpectedly succeeded"
fi
after="$("${spore_bin}" rootfs resolve local/run-commit-smoke:base)"
[[ "${before}" == "${after}" ]] || die "nonzero command changed the destination ref"

warm_spore="${workdir}/warm.spore"
children_dir="${workdir}/children"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --pull=never \
  --save "${warm_spore}" \
  -- /bin/sh -lc 'test ! -e /failed.txt && grep -Fxq copied-from-transient-injection /committed.txt'
"${spore_bin}" fork "${warm_spore}" --count 2 --out "${children_dir}"

children=("${children_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9])
[[ "${#children[@]}" -eq 2 ]] || die "fork did not create two children"
"${spore_bin}" run \
  --backend "${backend}" \
  --from "${children[0]}" \
  -- /bin/sh -lc 'test ! -e /child-private && grep -Fxq copied-from-transient-injection /committed.txt && echo child-0 >/child-private'
"${spore_bin}" run \
  --backend "${backend}" \
  --from "${children[1]}" \
  -- /bin/sh -lc 'test ! -e /child-private && grep -Fxq copied-from-transient-injection /committed.txt && echo child-1 >/child-private'

echo "smoke:run-image-commit ok backend=${backend} image=${image_ref}"
