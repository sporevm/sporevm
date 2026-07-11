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

clone_tree() {
  local source="$1"
  local destination="$2"
  mkdir -p "${destination}"
  if cp -a --reflink=auto "${source}/." "${destination}/" 2>/dev/null; then
    return
  fi
  if cp -cR "${source}/." "${destination}/" 2>/dev/null; then
    return
  fi
  cp -R "${source}/." "${destination}/"
}

process_has_open_path() {
  local pid="$1"
  local path="$2"
  case "$(uname -s)" in
    Linux)
      local fd
      for fd in "/proc/${pid}/fd/"*; do
        [[ -e "${fd}" ]] || continue
        [[ "$(readlink "${fd}" 2>/dev/null || true)" == "${path}" ]] && return 0
      done
      return 1
      ;;
    Darwin)
      lsof -a -p "${pid}" -- "${path}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_lock_waiter() {
  local pid="$1"
  local path="$2"
  local label="$3"
  local deadline=$((SECONDS + 10))
  while ! process_has_open_path "${pid}" "${path}"; do
    kill -0 "${pid}" 2>/dev/null || die "${label} exited before reaching the rootfs cache lock"
    ((SECONDS < deadline)) || die "${label} did not reach the rootfs cache lock"
    sleep 0.05
  done
}

build_index() {
  local stdout="$1"
  awk '/^  Rootfs index: / { print $3 }' "${stdout}" | tail -1
}

count_files() {
  local directory="$1"
  find "${directory}" -type f | wc -l | tr -d '[:space:]'
}

count_root_json() {
  local directory="$1"
  local count=0
  local path
  for path in "${directory}"/*.json; do
    [[ -f "${path}" ]] || continue
    count=$((count + 1))
  done
  echo "${count}"
}

wait_for_builds() {
  local first_pid="$1"
  local second_pid="$2"
  local deadline=$((SECONDS + 120))
  while kill -0 "${first_pid}" 2>/dev/null || kill -0 "${second_pid}" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -TERM "${first_pid}" "${second_pid}" 2>/dev/null || true
      wait "${first_pid}" 2>/dev/null || true
      wait "${second_pid}" 2>/dev/null || true
      die "concurrent preparation timed out"
    fi
    sleep 1
  done
  wait "${first_pid}" || die "first concurrent build failed"
  wait "${second_pid}" || die "second concurrent build failed"
}

backend="$(infer_backend)"
image_ref="${SPORE_SMOKE_IMAGE:-docker.io/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d}"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-build-publication.XXXXXX")"
cleanup() {
  if [[ -n "${lock_holder_pid:-}" ]]; then
    kill "${lock_holder_pid}" 2>/dev/null || true
    wait "${lock_holder_pid}" 2>/dev/null || true
  fi
  if [[ "${SPORE_SMOKE_KEEP_WORKDIR:-0}" == "1" ]]; then
    echo "retained smoke workdir: ${workdir}" >&2
  else
    rm -rf "${workdir}"
  fi
}
trap cleanup EXIT

template_cache="${workdir}/template-cache"
template_runtime="${workdir}/template-runtime"
old_context="${workdir}/old-context"
build_context="${workdir}/build-context"
mkdir -p "${template_cache}" "${template_runtime}" "${old_context}" "${build_context}"

base_ref="local/build-publication-smoke:compact"
old_ref="local/build-publication-smoke:destination"
SPOREVM_ROOTFS_CACHE_DIR="${template_cache}" \
SPOREVM_RUNTIME_DIR="${template_runtime}" \
  "${spore_bin}" run \
    --backend "${backend}" \
    --memory "${smoke_memory}" \
    --image "${image_ref}" \
    --commit "${base_ref}" \
    -- /bin/true

cat >"${old_context}/Dockerfile" <<EOF
FROM ${base_ref}
CMD ["/bin/true"]
EOF
SPOREVM_ROOTFS_CACHE_DIR="${template_cache}" \
SPOREVM_RUNTIME_DIR="${template_runtime}" \
  "${spore_bin}" build --network none -t "${old_ref}" "${old_context}" \
    >"${workdir}/old-build.stdout" 2>"${workdir}/old-build.stderr"

cat >"${build_context}/Dockerfile" <<EOF
FROM ${base_ref}
RUN printf 'publication-ok\n' >/publication-marker
EOF
mkdir -p \
  "${template_cache}/build/steps" \
  "${template_cache}/cas/rootfs/blake3/objects" \
  "${template_cache}/cas/rootfs/blake3/indexes" \
  "${template_cache}/cas/rootfs/blake3/complete" \
  "${template_cache}/refs/local"

concurrent_cache="${workdir}/concurrent-cache"
clone_tree "${template_cache}" "${concurrent_cache}"
cache_lock_path="${concurrent_cache}/.sporevm-rootfs-cache.lock"
lock_ready="${workdir}/concurrent-lock-ready"
lock_release="${workdir}/concurrent-lock-release"
python3 - "${cache_lock_path}" "${lock_ready}" "${lock_release}" <<'PY' &
import fcntl
import pathlib
import sys
import time

lock_path, ready_path, release_path = map(pathlib.Path, sys.argv[1:])
with lock_path.open("a+b") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    ready_path.touch()
    while not release_path.exists():
        time.sleep(0.01)
PY
lock_holder_pid=$!
lock_deadline=$((SECONDS + 10))
while [[ ! -f "${lock_ready}" ]]; do
  kill -0 "${lock_holder_pid}" 2>/dev/null || die "rootfs cache lock holder exited early"
  ((SECONDS < lock_deadline)) || die "timed out acquiring the rootfs cache test lock"
  sleep 0.05
done
concurrent_a="local/build-publication-smoke:concurrent-a"
concurrent_b="local/build-publication-smoke:concurrent-b"
SPOREVM_ROOTFS_CACHE_DIR="${concurrent_cache}" \
SPOREVM_RUNTIME_DIR="${workdir}/concurrent-runtime-a" \
  "${spore_bin}" --debug build --network none -t "${concurrent_a}" "${build_context}" \
    >"${workdir}/concurrent-a.stdout" 2>"${workdir}/concurrent-a.stderr" &
concurrent_a_pid=$!
SPOREVM_ROOTFS_CACHE_DIR="${concurrent_cache}" \
SPOREVM_RUNTIME_DIR="${workdir}/concurrent-runtime-b" \
  "${spore_bin}" --debug build --network none -t "${concurrent_b}" "${build_context}" \
    >"${workdir}/concurrent-b.stdout" 2>"${workdir}/concurrent-b.stderr" &
concurrent_b_pid=$!
wait_for_lock_waiter "${concurrent_a_pid}" "${cache_lock_path}" "first concurrent build"
wait_for_lock_waiter "${concurrent_b_pid}" "${cache_lock_path}" "second concurrent build"
touch "${lock_release}"
wait "${lock_holder_pid}" || die "rootfs cache lock holder failed"
lock_holder_pid=""
wait_for_builds "${concurrent_a_pid}" "${concurrent_b_pid}"

prepare_count="$(grep -Fhc 'rootfs preparation metrics:' \
  "${workdir}/concurrent-a.stderr" "${workdir}/concurrent-b.stderr" | awk '{ total += $1 } END { print total + 0 }')"
[[ "${prepare_count}" == "1" ]] || {
  cat "${workdir}/concurrent-a.stderr" >&2 || true
  cat "${workdir}/concurrent-b.stderr" >&2 || true
  die "concurrent builds performed ${prepare_count} preparations, expected exactly one"
}
concurrent_a_index="$(build_index "${workdir}/concurrent-a.stdout")"
concurrent_b_index="$(build_index "${workdir}/concurrent-b.stdout")"
[[ "${concurrent_a_index}" == blake3:* && "${concurrent_a_index}" == "${concurrent_b_index}" ]] || {
  die "concurrent builds did not publish the same rootfs identity"
}
for ref in "${concurrent_a}" "${concurrent_b}"; do
  SPOREVM_ROOTFS_CACHE_DIR="${concurrent_cache}" \
    "${spore_bin}" run --backend "${backend}" --memory "${smoke_memory}" \
      --image "${ref}" --pull=never -- /bin/sh -lc \
      'grep -Fxq publication-ok /publication-marker'
done

for boundary in object index completeness prepare-record image-metadata mutable-ref; do
  cache="${workdir}/failure-${boundary}-cache"
  runtime="${workdir}/failure-${boundary}-runtime"
  clone_tree "${template_cache}" "${cache}"
  old_resolved="$(SPOREVM_ROOTFS_CACHE_DIR="${cache}" "${spore_bin}" rootfs resolve "${old_ref}")"
  before_objects="$(count_files "${cache}/cas/rootfs/blake3/objects")"
  before_indexes="$(count_files "${cache}/cas/rootfs/blake3/indexes")"
  before_complete="$(count_files "${cache}/cas/rootfs/blake3/complete")"
  before_steps="$(count_files "${cache}/build/steps")"
  before_metadata="$(count_root_json "${cache}")"
  before_refs="$(count_files "${cache}/refs/local")"

  case "${boundary}" in
    object) blocked_path="${cache}/cas/rootfs/blake3/objects" ;;
    index) blocked_path="${cache}/cas/rootfs/blake3/indexes" ;;
    completeness) blocked_path="${cache}/cas/rootfs/blake3/complete" ;;
    prepare-record) blocked_path="${cache}/build/steps" ;;
    image-metadata) blocked_path="${cache}" ;;
    mutable-ref) blocked_path="${cache}/refs/local" ;;
    *) die "unknown publication boundary ${boundary}" ;;
  esac

  chmod u-w "${blocked_path}"
  set +e
  SPOREVM_ROOTFS_CACHE_DIR="${cache}" \
  SPOREVM_RUNTIME_DIR="${runtime}" \
    "${spore_bin}" --debug build --network none --no-cache -t "${old_ref}" "${build_context}" \
      >"${workdir}/failure-${boundary}.stdout" 2>"${workdir}/failure-${boundary}.stderr"
  status=$?
  set -e
  chmod u+w "${blocked_path}"

  if [[ "${status}" -ne 2 ]]; then
    cat "${workdir}/failure-${boundary}.stdout" >&2 || true
    cat "${workdir}/failure-${boundary}.stderr" >&2 || true
    die "${boundary} publication failure exited ${status}, expected 2"
  fi
  after_failure="$(SPOREVM_ROOTFS_CACHE_DIR="${cache}" "${spore_bin}" rootfs resolve "${old_ref}")"
  [[ "${after_failure}" == "${old_resolved}" ]] || die "${boundary} failure replaced the destination ref"
  after_objects="$(count_files "${cache}/cas/rootfs/blake3/objects")"
  after_indexes="$(count_files "${cache}/cas/rootfs/blake3/indexes")"
  after_complete="$(count_files "${cache}/cas/rootfs/blake3/complete")"
  after_steps="$(count_files "${cache}/build/steps")"
  after_metadata="$(count_root_json "${cache}")"
  after_refs="$(count_files "${cache}/refs/local")"
  case "${boundary}" in
    object)
      [[ "${after_objects}" == "${before_objects}" ]] || die "object failure published a CAS object"
      ;;
    index)
      [[ "${after_objects}" -gt "${before_objects}" && "${after_indexes}" == "${before_indexes}" ]] || \
        die "index failure did not stop between object and index publication"
      ;;
    completeness)
      [[ "${after_indexes}" -gt "${before_indexes}" && "${after_complete}" == "${before_complete}" ]] || \
        die "completeness failure did not stop after index publication"
      ;;
    prepare-record)
      [[ "${after_complete}" -gt "${before_complete}" && "${after_steps}" == "${before_steps}" ]] || \
        die "PREPARE record failure did not stop after completeness"
      ;;
    image-metadata)
      [[ "${after_steps}" -gt "${before_steps}" && "${after_metadata}" == "${before_metadata}" ]] || \
        die "image metadata failure did not stop after step publication"
      ;;
    mutable-ref)
      [[ "${after_metadata}" -gt "${before_metadata}" && "${after_refs}" == "${before_refs}" ]] || \
        die "mutable ref failure did not stop after image metadata publication"
      ;;
  esac
  if find "${cache}" -type f -name '*.tmp' -print -quit | grep -q .; then
    die "${boundary} failure left an atomic-publication temporary file"
  fi

  SPOREVM_ROOTFS_CACHE_DIR="${cache}" \
    "${spore_bin}" --json cache gc --rootfs --force >"${workdir}/failure-${boundary}-gc.json"
  SPOREVM_ROOTFS_CACHE_DIR="${cache}" \
  SPOREVM_RUNTIME_DIR="${workdir}/recovery-${boundary}-runtime" \
    "${spore_bin}" build --network none -t "${old_ref}" "${build_context}" \
      >"${workdir}/recovery-${boundary}.stdout" 2>"${workdir}/recovery-${boundary}.stderr" || {
        cat "${workdir}/recovery-${boundary}.stdout" >&2 || true
        cat "${workdir}/recovery-${boundary}.stderr" >&2 || true
        die "${boundary} recovery build failed"
      }
  recovered="$(SPOREVM_ROOTFS_CACHE_DIR="${cache}" "${spore_bin}" rootfs resolve "${old_ref}")"
  [[ "${recovered}" != "${old_resolved}" ]] || die "${boundary} recovery did not publish the new destination"
  SPOREVM_ROOTFS_CACHE_DIR="${cache}" \
    "${spore_bin}" run --backend "${backend}" --memory "${smoke_memory}" \
      --image "${old_ref}" --pull=never -- /bin/sh -lc \
      'grep -Fxq publication-ok /publication-marker'
done

echo "smoke:build-publication ok backend=${backend} image=${image_ref} index=${concurrent_a_index}"
