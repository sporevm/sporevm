#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)/$(uname -m)" in
  Linux/aarch64|Linux/arm64)
    backend="kvm"
    target="linux-arm64"
    archive="spore_Linux_arm64.tar.gz"
    archive_dir="spore_Linux_arm64"
    [[ -c /dev/kvm ]] || {
      echo "diskless removal smoke requires /dev/kvm" >&2
      exit 1
    }
    ;;
  Darwin/arm64)
    backend="hvf"
    target="darwin-arm64"
    archive="spore_Darwin_arm64.tar.gz"
    archive_dir="spore_Darwin_arm64"
    ;;
  *)
    echo "diskless removal smoke requires Linux ARM64/KVM or macOS ARM64/HVF" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch_root="${SPOREVM_DISKLESS_REMOVE_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "${scratch_root}"
workdir="$(mktemp -d "${scratch_root%/}/sporevm-diskless-remove.XXXXXX")"
spore_bin=""

cleanup() {
  if [[ -n "${spore_bin}" && -x "${spore_bin}" ]]; then
    SPOREVM_RUNTIME_DIR="${workdir}/runtime" SPOREVM_ROOTFS_CACHE="${workdir}/cache" \
      "${spore_bin}" rm diskless-rm-1 >/dev/null 2>&1 || true
    SPOREVM_RUNTIME_DIR="${workdir}/runtime" SPOREVM_ROOTFS_CACHE="${workdir}/cache" \
      "${spore_bin}" rm diskless-rm-2 >/dev/null 2>&1 || true
    for saved in stopped-1.spore stopped-2.spore; do
      if [[ -d "${workdir}/run/${saved}" ]]; then
        SPOREVM_RUNTIME_DIR="${workdir}/runtime" SPOREVM_ROOTFS_CACHE="${workdir}/cache" \
          "${spore_bin}" rm --spore "${workdir}/run/${saved}" >/dev/null 2>&1 || true
      fi
    done
  fi
  chmod -R u+w "${workdir}" 2>/dev/null || true
  rm -rf "${workdir}"
}
trap cleanup EXIT

cd "${repo_root}"
scripts/release/build-assets.sh --target "${target}" --output "${workdir}/dist"
tar -xzf "${workdir}/dist/${archive}" -C "${workdir}"
spore_bin="${workdir}/${archive_dir}/bin/spore"
[[ -x "${spore_bin}" ]] || {
  echo "packaged spore binary is missing: ${spore_bin}" >&2
  exit 1
}

mkdir -p "${workdir}/runtime" "${workdir}/cache" "${workdir}/run"
chmod 0700 "${workdir}/runtime" "${workdir}/cache" "${workdir}/run"
export SPOREVM_RUNTIME_DIR="${workdir}/runtime"
export SPOREVM_ROOTFS_CACHE="${workdir}/cache"
cd "${workdir}/run"

"${spore_bin}" create diskless-rm-1 --backend "${backend}" --memory 256mb --vcpus 1
"${spore_bin}" save diskless-rm-1 --out stopped-1.spore --stop
"${spore_bin}" inspect stopped-1.spore > inspect-1.txt
grep -Fq "vCPUs: 1" inspect-1.txt
"${spore_bin}" rm --spore stopped-1.spore > removed-1.txt
grep -Fxq "removed spore stopped-1.spore (no disk pin)" removed-1.txt
[[ ! -e stopped-1.spore ]]
if "${spore_bin}" rm --spore stopped-1.spore >/dev/null 2>&1; then
  echo "repeated diskless saved-spore removal unexpectedly succeeded" >&2
  exit 1
fi

"${spore_bin}" create diskless-rm-2 --backend "${backend}" --memory 256mb --vcpus 2
"${spore_bin}" save diskless-rm-2 --out stopped-2.spore --stop
"${spore_bin}" inspect stopped-2.spore > inspect-2.txt
grep -Fq "vCPUs: 2" inspect-2.txt
"${spore_bin}" --json rm --spore stopped-2.spore > removed-2.json
python3 - "${workdir}/run/removed-2.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "action": "removed_spore",
    "spore_dir": "stopped-2.spore",
    "pin_id": "",
    "pin_removed": False,
}
if result != expected:
    raise SystemExit(f"unexpected diskless removal JSON: {result!r}")
PY
[[ ! -e stopped-2.spore ]]

echo "packaged diskless saved-spore removal smoke ok: backend=${backend} vcpus=1,2"
