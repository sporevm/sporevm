#!/usr/bin/env bash
# Runs a fixed list of aarch64 smoke scripts against zig-out/bin/spore (or
# SPORE_BIN) and prints one result line per script. Each script's output goes
# to zig-cache/smoke/<script>.log; failing scripts also copy their work logs to
# zig-cache/smoke/<script>/. `mise run smoke core|full` builds first.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The per-commit gate: one-shot run, signal save, fork, named lifecycle, copy,
# the monitor jail, and networking.
core=(
  run/basic.sh
  run/capture.sh
  fanout/counter.sh
  lifecycle/basic.sh
  lifecycle/copy.sh
  monitor/jail.sh
  network/deny.sh
  network/forward.sh
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
  fanout/named-disk-fork.sh
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

case "${1:-}" in
  core) scripts=("${core[@]}") ;;
  full) scripts=("${full[@]}") ;;
  *)
    echo "usage: test/smoke/suite.sh core|full" >&2
    exit 2
    ;;
esac
suite="$1"

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
  args="${entry#"${script}"}"
  name="${script%.sh}"
  log="${log_root}/${name//\//-}.log"
  start="${SECONDS}"
  # shellcheck disable=SC2086 # args holds fixed, space-separated flags.
  if SPORE_SMOKE_LOG_DIR="${log_root}/${name//\//-}" "${repo_root}/test/smoke/${script}" ${args} </dev/null >"${log}" 2>&1; then
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
