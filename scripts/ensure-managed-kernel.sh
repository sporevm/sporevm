#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/ensure-managed-kernel.sh run|sporevm|initrd|rootfs

Resolve, download, cache, and verify a managed aarch64 Linux kernel Image from
buildkite/cleanroom-kernels. Prints the absolute Image path on stdout.

Kinds:
  run      SporeVM run kernel with initrd, virtio-blk, and ext4 support
  sporevm  Legacy SporeVM smoke/fork kernel with /dev/mem support
  initrd   cleanroom minimal initrd-profile kernel
  rootfs   cleanroom minimal rootfs-profile kernel

Environment:
  SPOREVM_KERNEL_IMAGE       explicit local Image path; skips download
  SPOREVM_KERNEL_RELEASE     cleanroom-kernels release tag (default: v0.5.0)
  SPOREVM_KERNEL_VERSION     Linux version in the asset name (default: 6.1.155)
  SPOREVM_KERNEL_REPOSITORY  GitHub repo (default: buildkite/cleanroom-kernels)
  SPOREVM_KERNEL_CACHE_DIR   cache directory override
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local path="$1"
  local dir base
  dir="$(dirname "${path}")"
  base="$(basename "${path}")"
  (cd "${dir}" && printf '%s/%s\n' "$(pwd -P)" "${base}")
}

cache_root() {
  if [[ -n "${SPOREVM_KERNEL_CACHE_DIR:-}" ]]; then
    printf '%s\n' "${SPOREVM_KERNEL_CACHE_DIR}"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s/sporevm/kernels\n' "${XDG_CACHE_HOME}"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s/Library/Caches/sporevm/kernels\n' "${HOME}"
  else
    printf '%s/.cache/sporevm/kernels\n' "${HOME}"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

verify_kernel() {
  local image="$1"
  local sha_file="$2"
  [[ -f "${image}" && -f "${sha_file}" ]] || return 1

  local expected actual
  expected="$(awk 'NF {print $1; exit}' "${sha_file}")"
  [[ -n "${expected}" ]] || return 1
  actual="$(sha256_file "${image}")"
  [[ "${actual}" == "${expected}" ]]
}

download_asset() {
  local repo="$1"
  local release="$2"
  local asset="$3"
  local tmp_dir="$4"

  if command -v gh >/dev/null 2>&1; then
    if GH_PROMPT_DISABLED=1 gh release download "${release}" \
      --repo "${repo}" \
      --pattern "${asset}" \
      --pattern "${asset}.sha256" \
      --dir "${tmp_dir}" \
      --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi

  command -v curl >/dev/null 2>&1 || return 1
  local base_url="https://github.com/${repo}/releases/download/${release}"
  curl -fsSL --retry 3 "${base_url}/${asset}" -o "${tmp_dir}/${asset}"
  curl -fsSL --retry 3 "${base_url}/${asset}.sha256" -o "${tmp_dir}/${asset}.sha256"
}

kind="${1:-}"
if [[ -z "${kind}" || "${kind}" == "-h" || "${kind}" == "--help" ]]; then
  usage
  [[ -z "${kind}" ]] && exit 2 || exit 0
fi
shift
[[ $# -eq 0 ]] || die "unexpected argument: $1"

if [[ -n "${SPOREVM_KERNEL_IMAGE:-}" ]]; then
  [[ -f "${SPOREVM_KERNEL_IMAGE}" ]] || die "SPOREVM_KERNEL_IMAGE not found: ${SPOREVM_KERNEL_IMAGE}"
  abs_path "${SPOREVM_KERNEL_IMAGE}"
  exit 0
fi

release="${SPOREVM_KERNEL_RELEASE:-v0.5.0}"
linux_version="${SPOREVM_KERNEL_VERSION:-6.1.155}"
repo="${SPOREVM_KERNEL_REPOSITORY:-buildkite/cleanroom-kernels}"

case "${kind}" in
  run)
    asset="sporevm-run-arm64-linux-${linux_version}-Image"
    ;;
  sporevm)
    asset="sporevm-arm64-linux-${linux_version}-Image"
    ;;
  initrd)
    asset="cleanroom-darwin-vz-minimal-initrd-arm64-linux-${linux_version}-Image"
    ;;
  rootfs)
    asset="cleanroom-darwin-vz-minimal-rootfs-arm64-linux-${linux_version}-Image"
    ;;
  *)
    die "kernel kind must be run, sporevm, initrd, or rootfs"
    ;;
esac

repo_cache="${repo//\//-}"
dest_dir="$(cache_root)/${repo_cache}/${release}"
dest="${dest_dir}/${asset}"
sha_dest="${dest}.sha256"

if verify_kernel "${dest}" "${sha_dest}"; then
  abs_path "${dest}"
  exit 0
fi

rm -f "${dest}" "${sha_dest}"
mkdir -p "${dest_dir}"
tmp_dir="$(mktemp -d "${dest_dir}/download.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "downloading managed kernel ${repo}@${release}:${asset}" >&2
download_asset "${repo}" "${release}" "${asset}" "${tmp_dir}" || die "failed to download ${asset} from ${repo}@${release}"
verify_kernel "${tmp_dir}/${asset}" "${tmp_dir}/${asset}.sha256" || die "sha256 verification failed for ${asset}"

mv "${tmp_dir}/${asset}" "${dest}"
mv "${tmp_dir}/${asset}.sha256" "${sha_dest}"
chmod 0644 "${dest}" "${sha_dest}" || true

abs_path "${dest}"
