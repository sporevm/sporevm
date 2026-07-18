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
  for name in "${restored_name}" "${child_name}" "${source_name}"; do
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
DOCKERFILE

"${spore_bin}" build \
  --tag "${image_ref}" \
  --memory "${SPORE_SMOKE_BUILD_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_BUILD_TIMEOUT:-120s}" \
  "${workdir}/context"

"${spore_bin}" create "${source_name}" \
  --backend "${backend}" \
  --image "${image_ref}" \
  --pull never \
  --memory "${SPORE_SMOKE_MEMORY:-512mb}" \
  --timeout "${SPORE_SMOKE_LIFECYCLE_TIMEOUT:-60s}" \
  -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD" > detached-context'

detached_context=""
for _ in $(seq 1 100); do
  if detached_context="$("${spore_bin}" exec "${source_name}" -- /bin/cat detached-context 2>/dev/null)" && \
    [[ "${detached_context}" == 'default|inherited|/workspace' ]]; then
    break
  fi
  sleep 0.05
done
expect_eq 'default|inherited|/workspace' "${detached_context}" "detached create context"

expect_eq 'default|inherited|/workspace' \
  "$("${spore_bin}" exec "${source_name}" -- /bin/sh -lc 'printf "%s|%s|%s" "$IMAGE_VALUE" "$CLEAR_ME" "$PWD"')" \
  "plain named exec defaults"

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
