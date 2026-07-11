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

rootfs_field() {
  local manifest="$1"
  local field="$2"
  python3 - "${manifest}" "${field}" <<'PY'
import json
import sys

manifest, field = sys.argv[1:]
with open(manifest, encoding="utf-8") as handle:
    rootfs = json.load(handle).get("rootfs")
if not isinstance(rootfs, dict) or not isinstance(rootfs.get("storage"), dict):
    raise SystemExit(f"{manifest}: missing chunked rootfs storage")
value = rootfs["storage"].get(field)
if not isinstance(value, (str, int)) or isinstance(value, bool):
    raise SystemExit(f"{manifest}: missing rootfs.storage.{field}")
print(value)
PY
}

assert_manifest_rootfs() {
  local manifest="$1"
  local expected_index="$2"
  local expected_size="$3"
  local actual_index actual_size
  actual_index="$(rootfs_field "${manifest}" index_digest)"
  actual_size="$(rootfs_field "${manifest}" logical_size)"
  [[ "${actual_index}" == "${expected_index}" ]] || {
    die "${manifest} rootfs index ${actual_index} != ${expected_index}"
  }
  [[ "${actual_size}" == "${expected_size}" ]] || {
    die "${manifest} rootfs size ${actual_size} != ${expected_size}"
  }
}

check_materialized_ext4() {
  local cache_root="$1"
  local index_digest="$2"
  local e2fsck_bin="${E2FSCK:-}"
  if [[ -z "${e2fsck_bin}" ]]; then
    e2fsck_bin="$(command -v e2fsck || true)"
  fi
  if [[ -z "${e2fsck_bin}" ]]; then
    if [[ "${SPORE_SMOKE_REQUIRE_E2FSCK:-0}" == "1" ]]; then
      die "e2fsck is required but unavailable"
    fi
    echo "note: e2fsck unavailable; skipping host fsck for ${index_digest}" >&2
    return
  fi
  local image="${cache_root}/by-digest/blake3/${index_digest#blake3:}.ext4"
  [[ -f "${image}" ]] || die "unpack did not materialize ${image}"
  "${e2fsck_bin}" -fn "${image}" >"${workdir}/e2fsck.stdout" 2>"${workdir}/e2fsck.stderr" || {
    cat "${workdir}/e2fsck.stdout" >&2 || true
    cat "${workdir}/e2fsck.stderr" >&2 || true
    die "e2fsck rejected prepared build output ${index_digest}"
  }
}

build_image() {
  local context="$1"
  local tag="$2"
  local stdout="$3"
  local stderr="$4"
  "${spore_bin}" --debug build --network none -t "${tag}" "${context}" \
    >"${stdout}" 2>"${stderr}" || {
      cat "${stdout}" >&2 || true
      cat "${stderr}" >&2 || true
      die "build of ${tag} failed"
    }
  awk '/^  Rootfs index: / { print $3 }' "${stdout}" | tail -1
}

assert_no_resize() {
  local stdout="$1"
  local stderr="$2"
  if grep -Fq 'rootfs preparation metrics:' "${stdout}" "${stderr}" ||
    grep -Fq 'rootfs growth blk metrics:' "${stdout}" "${stderr}"; then
    cat "${stdout}" >&2 || true
    cat "${stderr}" >&2 || true
    die "an already-capable build base was resized"
  fi
}

backend="$(infer_backend)"
image_ref="${SPORE_SMOKE_IMAGE:-docker.io/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d}"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"
capacity_16=$((16 * 1024 * 1024 * 1024))
capacity_20=$((20 * 1024 * 1024 * 1024))
sectors_16=$((capacity_16 / 512))
sectors_20=$((capacity_20 / 512))
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-build-capacity.XXXXXX")"
cleanup() {
  if [[ "${SPORE_SMOKE_KEEP_WORKDIR:-0}" == "1" ]]; then
    echo "retained smoke workdir: ${workdir}" >&2
  else
    rm -rf "${workdir}"
  fi
}
trap cleanup EXIT

primary_cache="${workdir}/rootfs-cache"
runtime_dir="${workdir}/runtime"
unpack_cache="${workdir}/unpack-rootfs-cache"
pull_cache="${workdir}/pull-rootfs-cache"
bundle_cache="${workdir}/bundle-cache"
mkdir -p "${primary_cache}" "${unpack_cache}" "${pull_cache}" "${bundle_cache}"
export SPOREVM_ROOTFS_CACHE_DIR="${primary_cache}"
export SPOREVM_RUNTIME_DIR="${runtime_dir}"

base_ref="local/build-capacity-smoke:compact"
built_ref="local/build-capacity-smoke:built"
committed_ref="local/build-capacity-smoke:committed"
rebuilt_ref="local/build-capacity-smoke:rebuilt"
above_ref="local/build-capacity-smoke:above-cap"
above_built_ref="local/build-capacity-smoke:above-cap-built"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --commit "${base_ref}" \
  -- /bin/true

build_context="${workdir}/build-context"
mkdir -p "${build_context}"
cat >"${build_context}/Dockerfile" <<EOF
FROM ${base_ref}
RUN test "\$(df -k / | awk 'NR == 2 { print \$2 }')" -gt 15000000 && printf 'prepared-build\n' >/prepared-build-marker
EOF

built_index="$(build_image \
  "${build_context}" \
  "${built_ref}" \
  "${workdir}/build.stdout" \
  "${workdir}/build.stderr")"
[[ "${built_index}" == blake3:* ]] || die "build did not report a rootfs index"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${built_ref}" \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq prepared-build /prepared-build-marker && test "$(df -k / | awk "NR == 2 { print \$2 }")" -gt 15000000'

capture_dir="${workdir}/built.spore"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${built_ref}" \
  --pull=never \
  --save "${capture_dir}" \
  -- /bin/sh -lc 'grep -Fxq prepared-build /prepared-build-marker'
assert_manifest_rootfs "${capture_dir}/manifest.json" "${built_index}" "${capacity_16}"

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${capture_dir}" \
  -- /bin/sh -lc "grep -Fxq prepared-build /prepared-build-marker && test \"\$(cat /sys/class/block/vda/size)\" -eq ${sectors_16} && test \"\$(df -k / | awk 'NR == 2 { print \$2 }')\" -gt 15000000"

bundle_dir="${workdir}/built.bundle"
unpacked_dir="${workdir}/unpacked.spore"
pulled_dir="${workdir}/pulled.spore"
"${spore_bin}" --json pack "${capture_dir}" --out "${bundle_dir}" >"${workdir}/pack.json"

SPOREVM_ROOTFS_CACHE_DIR="${unpack_cache}" \
  "${spore_bin}" --json unpack "${bundle_dir}" --out "${unpacked_dir}" >"${workdir}/unpack.json"
assert_manifest_rootfs "${unpacked_dir}/manifest.json" "${built_index}" "${capacity_16}"
check_materialized_ext4 "${unpack_cache}" "${built_index}"
SPOREVM_ROOTFS_CACHE_DIR="${unpack_cache}" \
  "${spore_bin}" run --backend "${backend}" --from "${unpacked_dir}" -- \
    /bin/sh -lc "grep -Fxq prepared-build /prepared-build-marker && test \"\$(cat /sys/class/block/vda/size)\" -eq ${sectors_16} && test \"\$(df -k / | awk 'NR == 2 { print \$2 }')\" -gt 15000000"

SPOREVM_ROOTFS_CACHE_DIR="${pull_cache}" \
  SPOREVM_BUNDLE_CACHE_DIR="${bundle_cache}" \
  "${spore_bin}" --json pull "file://${bundle_dir}" --out "${pulled_dir}" >"${workdir}/pull.json"
assert_manifest_rootfs "${pulled_dir}/manifest.json" "${built_index}" "${capacity_16}"
SPOREVM_ROOTFS_CACHE_DIR="${pull_cache}" \
  "${spore_bin}" run --backend "${backend}" --from "${pulled_dir}" -- \
    /bin/sh -lc "grep -Fxq prepared-build /prepared-build-marker && test \"\$(cat /sys/class/block/vda/size)\" -eq ${sectors_16} && test \"\$(df -k / | awk 'NR == 2 { print \$2 }')\" -gt 15000000"

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${built_ref}" \
  --pull=never \
  --commit "${committed_ref}" \
  -- /bin/sh -lc 'printf "committed-build\n" >/committed-build-marker'

committed_context="${workdir}/committed-context"
mkdir -p "${committed_context}"
cat >"${committed_context}/Dockerfile" <<EOF
FROM ${committed_ref}
RUN grep -Fxq committed-build /committed-build-marker && printf 'rebuilt\n' >/rebuilt-marker
EOF
rebuilt_index="$(build_image \
  "${committed_context}" \
  "${rebuilt_ref}" \
  "${workdir}/rebuilt.stdout" \
  "${workdir}/rebuilt.stderr")"
[[ "${rebuilt_index}" == blake3:* ]] || die "build from committed image did not report a rootfs index"
assert_no_resize "${workdir}/rebuilt.stdout" "${workdir}/rebuilt.stderr"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${rebuilt_ref}" \
  --pull=never \
  -- /bin/sh -lc 'grep -Fxq rebuilt /rebuilt-marker'

"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${built_ref}" \
  --pull=never \
  --disk-size 20gb \
  --commit "${above_ref}" \
  -- /bin/sh -lc 'printf "above-cap\n" >/above-cap-marker'

above_context="${workdir}/above-context"
mkdir -p "${above_context}"
cat >"${above_context}/Dockerfile" <<EOF
FROM ${above_ref}
RUN grep -Fxq above-cap /above-cap-marker && printf 'above-cap-built\n' >/above-cap-built-marker
EOF
above_built_index="$(build_image \
  "${above_context}" \
  "${above_built_ref}" \
  "${workdir}/above-built.stdout" \
  "${workdir}/above-built.stderr")"
[[ "${above_built_index}" == blake3:* ]] || die "above-cap build did not report a rootfs index"
assert_no_resize "${workdir}/above-built.stdout" "${workdir}/above-built.stderr"

above_capture="${workdir}/above-cap.spore"
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${above_built_ref}" \
  --pull=never \
  --save "${above_capture}" \
  -- /bin/sh -lc 'grep -Fxq above-cap-built /above-cap-built-marker'
assert_manifest_rootfs "${above_capture}/manifest.json" "${above_built_index}" "${capacity_20}"
"${spore_bin}" run \
  --backend "${backend}" \
  --from "${above_capture}" \
  -- /bin/sh -lc "grep -Fxq above-cap-built /above-cap-built-marker && test \"\$(cat /sys/class/block/vda/size)\" -eq ${sectors_20} && test \"\$(df -k / | awk 'NR == 2 { print \$2 }')\" -gt 19000000"

echo "smoke:build-rootfs-capacity ok backend=${backend} image=${image_ref} index=${built_index}"
