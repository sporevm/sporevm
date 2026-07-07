#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-env.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

expect_env() {
  local stdout_path="$1"
  local stderr_path="$2"
  grep -Fxq "SPORE_TEST_ENV=ok" "${stdout_path}" || {
    cat "${stdout_path}" >&2 || true
    cat "${stderr_path}" >&2 || true
    die "guest environment did not contain SPORE_TEST_ENV=ok"
  }
}

"${spore_bin}" run --backend "${backend}" --env SPORE_TEST_ENV=ok -- /usr/bin/env \
  >"${workdir}/literal.stdout" 2>"${workdir}/literal.stderr"
expect_env "${workdir}/literal.stdout" "${workdir}/literal.stderr"

SPORE_TEST_ENV=ok "${spore_bin}" run --backend "${backend}" --env SPORE_TEST_ENV -- /usr/bin/env \
  >"${workdir}/copy.stdout" 2>"${workdir}/copy.stderr"
expect_env "${workdir}/copy.stdout" "${workdir}/copy.stderr"

"${spore_bin}" run --backend "${backend}" --save "${workdir}/base.spore" -- /bin/true \
  >"${workdir}/save.stdout" 2>"${workdir}/save.stderr"
"${spore_bin}" run --backend "${backend}" --from "${workdir}/base.spore" --env SPORE_TEST_ENV=ok -- /usr/bin/env \
  >"${workdir}/from.stdout" 2>"${workdir}/from.stderr"
expect_env "${workdir}/from.stdout" "${workdir}/from.stderr"

missing_key="SPORE_TEST_ENV_MISSING_${RANDOM}_${RANDOM}"
if "${spore_bin}" run --env "${missing_key}" -- /bin/true >"${workdir}/missing.stdout" 2>"${workdir}/missing.stderr"; then
  die "spore run accepted --env for a missing host variable"
fi
grep -Fq "not set in the host environment" "${workdir}/missing.stderr" || {
  cat "${workdir}/missing.stderr" >&2 || true
  die "missing host env failure did not explain the problem"
}

if "${spore_bin}" run --env "1BAD=value" -- /bin/true >"${workdir}/bad-key.stdout" 2>"${workdir}/bad-key.stderr"; then
  die "spore run accepted an invalid --env key"
fi
grep -Fq "invalid --env" "${workdir}/bad-key.stderr" || {
  cat "${workdir}/bad-key.stderr" >&2 || true
  die "invalid key failure did not mention --env"
}

echo "smoke:run-env ok backend=${backend}"
