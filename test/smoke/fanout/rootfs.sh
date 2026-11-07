#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

count="${SPORE_SMOKE_ROOTFS_FANOUT_COUNT:-3}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_ROOTFS_FANOUT_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_ROOTFS_FANOUT_COUNT must be greater than zero"

image_ref="${SPORE_SMOKE_ROOTFS_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_SMOKE_ROOTFS_PLATFORM:-linux/arm64}"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-rootfs-fanout"
# Image-backed saves must share a filesystem with the rootfs cache.
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
child_pids=()
cleanup() {
  if ((${#child_pids[@]})); then
    for pid in "${child_pids[@]}"; do
      kill -TERM "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    done
  fi
}

capture_dir="${workdir}/ruby-base.spore"
fork_dir="${workdir}/children"
run_stdout="${workdir}/run.stdout"
run_stderr="${workdir}/run.stderr"
base_from_stdout="${workdir}/run-from-base.stdout"
base_from_stderr="${workdir}/run-from-base.stderr"
if [[ "${image_ref}" == *@sha256:* ]]; then
  resolved_image_ref="${image_ref}"
else
  resolved_image_ref="$("${spore_bin}" image resolve "${image_ref}" --platform "${platform}")"
fi
printf 'rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --save "${capture_dir}" \
  -- /bin/true \
  >"${run_stdout}" 2>"${run_stderr}" || {
  cat "${run_stdout}" >&2 || true
  cat "${run_stderr}" >&2 || true
  die "spore run rootfs base capture failed"
}
[[ -f "${capture_dir}/manifest.json" ]] || die "capture did not write ${capture_dir}/manifest.json"
grep -Fq '"rootfs"' "${capture_dir}/manifest.json" || die "capture manifest did not record rootfs metadata"
grep -Fq '"digest": "blake3:' "${capture_dir}/manifest.json" || die "capture manifest did not record a rootfs digest"

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${capture_dir}" \
  -- /bin/sh -lc 'echo rootfs-base-out; echo rootfs-base-err >&2' \
  >"${base_from_stdout}" 2>"${base_from_stderr}" || {
  cat "${base_from_stdout}" >&2 || true
  cat "${base_from_stderr}" >&2 || true
  die "rootfs base run-from output command failed"
}
grep -Fxq "rootfs-base-out" "${base_from_stdout}" || {
  cat "${base_from_stdout}" >&2 || true
  cat "${base_from_stderr}" >&2 || true
  die "rootfs base run-from did not stream stdout"
}
grep -Fxq "rootfs-base-err" "${base_from_stderr}" || {
  cat "${base_from_stdout}" >&2 || true
  cat "${base_from_stderr}" >&2 || true
  die "rootfs base run-from did not stream stderr"
}

"${spore_bin}" checkpoint fork "${capture_dir}" --count "${count}" --out "${fork_dir}" >"${workdir}/fork.stdout" 2>"${workdir}/fork.stderr"

children=()
while IFS= read -r child; do
  children+=("${child}")
done < <(fork_children "${fork_dir}")
[[ "${#children[@]}" == "${count}" ]] || die "expected ${count} child spores, found ${#children[@]}"

child_stdout=()
child_stderr=()
for child in "${children[@]}"; do
  child_name="$(basename "${child}")"
  stdout_path="${workdir}/run-from-${child_name}.stdout"
  stderr_path="${workdir}/run-from-${child_name}.stderr"
  child_stdout+=("${stdout_path}")
  child_stderr+=("${stderr_path}")
  "${spore_bin}" run \
    --backend "${backend}" \
    --from "${child}" \
    -- /usr/local/bin/ruby \
      -e 'STDOUT.sync = true; STDERR.sync = true; child = ARGV.fetch(0); puts "ruby child #{child}"; warn "ruby stderr #{child}"' \
      "${child_name}" \
    >"${stdout_path}" 2>"${stderr_path}" &
  child_pids+=("$!")
done

failed=0
for i in "${!child_pids[@]}"; do
  pid="${child_pids[$i]}"
  set +e
  wait "${pid}"
  rc="$?"
  set -e
  if [[ "${rc}" != "0" ]]; then
    cat "${child_stdout[$i]}" >&2 || true
    cat "${child_stderr[$i]}" >&2 || true
    failed=1
  fi
done
child_pids=()
[[ "${failed}" == "0" ]] || die "one or more rootfs child run-from commands failed"

for i in "${!children[@]}"; do
  child_name="$(basename "${children[$i]}")"
  if ! grep -Fxq "ruby child ${child_name}" "${child_stdout[$i]}"; then
    cat "${child_stdout[$i]}" >&2 || true
    cat "${child_stderr[$i]}" >&2 || true
    die "child ${child_name} did not stream run-from stdout"
  fi
  if ! grep -Fxq "ruby stderr ${child_name}" "${child_stderr[$i]}"; then
    cat "${child_stdout[$i]}" >&2 || true
    cat "${child_stderr[$i]}" >&2 || true
    die "child ${child_name} did not stream run-from stderr"
  fi
done

echo "smoke:rootfs-fanout ok backend=${backend} count=${count} image=${resolved_image_ref}"
