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

disk_layer_count() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    manifest = json.load(f)
disk = manifest.get("disk") or {}
print(len(disk.get("layers") or []))
PY
}

backend="$(infer_backend)"
case "${backend}" in
  hvf|kvm) ;;
  *) die "SPORE_BACKEND must be hvf or kvm" ;;
esac
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

image_ref="${SPORE_SMOKE_WRITABLE_ROOTFS_IMAGE:-docker.io/library/alpine:3.20}"
platform="${SPORE_SMOKE_WRITABLE_ROOTFS_PLATFORM:-linux/arm64}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-writable-rootfs.XXXXXX")"
cleanup() {
  if [[ -z "${SPORE_KEEP_SMOKE_WORKDIR:-}" ]]; then
    rm -rf "${workdir}"
  else
    echo "kept smoke workdir: ${workdir}" >&2
  fi
}
trap cleanup EXIT

base_dir="${workdir}/base.spore"
child_dir="${workdir}/child.spore"
fork_dir="${workdir}/forks"
fork_child0_capture_dir="${workdir}/fork-child0-capture.spore"
bundle_dir="${workdir}/child.bundle"
unpacked_dir="${workdir}/child-unpacked.spore"
base_stdout="${workdir}/base.stdout"
base_stderr="${workdir}/base.stderr"
child_stdout="${workdir}/child.stdout"
child_stderr="${workdir}/child.stderr"
fork_child0_stdout="${workdir}/fork-child0.stdout"
fork_child0_stderr="${workdir}/fork-child0.stderr"
fork_child0_verify_stdout="${workdir}/fork-child0-verify.stdout"
fork_child0_verify_stderr="${workdir}/fork-child0-verify.stderr"
verify_stdout="${workdir}/verify.stdout"
verify_stderr="${workdir}/verify.stderr"
unpacked_verify_stdout="${workdir}/unpacked-verify.stdout"
unpacked_verify_stderr="${workdir}/unpacked-verify.stderr"

if [[ "${image_ref}" == *@sha256:* ]]; then
  resolved_image_ref="${image_ref}"
else
  resolved_image_ref="$("${spore_bin}" rootfs resolve "${image_ref}" --platform "${platform}")"
fi
printf 'writable rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --capture "${base_dir}" \
  -- /bin/sh -lc 'printf "parent-layer-ok\n" >/var/sporevm-parent && sync' \
  >"${base_stdout}" 2>"${base_stderr}" || {
  cat "${base_stdout}" >&2 || true
  cat "${base_stderr}" >&2 || true
  die "base writable rootfs capture failed"
}

[[ -f "${base_dir}/manifest.json" ]] || die "base capture did not write manifest"
[[ "$(disk_layer_count "${base_dir}/manifest.json")" == "1" ]] || {
  cat "${base_dir}/manifest.json" >&2 || true
  die "base capture did not record one writable disk layer"
}

"${spore_bin}" fork "${base_dir}" --count 4 --out "${fork_dir}" >"${workdir}/fork.json" || {
  cat "${workdir}/fork.json" >&2 || true
  die "writable rootfs fork failed"
}

for child_name in 000000 000001 000002 000003; do
  child_manifest="${fork_dir}/${child_name}/manifest.json"
  [[ -f "${child_manifest}" ]] || die "fork child ${child_name} did not write manifest"
  [[ "$(disk_layer_count "${child_manifest}")" == "1" ]] || {
    cat "${child_manifest}" >&2 || true
    die "fork child ${child_name} did not preserve parent disk layer"
  }
done

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${fork_dir}/000000" \
  --capture "${fork_child0_capture_dir}" \
  -- /bin/sh -lc 'test "$(cat /var/sporevm-parent)" = "parent-layer-ok" && printf "fork-child0-layer-ok\n" >/var/sporevm-fork-child && sync' \
  >"${fork_child0_stdout}" 2>"${fork_child0_stderr}" || {
  cat "${fork_child0_stdout}" >&2 || true
  cat "${fork_child0_stderr}" >&2 || true
  die "fork child 000000 writable capture failed"
}

[[ "$(disk_layer_count "${fork_child0_capture_dir}/manifest.json")" == "2" ]] || {
  cat "${fork_child0_capture_dir}/manifest.json" >&2 || true
  die "fork child 000000 capture did not append its own disk layer"
}

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${fork_child0_capture_dir}" \
  -- /bin/sh -lc 'cat /var/sporevm-parent /var/sporevm-fork-child' \
  >"${fork_child0_verify_stdout}" 2>"${fork_child0_verify_stderr}" || {
  cat "${fork_child0_verify_stdout}" >&2 || true
  cat "${fork_child0_verify_stderr}" >&2 || true
  die "fork child 000000 verification run failed"
}

grep -Fxq "parent-layer-ok" "${fork_child0_verify_stdout}" || {
  cat "${fork_child0_verify_stdout}" >&2 || true
  cat "${fork_child0_verify_stderr}" >&2 || true
  die "fork child 000000 did not see parent layer contents"
}
grep -Fxq "fork-child0-layer-ok" "${fork_child0_verify_stdout}" || {
  cat "${fork_child0_verify_stdout}" >&2 || true
  cat "${fork_child0_verify_stderr}" >&2 || true
  die "fork child 000000 did not see its own layer contents"
}

for child_name in 000001 000002 000003; do
  sibling_stdout="${workdir}/fork-${child_name}.stdout"
  sibling_stderr="${workdir}/fork-${child_name}.stderr"
  "${spore_bin}" run \
    --backend "${backend}" \
    --from "${fork_dir}/${child_name}" \
    -- /bin/sh -lc 'test "$(cat /var/sporevm-parent)" = "parent-layer-ok" && test ! -e /var/sporevm-fork-child && printf "fork-sibling-clean\n"' \
    >"${sibling_stdout}" 2>"${sibling_stderr}" || {
    cat "${sibling_stdout}" >&2 || true
    cat "${sibling_stderr}" >&2 || true
    die "fork child ${child_name} divergence verification failed"
  }

  grep -Fxq "fork-sibling-clean" "${sibling_stdout}" || {
    cat "${sibling_stdout}" >&2 || true
    cat "${sibling_stderr}" >&2 || true
    die "fork child ${child_name} did not prove sibling divergence"
  }
done

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${base_dir}" \
  --capture "${child_dir}" \
  -- /bin/sh -lc 'test "$(cat /var/sporevm-parent)" = "parent-layer-ok" && printf "child-layer-ok\n" >/var/sporevm-child && sync' \
  >"${child_stdout}" 2>"${child_stderr}" || {
  cat "${child_stdout}" >&2 || true
  cat "${child_stderr}" >&2 || true
  die "child writable rootfs capture failed"
}

[[ -f "${child_dir}/manifest.json" ]] || die "child capture did not write manifest"
[[ "$(disk_layer_count "${child_dir}/manifest.json")" == "2" ]] || {
  cat "${child_dir}/manifest.json" >&2 || true
  die "child capture did not append a second writable disk layer"
}

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${child_dir}" \
  -- /bin/sh -lc 'cat /var/sporevm-parent /var/sporevm-child' \
  >"${verify_stdout}" 2>"${verify_stderr}" || {
  cat "${verify_stdout}" >&2 || true
  cat "${verify_stderr}" >&2 || true
  die "writable rootfs verification run failed"
}

grep -Fxq "parent-layer-ok" "${verify_stdout}" || {
  cat "${verify_stdout}" >&2 || true
  cat "${verify_stderr}" >&2 || true
  die "verification run did not see parent layer contents"
}
grep -Fxq "child-layer-ok" "${verify_stdout}" || {
  cat "${verify_stdout}" >&2 || true
  cat "${verify_stderr}" >&2 || true
  die "verification run did not see child layer contents"
}

"${spore_bin}" pack "${child_dir}" --out "${bundle_dir}" >"${workdir}/pack.json" || {
  cat "${workdir}/pack.json" >&2 || true
  die "writable rootfs bundle pack failed"
}

"${spore_bin}" unpack "${bundle_dir}" --out "${unpacked_dir}" >"${workdir}/unpack.json" || {
  cat "${workdir}/unpack.json" >&2 || true
  die "writable rootfs bundle unpack failed"
}

[[ -f "${unpacked_dir}/manifest.json" ]] || die "unpacked writable rootfs bundle did not write manifest"
[[ "$(disk_layer_count "${unpacked_dir}/manifest.json")" == "2" ]] || {
  cat "${unpacked_dir}/manifest.json" >&2 || true
  die "unpacked writable rootfs bundle did not preserve two disk layers"
}

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${unpacked_dir}" \
  -- /bin/sh -lc 'cat /var/sporevm-parent /var/sporevm-child' \
  >"${unpacked_verify_stdout}" 2>"${unpacked_verify_stderr}" || {
  cat "${unpacked_verify_stdout}" >&2 || true
  cat "${unpacked_verify_stderr}" >&2 || true
  die "unpacked writable rootfs verification run failed"
}

grep -Fxq "parent-layer-ok" "${unpacked_verify_stdout}" || {
  cat "${unpacked_verify_stdout}" >&2 || true
  cat "${unpacked_verify_stderr}" >&2 || true
  die "unpacked verification run did not see parent layer contents"
}
grep -Fxq "child-layer-ok" "${unpacked_verify_stdout}" || {
  cat "${unpacked_verify_stdout}" >&2 || true
  cat "${unpacked_verify_stderr}" >&2 || true
  die "unpacked verification run did not see child layer contents"
}

echo "smoke:writable-rootfs ok backend=${backend} image=${resolved_image_ref}"
