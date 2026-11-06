#!/usr/bin/env bash
# Runs a smoke suite (core or full, aarch64) or one script under test/smoke
# (for example run/attach or x86/run, with any further arguments passed to it)
# against zig-out/bin/spore (or SPORE_BIN), and prints one result line per
# script. Each script's output goes to zig-cache/smoke/<script>.log; failing
# scripts also copy their work logs to zig-cache/smoke/<script>/. With --build,
# as `mise run smoke` passes, it builds first with the shipped ReleaseSafe
# settings and -Dsmoke-helpers, which puts the helper binaries the scripts run
# in the guest initrd, plus the board smoke binary for x86/ scripts.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The per-commit gate: one-shot run, signal save, fork, named disk forks with
# save, restore, prune and GC, named lifecycle, copy, the monitor jail,
# networking, and lazy runs from an image store.
core=(
  run/basic.sh
  run/capture.sh
  fanout/counter.sh
  fanout/named-disk-fork.sh
  lifecycle/basic.sh
  lifecycle/copy.sh
  monitor/jail.sh
  network/deny.sh
  network/forward.sh
  rootfs/remote-lazy.sh
)

full=(
  "${core[@]}"
  run/attach.sh
  run/auto-memory.sh
  run/cgroup.sh
  run/disk-size.sh
  run/env.sh
  run/file-locking.sh
  run/image-commit.sh
  run/inject.sh
  run/stdin.sh
  run/tty.sh
  fanout/live-rootfs.sh
  fanout/local-pull.sh
  fanout/multi-vcpu.sh
  fanout/rootfs.sh
  lifecycle/auto-memory.sh
  lifecycle/image-context.sh
  lifecycle/tty.sh
  monitor/failure-modes.sh
  network/bind-service.sh
  network/bind-service-oci.sh
  network/capture.sh
  network/config.sh
  network/dns.sh
  network/egress.sh
  network/http.sh
  "rootfs/oci-run.sh --no-build"
  rootfs/writable.sh
  rootfs/build-capacity.sh
  rootfs/build-publication.sh
)

usage() {
  echo "usage: test/smoke/suite.sh [--build] core|full|<script> [args...]" >&2
  echo "  <script> is a path under test/smoke without .sh, such as run/attach or x86/run" >&2
  exit 2
}

build=0
if [[ "${1:-}" == "--build" ]]; then
  build=1
  shift
fi
suite="${1:-}"
[[ -n "${suite}" ]] || usage
shift
script_args=("$@")
case "${suite}" in
  core) scripts=("${core[@]}") ;;
  full) scripts=("${full[@]}") ;;
  *)
    suite="${suite%.sh}"
    case "${suite}" in
      lib | suite | /* | ../* | */../*) usage ;;
    esac
    [[ -f "${repo_root}/test/smoke/${suite}.sh" ]] || usage
    scripts=("${suite}.sh")
    ;;
esac
if ((${#script_args[@]})) && [[ "${suite}" == core || "${suite}" == full ]]; then
  usage
fi

if ((build)); then
  if [[ "${suite}" == x86/* ]]; then
    (cd "${repo_root}" && zig build install x86-board-smoke --release=safe -Dsmoke-helpers)
  else
    (cd "${repo_root}" && zig build --release=safe -Dsmoke-helpers)
  fi
fi
require_spore_bin

duration() {
  local seconds="$1"
  if ((seconds >= 60)); then
    printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%ds' "${seconds}"
  fi
}

log_root="${repo_root}/zig-cache/smoke"
rm -rf "${log_root}"
mkdir -p "${log_root}"

echo "smoke ${suite}: $("${spore_bin}" --version) on $(uname -s) $(uname -m)"
passed=0
skipped=0
failed=()
suite_start="${SECONDS}"
for entry in "${scripts[@]}"; do
  script="${entry%% *}"
  # shellcheck disable=SC2206 # suite entries hold fixed, space-separated flags.
  args=(${entry#"${script}"} ${script_args[@]+"${script_args[@]}"})
  name="${script%.sh}"
  log="${log_root}/${name//\//-}.log"
  start="${SECONDS}"
  if SPORE_SMOKE_LOG_DIR="${log_root}/${name//\//-}" "${repo_root}/test/smoke/${script}" ${args[@]+"${args[@]}"} </dev/null >"${log}" 2>&1; then
    status=0
  else
    status=$?
  fi
  elapsed="$(duration "$((SECONDS - start))")"
  if [[ "${status}" != "0" ]]; then
    printf 'FAIL  %-28s %7s  exit %s, log %s\n' "${name}" "${elapsed}" "${status}" "${log#"${repo_root}"/}"
    # The reason first: monitor logs dumped on failure can push it out of the tail.
    grep -m3 '^error:' "${log}" | sed 's/^/      /' || true
    tail -n 80 "${log}" | sed 's/^/      /'
    failed+=("${name}")
  elif tail -n 1 "${log}" | grep -q ' skipped'; then
    printf 'SKIP  %-28s %7s  %s\n' "${name}" "${elapsed}" "$(tail -n 1 "${log}")"
    skipped=$((skipped + 1))
  else
    printf 'PASS  %-28s %7s\n' "${name}" "${elapsed}"
    passed=$((passed + 1))
  fi
done

echo "smoke ${suite}: ${passed} passed, ${skipped} skipped, ${#failed[@]} failed in $(duration "$((SECONDS - suite_start))")"
if ((${#failed[@]})); then
  echo "failed: ${failed[*]}"
  exit 1
fi
