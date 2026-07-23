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
    *) die "cannot infer supported backend for $(uname -s)-$(uname -m); set SPORE_BACKEND=hvf or SPORE_BACKEND=kvm" ;;
  esac
}

expect_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || die "${label}: expected ${expected}, got ${actual}"
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${SPORE_SMOKE_WORK_ROOT:-/tmp}/sporevm-image-context.XXXXXX")"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"
mkdir -p "${SPOREVM_RUNTIME_DIR}" "${SPOREVM_ROOTFS_CACHE_DIR}" "${workdir}/context"
chmod 700 "${SPOREVM_RUNTIME_DIR}"

source_name="image-context-source"
override_name="image-context-override"
failed_name="image-context-failed"
child_name="image-context-child"
restored_name="image-context-restored"
saved_spore="${workdir}/child.spore"
image_ref="local/sporevm-image-context:smoke"

cleanup() {
  local status="$?"
  if [[ "${status}" != "0" || "${SPORE_KEEP_SMOKE_WORKDIR:-0}" == "1" ]]; then
    echo "smoke:lifecycle-image-context kept workdir=${workdir} runtime_dir=${SPOREVM_RUNTIME_DIR}" >&2
    for log in "${SPOREVM_RUNTIME_DIR}"/vms/*/monitor.log; do
      [[ -f "${log}" ]] || continue
      echo "== ${log} ==" >&2
      tail -120 "${log}" >&2 || true
    done
  fi
  for name in "${restored_name}" "${child_name}" "${failed_name}" "${override_name}" "${source_name}"; do
    "${spore_bin}" rm "${name}" >/dev/null 2>&1 || true
  done
  if [[ "${status}" == "0" && "${SPORE_KEEP_SMOKE_WORKDIR:-0}" != "1" ]]; then
    rm -rf "${workdir}"
  fi
  return "${status}"
}
trap cleanup EXIT

cat >"${workdir}/context/Dockerfile" <<'DOCKERFILE'
FROM docker.io/library/alpine:3.20
ENV IMAGE_VALUE=default CLEAR_ME=inherited
WORKDIR /workspace
RUN mkdir -p /workspace/sub /workspace/tools && printf '%b' '#!/bin/sh\nprintf "%s|%s" "\0441" "\0442"\n' > /workspace/tools/exact-tool && chmod 0755 /workspace/tools/exact-tool
CMD ["/bin/sh", "-c", "printf '%s|%s|%s' \"$IMAGE_VALUE\" \"$CLEAR_ME\" \"$PWD\" > default-context; cat default-context"]
DOCKERFILE

"${spore_bin}" build \
  --tag "${image_ref}" \
  --memory "${SPORE_SMOKE_BUILD_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_BUILD_TIMEOUT:-120s}" \
  "${workdir}/context"

expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" run --backend "${backend}" --image "${image_ref}" --pull never --memory "${SPORE_SMOKE_MEMORY:-512mb}" --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}")" \
  "one-shot image command defaults"

expect_eq 'override:default' \
  "$("${spore_bin}" run --backend "${backend}" --image "${image_ref}" --pull never --memory "${SPORE_SMOKE_MEMORY:-512mb}" --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}" -- /bin/sh -lc 'printf "override:%s" "$IMAGE_VALUE"')" \
  "one-shot image command override"

expect_eq 'one-shot exact argv' \
  "$("${spore_bin}" run --backend "${backend}" --image "${image_ref}" --pull never --memory "${SPORE_SMOKE_MEMORY:-512mb}" --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}" -- echo 'one-shot exact argv')" \
  "one-shot image PATH lookup"

"${spore_bin}" create "${source_name}" \
  --backend "${backend}" \
  --image "${image_ref}" \
  --pull never \
  --memory "${SPORE_SMOKE_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}"

default_context=""
for _ in $(seq 1 100); do
  if default_context="$("${spore_bin}" exec "${source_name}" -- /bin/cat default-context 2>/dev/null)" && \
    [[ "${default_context}" == 'default|inherited|/workspace' ]]; then
    break
  fi
  sleep 0.05
done
expect_eq 'default|inherited|/workspace' "${default_context}" "detached image command defaults"
"${spore_bin}" --json logs "${source_name}" | python3 -c '
import json
import sys

initial = json.load(sys.stdin)["initial_command"]
if initial["process_status"] != "exited" or initial["exit_code"] != 0:
    raise SystemExit("successful initial command did not report exit 0")
if initial["stdout"] != "default|inherited|/workspace" or initial["stderr"] != "":
    raise SystemExit("successful initial command output was not retained")
'

"${spore_bin}" create "${override_name}" \
  --backend "${backend}" \
  --image "${image_ref}" \
  --pull never \
  --memory "${SPORE_SMOKE_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}" \
  --initial-output discard \
  -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD" > detached-context'

detached_context=""
for _ in $(seq 1 100); do
  if detached_context="$("${spore_bin}" exec "${override_name}" -- /bin/cat detached-context 2>/dev/null)" && \
    [[ "${detached_context}" == 'default|inherited|/workspace' ]]; then
    break
  fi
  sleep 0.05
done
expect_eq 'default|inherited|/workspace' "${detached_context}" "detached create context"
if "${spore_bin}" logs "${override_name}" >/dev/null 2>&1; then
  die "discarded initial output was unexpectedly retrievable"
fi

if "${spore_bin}" create "${failed_name}" \
  --backend "${backend}" \
  --memory "${SPORE_SMOKE_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}" \
  -- /does-not-exist >/dev/null 2>&1; then
  die "create unexpectedly accepted an unstartable initial command"
fi
[[ ! -e "${SPOREVM_RUNTIME_DIR}/vms/${failed_name}" ]] || die "failed create left a named VM behind"

expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" exec "${source_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "plain named exec defaults"

expect_eq 'two words|$VALUE' \
  "$("${spore_bin}" exec --env PATH=/workspace/tools:/bin "${source_name}" -- exact-tool 'two words' '$VALUE')" \
  "named exec PATH lookup preserves exact argv"

expect_eq 'traversal|contained' \
  "$("${spore_bin}" exec --env PATH=/workspace/sub/../tools:/bin "${source_name}" -- exact-tool traversal contained)" \
  "absolute PATH traversal stays inside the guest root"

expect_eq 'relative entry skipped' \
  "$("${spore_bin}" exec --env PATH=missing:/bin "${source_name}" -- echo 'relative entry skipped')" \
  "missing relative PATH entry falls through"

for path_case in /does-not-exist ""; do
  set +e
  "${spore_bin}" exec --env "PATH=${path_case}" "${source_name}" -- echo should-not-run >"${workdir}/path-failure.stdout" 2>"${workdir}/path-failure.stderr"
  path_rc="$?"
  set -e
  [[ "${path_rc}" == "127" ]] || die "missing or empty PATH exited ${path_rc}, expected 127"
  [[ ! -s "${workdir}/path-failure.stdout" ]] || die "missing or empty PATH executed a command"
done

set +e
"${spore_bin}" exec --env PATH=tools:/bin --workdir /workspace "${source_name}" -- exact-tool should not-run >"${workdir}/relative-path.stdout" 2>"${workdir}/relative-path.stderr"
relative_path_rc="$?"
set -e
[[ "${relative_path_rc}" == "126" ]] || die "relative executable PATH match exited ${relative_path_rc}, expected 126"
[[ ! -s "${workdir}/relative-path.stdout" ]] || die "relative executable PATH match ran the command"

too_many_path="/"
for _ in $(seq 1 64); do
  too_many_path="${too_many_path}:/"
done
set +e
"${spore_bin}" exec --env "PATH=${too_many_path}" "${source_name}" -- missing >"${workdir}/bounded-path.stdout" 2>"${workdir}/bounded-path.stderr"
bounded_path_rc="$?"
set -e
[[ "${bounded_path_rc}" == "126" ]] || die "over-limit PATH entry count exited ${bounded_path_rc}, expected 126"
[[ ! -s "${workdir}/bounded-path.stdout" ]] || die "over-limit PATH entry count ran the command"

long_command="$(printf '%0511d' 0 | tr 0 x)"
set +e
"${spore_bin}" exec --env PATH=/bin "${source_name}" -- "${long_command}" >"${workdir}/bounded-candidate.stdout" 2>"${workdir}/bounded-candidate.stderr"
bounded_candidate_rc="$?"
set -e
[[ "${bounded_candidate_rc}" == "126" ]] || die "over-limit PATH candidate exited ${bounded_candidate_rc}, expected 126"
[[ ! -s "${workdir}/bounded-candidate.stdout" ]] || die "over-limit PATH candidate ran the command"

expect_eq 'override||/' \
  "$("${spore_bin}" exec --env IMAGE_VALUE=override --env CLEAR_ME= --workdir / "${source_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "named exec overrides"

host_context="$(env HOST_CONTEXT=from-host "${spore_bin}" exec --env HOST_CONTEXT "${source_name}" -- /bin/sh -lc 'printf "%s" "$HOST_CONTEXT"')"
expect_eq from-host "${host_context}" "host environment copy"

interactive_context="$(printf 'input-ok\n' | "${spore_bin}" exec --env IMAGE_VALUE=interactive --workdir / -i "${source_name}" -- /bin/sh -lc 'read -r input; printf "%s|%s|%s" "$IMAGE_VALUE" "$PWD" "$input"')"
expect_eq 'interactive|/|input-ok' "${interactive_context}" "interactive named exec context"

tty_context="$("${spore_bin}" exec --env IMAGE_VALUE=tty --workdir /tmp -t "${source_name}" -- /bin/sh -lc 'printf "%s|%s" "$IMAGE_VALUE" "$PWD"')"
expect_eq 'tty|/tmp' "${tty_context}" "TTY named exec context"

"${spore_bin}" exec --env PER_EXEC_SECRET=ephemeral-only "${source_name}" -- /bin/sh -lc 'test "$PER_EXEC_SECRET" = ephemeral-only'
expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" exec "${source_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "defaults after per-exec override"
if grep -Fq 'ephemeral-only' "${SPOREVM_RUNTIME_DIR}/vms/${source_name}/spec.json"; then
  die "per-exec environment value persisted in named runtime metadata"
fi

"${spore_bin}" fork --vm "${source_name}" --count 1 --name "${child_name}"
expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" exec "${child_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "forked named exec defaults"

"${spore_bin}" save "${child_name}" --out "${saved_spore}" --stop
for metadata in "${saved_spore}/sporevm-lifecycle.json" "${saved_spore}/manifest.json"; do
  grep -Fq '"IMAGE_VALUE=default"' "${metadata}" || die "image environment missing from ${metadata}"
  grep -Fq '"CLEAR_ME=inherited"' "${metadata}" || die "clearable image environment missing from ${metadata}"
  grep -Fq '"working_dir": "/workspace"' "${metadata}" || die "image working directory missing from ${metadata}"
  if grep -Fq 'ephemeral-only' "${metadata}"; then
    die "per-exec environment value persisted in ${metadata}"
  fi
done

"${spore_bin}" restore "${saved_spore}" --name "${restored_name}" --backend "${backend}"
expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" exec "${restored_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "restored named exec defaults"

echo "smoke:lifecycle-image-context ok backend=${backend}"
