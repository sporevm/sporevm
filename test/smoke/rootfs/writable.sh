#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# disk_base MANIFEST prints the digest of the saved writable disk index, which
# changes whenever a capture records guest disk writes.
disk_base() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    manifest = json.load(f)
print((manifest.get("disk") or {}).get("base", ""))
PY
}

backend="$(infer_backend)"
require_spore_bin

image_ref="${SPORE_SMOKE_WRITABLE_ROOTFS_IMAGE:-docker.io/library/alpine:3.20}"
platform="${SPORE_SMOKE_WRITABLE_ROOTFS_PLATFORM:-linux/arm64}"

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-writable-rootfs"
# Image-backed saves must share a filesystem with the rootfs cache.
export SPOREVM_ROOTFS_CACHE_DIR="${workdir}/rootfs-cache"

base_dir="${workdir}/base.spore"
child_dir="${workdir}/child.spore"
fork_dir="${workdir}/forks"
fork_child0_capture_dir="${workdir}/fork-child0-capture.spore"
store_dir="${workdir}/store"
pull_cache="${workdir}/pull-rootfs-cache"
pulled_dir="${workdir}/child-pulled.spore"
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
pulled_verify_stdout="${workdir}/pulled-verify.stdout"
pulled_verify_stderr="${workdir}/pulled-verify.stderr"

if [[ "${image_ref}" == *@sha256:* ]]; then
  resolved_image_ref="${image_ref}"
else
  resolved_image_ref="$("${spore_bin}" image resolve "${image_ref}" --platform "${platform}")"
fi
printf 'writable rootfs image: %s -> %s\n' "${image_ref}" "${resolved_image_ref}"

"${spore_bin}" run \
  --backend "${backend}" \
  --image "${resolved_image_ref}" \
  --save "${base_dir}" \
  -- /bin/sh -lc 'printf "parent-layer-ok\n" >/var/sporevm-parent && sync' \
  >"${base_stdout}" 2>"${base_stderr}" || {
  cat "${base_stdout}" >&2 || true
  cat "${base_stderr}" >&2 || true
  die "base writable rootfs capture failed"
}

[[ -f "${base_dir}/manifest.json" ]] || die "base capture did not write manifest"
image_disk="$(json_field "${base_dir}/manifest.json" rootfs.storage.index_digest)"
base_disk="$(disk_base "${base_dir}/manifest.json")"
[[ -n "${base_disk}" && "${base_disk}" != "${image_disk}" ]] || {
  cat "${base_dir}/manifest.json" >&2 || true
  die "base capture did not record its writable disk"
}

# Anything resume can restore must also pass inspect; disk-backed captures
# once tripped BadManifest in the inspect parser.
"${spore_bin}" --json checkpoint inspect "${base_dir}" >"${workdir}/inspect.json" || {
  cat "${workdir}/inspect.json" >&2 || true
  die "spore checkpoint inspect rejected a disk-backed capture that resume accepts"
}

"${spore_bin}" checkpoint fork "${base_dir}" --count 4 --out "${fork_dir}" >"${workdir}/fork.json" || {
  cat "${workdir}/fork.json" >&2 || true
  die "writable rootfs fork failed"
}

for child_name in 000000 000001 000002 000003; do
  child_manifest="${fork_dir}/${child_name}/manifest.json"
  [[ -f "${child_manifest}" ]] || die "fork child ${child_name} did not write manifest"
  [[ "$(disk_base "${child_manifest}")" == "${base_disk}" ]] || {
    cat "${child_manifest}" >&2 || true
    die "fork child ${child_name} did not preserve parent disk"
  }
done

"${spore_bin}" run \
  --backend "${backend}" \
  --from "${fork_dir}/000000" \
  --save "${fork_child0_capture_dir}" \
  -- /bin/sh -lc 'test "$(cat /var/sporevm-parent)" = "parent-layer-ok" && printf "fork-child0-layer-ok\n" >/var/sporevm-fork-child && sync' \
  >"${fork_child0_stdout}" 2>"${fork_child0_stderr}" || {
  cat "${fork_child0_stdout}" >&2 || true
  cat "${fork_child0_stderr}" >&2 || true
  die "fork child 000000 writable capture failed"
}

fork_child0_disk="$(disk_base "${fork_child0_capture_dir}/manifest.json")"
[[ -n "${fork_child0_disk}" && "${fork_child0_disk}" != "${base_disk}" ]] || {
  cat "${fork_child0_capture_dir}/manifest.json" >&2 || true
  die "fork child 000000 capture did not record its own disk writes"
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
  --save "${child_dir}" \
  -- /bin/sh -lc 'test "$(cat /var/sporevm-parent)" = "parent-layer-ok" && printf "child-layer-ok\n" >/var/sporevm-child && sync' \
  >"${child_stdout}" 2>"${child_stderr}" || {
  cat "${child_stdout}" >&2 || true
  cat "${child_stderr}" >&2 || true
  die "child writable rootfs capture failed"
}

[[ -f "${child_dir}/manifest.json" ]] || die "child capture did not write manifest"
child_disk="$(disk_base "${child_dir}/manifest.json")"
[[ -n "${child_disk}" && "${child_disk}" != "${base_disk}" ]] || {
  cat "${child_dir}/manifest.json" >&2 || true
  die "child capture did not record its own disk writes"
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

"${spore_bin}" --json checkpoint push "${child_dir}" "${store_dir}/child" >"${workdir}/push.json" || {
  cat "${workdir}/push.json" >&2 || true
  die "writable rootfs push failed"
}

# Into an empty rootfs cache, so the pull must fetch the child's disk.
SPOREVM_ROOTFS_CACHE_DIR="${pull_cache}" \
  "${spore_bin}" --json checkpoint pull "file://${store_dir}/child" --out "${pulled_dir}" >"${workdir}/pull.json" || {
  cat "${workdir}/pull.json" >&2 || true
  die "writable rootfs pull failed"
}

[[ -f "${pulled_dir}/manifest.json" ]] || die "pulled writable rootfs spore did not write manifest"
[[ "$(disk_base "${pulled_dir}/manifest.json")" == "${child_disk}" ]] || {
  cat "${pulled_dir}/manifest.json" >&2 || true
  die "pulled writable rootfs spore did not preserve the child disk"
}

SPOREVM_ROOTFS_CACHE_DIR="${pull_cache}" "${spore_bin}" run \
  --backend "${backend}" \
  --from "${pulled_dir}" \
  -- /bin/sh -lc 'cat /var/sporevm-parent /var/sporevm-child' \
  >"${pulled_verify_stdout}" 2>"${pulled_verify_stderr}" || {
  cat "${pulled_verify_stdout}" >&2 || true
  cat "${pulled_verify_stderr}" >&2 || true
  die "pulled writable rootfs verification run failed"
}

grep -Fxq "parent-layer-ok" "${pulled_verify_stdout}" || {
  cat "${pulled_verify_stdout}" >&2 || true
  cat "${pulled_verify_stderr}" >&2 || true
  die "pulled verification run did not see parent layer contents"
}
grep -Fxq "child-layer-ok" "${pulled_verify_stdout}" || {
  cat "${pulled_verify_stdout}" >&2 || true
  cat "${pulled_verify_stderr}" >&2 || true
  die "pulled verification run did not see child layer contents"
}

echo "smoke:writable-rootfs ok backend=${backend} image=${resolved_image_ref}"
