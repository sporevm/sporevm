#!/usr/bin/env bash
# Saves a Ruby spore, pushes it to a directory store, serves the store over
# loopback HTTP, and pulls it COUNT times (the first from the directory, the
# rest over HTTP), each into an empty rootfs cache. Each pulled spore runs with
# its own --generation identity, which the guest must see.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

count="${SPORE_SMOKE_LOCAL_PULL_COUNT:-3}"
case "${count}" in
  ''|*[!0-9]*) die "SPORE_SMOKE_LOCAL_PULL_COUNT must be a positive integer" ;;
esac
[[ "${count}" != "0" ]] || die "SPORE_SMOKE_LOCAL_PULL_COUNT must be greater than zero"

image_ref="${SPORE_SMOKE_ROOTFS_IMAGE:-docker.io/library/ruby:3.3-alpine}"
platform="${SPORE_SMOKE_ROOTFS_PLATFORM:-linux/arm64}"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-local-pull"
server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}

push_rootfs_cache="${workdir}/push-rootfs-cache"
capture_dir="${workdir}/ruby.spore"
store_dir="${workdir}/store"

resolved_image_ref="$(SPOREVM_ROOTFS_CACHE_DIR="${push_rootfs_cache}" "${spore_bin}" image resolve "${image_ref}" --platform "${platform}")"
printf 'rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

SPOREVM_ROOTFS_CACHE_DIR="${push_rootfs_cache}" "${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --save-checkpoint "${capture_dir}" \
  -- /bin/sh -c 'echo saved >/saved-marker' \
  >"${workdir}/run.stdout" 2>"${workdir}/run.stderr" || {
  cat "${workdir}/run.stderr" >&2 || true
  die "spore run --save failed"
}
[[ -f "${capture_dir}/manifest.json" ]] || die "save did not write ${capture_dir}/manifest.json"

SPOREVM_ROOTFS_CACHE_DIR="${push_rootfs_cache}" "${spore_bin}" --json checkpoint push "${capture_dir}" --to "${store_dir}/ruby" >"${workdir}/push.json"
spore_digest="$(json_field "${workdir}/push.json" spore_digest)"
[[ "${spore_digest}" == blake3:* ]] || die "push reported spore digest ${spore_digest}"

# `python3 -m http.server` with a listen backlog above its 5: a pull fetches
# 16 objects at once, and Linux retries connections past the backlog a second
# later.
python3 -u - "${store_dir}" >"${workdir}/server.out" 2>"${workdir}/server.err" <<'PY' &
import functools
import http.server
import sys


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 128


handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with Server(("127.0.0.1", 0), handler) as server:
    print(f"port {server.server_address[1]}")
    server.serve_forever()
PY
server_pid=$!
port=""
for _ in $(seq 1 100); do
  port="$(sed -n 's/^port \([0-9][0-9]*\)$/\1/p' "${workdir}/server.out")"
  [[ -n "${port}" ]] && break
  sleep 0.1
done
[[ -n "${port}" ]] || die "image store server did not start"

for i in $(seq 0 $((count - 1))); do
  ref="http://127.0.0.1:${port}/ruby"
  [[ "${i}" == "0" ]] && ref="file://${store_dir}/ruby"
  cache="${workdir}/pull-rootfs-cache-${i}"
  pulled="${workdir}/pulled-${i}.spore"
  pull_json="${workdir}/pull-${i}.json"
  SPOREVM_ROOTFS_CACHE_DIR="${cache}" "${spore_bin}" --json checkpoint pull "${ref}" --output "${pulled}" >"${pull_json}"
  expect_eq "$(json_field "${pull_json}" spore_digest)" "${spore_digest}" "pull ${i} spore digest"
  ram_fetched="$(json_field "${pull_json}" ram.objects_fetched)"
  disk_objects="$(json_field "${pull_json}" disk.objects)"
  disk_fetched="$(json_field "${pull_json}" disk.objects_fetched)"
  ((ram_fetched > 0)) || die "pull ${i} fetched no RAM objects"
  expect_eq "${disk_fetched}" "${disk_objects}" "pull ${i} disk objects fetched into an empty cache"
  printf 'pull %s: %s RAM objects (%s bytes), %s disk objects (%s bytes)\n' "${i}" \
    "${ram_fetched}" "$(json_field "${pull_json}" ram.bytes_fetched)" \
    "${disk_fetched}" "$(json_field "${pull_json}" disk.bytes_fetched)"

  generation_json="${workdir}/generation-${i}.json"
  cat >"${generation_json}" <<JSON
{"run_id":"local-pull-smoke","child_id":${i},"parallel_index":${i},"parallel_count":${count},"fork_index":${i},"fork_count":${count},"fork_batch_id":"local-pull-batch","vm_id":"local-pull-${i}"}
JSON
  SPOREVM_ROOTFS_CACHE_DIR="${cache}" "${spore_bin}" run \
    --backend "${backend}" \
    --checkpoint "${pulled}" \
    --generation "${generation_json}" \
    -- /bin/sh -c 'cat /saved-marker /run/sporevm/env /run/sporevm/generation.json' \
    >"${workdir}/from-${i}.stdout" 2>"${workdir}/from-${i}.stderr" || {
    cat "${workdir}/from-${i}.stderr" >&2 || true
    die "spore run --from pulled spore ${i} failed"
  }
  grep -Fxq saved "${workdir}/from-${i}.stdout" || die "pulled spore ${i} lost the saved disk change"
  if ! grep -Fxq "SPORE_VM_ID=local-pull-${i}" "${workdir}/from-${i}.stdout" ||
    ! grep -Fxq "SPORE_PARALLEL_JOB=${i}" "${workdir}/from-${i}.stdout" ||
    ! grep -Fq "\"local-pull-${i}\"" "${workdir}/from-${i}.stdout"; then
    cat "${workdir}/from-${i}.stdout" >&2 || true
    die "pulled spore ${i} did not see its generation identity"
  fi
done

served="$(grep -c '"GET /spores/' "${workdir}/server.err" || true)"
expect_eq "${served}" "$((count - 1))" "spore manifests served over HTTP"

echo "smoke:local-pull ok backend=${backend} count=${count} image=${resolved_image_ref}"
