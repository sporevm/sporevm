#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-run-oci-rootfs.sh [options] [-- <argv...>]

Build a small linux/arm64 OCI image into an ext4 rootfs, verify the metadata
records a digest-pinned resolved image ref, then run an explicit argv from the
rootfs through `spore run --rootfs`.

Options:
  --image REF        OCI image ref to build (default: docker.io/library/alpine:3.20)
  --platform VALUE   OCI platform to select (default: linux/arm64)
  --workdir DIR      Work directory for smoke artifacts (default: mktemp)
  --output PATH      Rootfs ext4 output path (default: <workdir>/rootfs.ext4)
  --metadata PATH    Metadata output path (default: <output>.json)
  --spore-bin PATH   Prebuilt spore CLI (default: zig-out/bin/spore)
  --no-build         Do not run `zig build`
  -h, --help         Show this help

Example:
  scripts/smoke-run-oci-rootfs.sh -- /bin/echo hi
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

shell_join() {
  local arg
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${repo_root}/mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-${repo_root}/mise.toml}"
fi

image_ref="docker.io/library/alpine:3.20"
platform="linux/arm64"
workdir=""
output_path=""
metadata_path=""
spore_bin=""
build=1
run_argv=()

while (($#)); do
  case "$1" in
    --image)
      need_value "$1" "${2-}"
      image_ref="$2"
      shift 2
      ;;
    --platform)
      need_value "$1" "${2-}"
      platform="$2"
      shift 2
      ;;
    --workdir)
      need_value "$1" "${2-}"
      workdir="$2"
      shift 2
      ;;
    --output)
      need_value "$1" "${2-}"
      output_path="$2"
      shift 2
      ;;
    --metadata)
      need_value "$1" "${2-}"
      metadata_path="$2"
      shift 2
      ;;
    --spore-bin)
      need_value "$1" "${2-}"
      spore_bin="$2"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      run_argv=("$@")
      break
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if ((${#run_argv[@]} == 0)); then
  run_argv=(/bin/echo hi)
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-oci-rootfs-smoke.XXXXXX")"
else
  mkdir -p "${workdir}"
fi

if [[ -z "${output_path}" ]]; then
  output_path="${workdir}/rootfs.ext4"
fi
if [[ -z "${metadata_path}" ]]; then
  metadata_path="${output_path}.json"
fi
if [[ -z "${spore_bin}" ]]; then
  spore_bin="${repo_root}/zig-out/bin/spore"
fi

if [[ "${build}" == "1" ]]; then
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build)
  else
    (cd "${repo_root}" && zig build)
  fi
fi
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"

printf 'workdir: %s\n' "${workdir}"
printf 'building rootfs from %s for %s\n' "${image_ref}" "${platform}"
"${spore_bin}" rootfs build "${image_ref}" \
  --platform "${platform}" \
  --output "${output_path}" \
  --metadata "${metadata_path}"
[[ -f "${output_path}" ]] || die "rootfs build did not create ${output_path}"
[[ -f "${metadata_path}" ]] || die "rootfs build did not create ${metadata_path}"

resolved_image_ref="$(
  python3 - "${metadata_path}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    metadata = json.load(f)

resolved = metadata.get("resolved_image_ref")
if not isinstance(resolved, str) or "@sha256:" not in resolved:
    raise SystemExit(f"metadata missing digest-pinned resolved_image_ref: {resolved!r}")

print(resolved)
PY
)"

printf 'metadata: %s\n' "${metadata_path}"
printf 'resolved_image_ref: %s\n' "${resolved_image_ref}"
printf 'running:'
shell_join "${spore_bin}" run --rootfs "${output_path}" -- "${run_argv[@]}"
printf '\n'
"${spore_bin}" run --rootfs "${output_path}" -- "${run_argv[@]}"
