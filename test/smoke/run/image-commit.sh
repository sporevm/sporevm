#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin
image_ref="${SPORE_SMOKE_IMAGE:-docker.io/library/alpine:3.20}"
if [[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]]; then
  default_smoke_memory="512mib"
  default_smoke_platform="linux/amd64"
  x86_fresh_only=1
else
  default_smoke_memory="256mib"
  default_smoke_platform="linux/arm64"
  x86_fresh_only=0
fi
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-${default_smoke_memory%mib}}mib}"
smoke_platform="${SPORE_SMOKE_PLATFORM:-${default_smoke_platform}}"
smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-run-image-commit"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"

expect_rejected() {
  local name="$1"
  shift
  if "${spore_bin}" run "$@" >"${workdir}/${name}.stdout" 2>"${workdir}/${name}.stderr"; then
    die "run --commit accepted incompatible ${name} options"
  fi
}

expect_rejected remote-ref --image "${image_ref}" --commit-image registry.example/project:tag -- /bin/true
expect_rejected raw-rootfs --rootfs missing.ext4 --commit-image local/run-commit-smoke:bad -- /bin/true
expect_rejected saved-spore --checkpoint missing.spore --commit-image local/run-commit-smoke:bad -- /bin/true
expect_rejected save --image "${image_ref}" --commit-image local/run-commit-smoke:bad --save-checkpoint "${workdir}/bad.spore" -- /bin/true
expect_rejected interactive -i --image "${image_ref}" --commit-image local/run-commit-smoke:bad -- /bin/true

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --commit-image local/run-commit-smoke:default-command
"${spore_bin}" image resolve local/run-commit-smoke:default-command --platform "${smoke_platform}" >/dev/null

payload="${workdir}/payload.txt"
printf 'copied-from-transient-injection\n' >"${payload}"

events="${workdir}/commit.jsonl"
"${spore_bin}" --json run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --commit-image local/run-commit-smoke:base \
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
  --commit-image local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'echo refreshed >/refreshed.txt'
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq refreshed /refreshed.txt'

if (( ! x86_fresh_only )); then
  "${spore_bin}" run \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --vcpus 2 \
    --image local/run-commit-smoke:base \
    --commit-image local/run-commit-smoke:multi-vcpu \
    --pull=never \
    -- /bin/sh -lc 'echo multi-vcpu >/multi-vcpu.txt'
  "${spore_bin}" run \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --image local/run-commit-smoke:multi-vcpu \
    --pull=never \
    -- /bin/sh -lc 'grep -Fxq multi-vcpu /multi-vcpu.txt'
fi

before="$("${spore_bin}" image resolve local/run-commit-smoke:base --platform "${smoke_platform}")"
if "${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --commit-image local/run-commit-smoke:base \
  --pull=never \
  -- /bin/sh -lc 'echo discarded >/failed.txt; exit 23'; then
  die "nonzero guest command unexpectedly succeeded"
fi
after="$("${spore_bin}" image resolve local/run-commit-smoke:base --platform "${smoke_platform}")"
[[ "${before}" == "${after}" ]] || die "nonzero command changed the destination ref"

if (( x86_fresh_only )); then
  if "${spore_bin}" run \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --timeout 100ms \
    --image local/run-commit-smoke:base \
    --commit-image local/run-commit-smoke:timed-out \
    --pull=never \
    -- /bin/sh -lc 'sleep 5'; then
    die "timed-out x86 commit command unexpectedly succeeded"
  fi
  if "${spore_bin}" image resolve local/run-commit-smoke:timed-out --platform "${smoke_platform}" >/dev/null 2>&1; then
    die "timed-out x86 commit published the destination ref"
  fi
  echo "smoke:run-image-commit ok backend=${backend} image=${image_ref} fresh-only=1"
  exit 0
fi

warm_spore="${workdir}/warm.spore"
children_dir="${workdir}/children"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image local/run-commit-smoke:base \
  --pull=never \
  --save-checkpoint "${warm_spore}" \
  -- /bin/sh -lc 'test ! -e /failed.txt && grep -Fxq copied-from-transient-injection /committed.txt'
"${spore_bin}" checkpoint fork "${warm_spore}" --count 2 --output "${children_dir}"

children=("${children_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9])
[[ "${#children[@]}" -eq 2 ]] || die "fork did not create two children"
"${spore_bin}" run \
  --backend "${backend}" \
  --checkpoint "${children[0]}" \
  -- /bin/sh -lc 'test ! -e /child-private && grep -Fxq copied-from-transient-injection /committed.txt && echo child-0 >/child-private'
"${spore_bin}" run \
  --backend "${backend}" \
  --checkpoint "${children[1]}" \
  -- /bin/sh -lc 'test ! -e /child-private && grep -Fxq copied-from-transient-injection /committed.txt && echo child-1 >/child-private'

echo "smoke:run-image-commit ok backend=${backend} image=${image_ref}"
