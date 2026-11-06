# Shared helpers for the aarch64 smoke scripts. Source it after
# `set -euo pipefail`:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
#
# A script may define `cleanup` (kill helpers, remove named VMs). The EXIT trap
# runs it, then removes every directory created with smoke_tempdir. On failure
# it first prints VM monitor log tails and, with SPORE_SMOKE_LOG_DIR set, copies
# small text logs there. SPORE_KEEP_SMOKE_WORKDIR=1 skips cleanup and keeps the
# directories.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
smoke_dirs=()

die() {
  echo "error: $*" >&2
  exit 1
}

require_spore_bin() {
  [[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run zig build --release=safe -Dsmoke-helpers"
}

# Prints SPORE_BACKEND, or the backend for this aarch64 host.
infer_backend() {
  local backend="${SPORE_BACKEND:-}"
  if [[ -z "${backend}" ]]; then
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) backend=hvf ;;
      Linux-aarch64|Linux-arm64) backend=kvm ;;
      *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
    esac
  fi
  case "${backend}" in
    hvf|kvm) echo "${backend}" ;;
    *) die "SPORE_BACKEND must be hvf or kvm" ;;
  esac
}

# smoke_tempdir VAR PREFIX creates the directory PREFIX.XXXXXX, stores its path
# in VAR, and removes it on exit. Runtime directories hold Unix sockets, so put
# them under a short root such as /tmp: macOS limits socket paths to 104 bytes.
smoke_tempdir() {
  local dir
  mkdir -p "$(dirname "$2")"
  dir="$(mktemp -d "$2.XXXXXX")"
  smoke_dirs+=("${dir}")
  printf -v "$1" '%s' "${dir}"
}

# Prints the tail of each VM monitor log and, when SPORE_SMOKE_LOG_DIR is set,
# copies small text logs there before cleanup removes them.
smoke_report_failure() {
  local dir dest file
  for dir in "${smoke_dirs[@]}"; do
    find "${dir}" -name '*cache*' -prune -o -type f -name monitor.log -print | while IFS= read -r file; do
      echo "== ${file} ==" >&2
      tail -n 60 "${file}" >&2 || true
    done
    [[ -n "${SPORE_SMOKE_LOG_DIR:-}" ]] || continue
    dest="${SPORE_SMOKE_LOG_DIR}/$(basename "${dir}")"
    (
      cd "${dir}" &&
        find . \( -name '*cache*' -o -name cas \) -prune -o -type f \
          \( -name '*.log' -o -name '*.stdout' -o -name '*.stderr' -o -name '*.out' -o -name '*.err' -o -name '*.json' -o -name '*.jsonl' \) \
          -size -4096k -print
    ) | while IFS= read -r file; do
      mkdir -p "${dest}/$(dirname "${file}")"
      cp "${dir}/${file}" "${dest}/${file}"
    done
  done
}

smoke_exit() {
  local status=$?
  trap - EXIT
  if [[ "${status}" != "0" ]] && ((${#smoke_dirs[@]})); then
    smoke_report_failure || true
  fi
  if [[ -n "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    ((${#smoke_dirs[@]} == 0)) || echo "kept ${smoke_dirs[*]} (cleanup skipped)" >&2
    exit "${status}"
  fi
  if declare -F cleanup >/dev/null; then
    cleanup || true
  fi
  ((${#smoke_dirs[@]} == 0)) || rm -rf "${smoke_dirs[@]}"
  exit "${status}"
}
trap smoke_exit EXIT

# run_capture STDOUT STDERR COMMAND... runs COMMAND with output redirected and
# returns its status without tripping set -e.
run_capture() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2

  set +e
  "$@" >"${stdout_path}" 2>"${stderr_path}"
  local status=$?
  set -e
  return "${status}"
}

require_success() {
  local status="$1"
  local label="$2"
  local stderr_path="$3"
  [[ "${status}" == "0" ]] && return
  cat "${stderr_path}" >&2 || true
  die "${label} exited ${status}, expected 0"
}

expect_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || die "${label}: expected ${expected}, got ${actual}"
}

# jsonl_output_contains FILE EVENT NEEDLE succeeds when a JSONL output event of
# type EVENT (stdout or stderr) carries NEEDLE in its base64 payload.
jsonl_output_contains() {
  python3 - "$1" "$2" "$3" <<'PY'
import base64
import json
import sys

needle = sys.argv[3].encode()
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") != sys.argv[2]:
            continue
        if needle in base64.b64decode(event.get("data_base64", "")):
            sys.exit(0)
sys.exit(1)
PY
}

# with_timeout SECONDS COMMAND... runs COMMAND and kills it with SIGALRM after
# SECONDS. macOS has no coreutils timeout.
with_timeout() {
  python3 -c 'import os, signal, sys; signal.alarm(int(sys.argv[1])); os.execvp(sys.argv[2], sys.argv[2:])' "$@"
}

# fork_children DIR prints the child spores of a `spore fork --out DIR` batch.
# The batch also holds shared stores such as shared-chunks.
fork_children() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9]' | sort
}

# json_field FILE DOTTED.PATH prints one value from a JSON document.
json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    value = json.load(f)
for part in sys.argv[2].split("."):
    value = value[part]
print(str(value).lower() if isinstance(value, bool) else value)
PY
}
