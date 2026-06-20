#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_EXTRA_DIR="${REPO_ROOT}/release-extra"
INITRD_PATH="${RELEASE_EXTRA_DIR}/share/sporevm/minimal-exec-initrd.cpio"

rm -rf "${RELEASE_EXTRA_DIR}"
mkdir -p "$(dirname "${INITRD_PATH}")"
"${REPO_ROOT}/scripts/make-minimal-exec-initrd.sh" "${INITRD_PATH}"
