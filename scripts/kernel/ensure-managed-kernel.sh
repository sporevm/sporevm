#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/kernel/ensure-managed-kernel.sh run|sporevm|initrd|rootfs

Resolve, download, cache, and verify a managed aarch64 Linux kernel Image from
GitHub releases. Prints the absolute Image path on stdout.

Kinds:
  run      SporeVM kernel with initrd, virtio-blk, ext4, and Docker runtime support
  sporevm  Alias for run
  initrd   cleanroom minimal initrd-profile kernel
  rootfs   cleanroom minimal rootfs-profile kernel

Environment:
  SPOREVM_KERNEL_IMAGE       explicit local Image path; skips download
  SPOREVM_KERNEL_RELEASE     kernel release tag (default: v0.6.3)
  SPOREVM_KERNEL_VERSION     Linux version in the asset name (default: 6.1.155)
  SPOREVM_KERNEL_REPOSITORY  GitHub repo override
                              default: sporevm/kernels for run/sporevm,
                              buildkite/cleanroom-kernels for initrd/rootfs
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

required_run_config_symbols=(
  CONFIG_CGROUPS
  CONFIG_FILE_LOCKING
  CONFIG_HW_RANDOM
  CONFIG_HW_RANDOM_VIRTIO
  CONFIG_VIRTIO_BLK
  CONFIG_EXT4_FS
  CONFIG_JBD2
  CONFIG_SHMEM
  CONFIG_TMPFS
  CONFIG_FSNOTIFY
  CONFIG_INOTIFY_USER
  CONFIG_BPF_SYSCALL
  CONFIG_CGROUP_BPF
  CONFIG_MEMCG
  CONFIG_CGROUP_PIDS
  CONFIG_CPUSETS
  CONFIG_CGROUP_DEVICE
  CONFIG_EXT4_FS_SECURITY
  CONFIG_MEMORY_HOTPLUG
  CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE
  CONFIG_MEMORY_HOTREMOVE
  CONFIG_CONTIG_ALLOC
  CONFIG_EXCLUSIVE_SYSTEM_RAM
  CONFIG_VIRTIO_MEM
)

verify_run_kernel_config() {
  local config_file="$1"
  [[ -f "${config_file}" ]] || return 1

  local symbol
  for symbol in "${required_run_config_symbols[@]}"; do
    if ! grep -Fxq "${symbol}=y" "${config_file}"; then
      echo "error: managed run kernel config ${config_file} is missing ${symbol}=y" >&2
      return 1
    fi
  done
  if ! grep -Fxq "# CONFIG_SECURITY is not set" "${config_file}"; then
    echo "error: managed run kernel config ${config_file} unexpectedly enables CONFIG_SECURITY" >&2
    return 1
  fi
}

verify_kernel() {
  local image="$1"
  local sha_file="$2"
  local config_file="${3:-}"
  [[ -f "${image}" && -f "${sha_file}" ]] || return 1

  local expected actual
  expected="$(awk 'NF {print $1; exit}' "${sha_file}")"
  [[ -n "${expected}" ]] || return 1
  actual="$(sha256_file "${image}")"
  [[ "${actual}" == "${expected}" ]] || return 1
  if [[ -n "${config_file}" ]]; then
    verify_run_kernel_config "${config_file}" || return 1
  fi
}

download_asset() {
  local repo="$1"
  local release="$2"
  local asset="$3"
  local tmp_dir="$4"
  local require_config="$5"

  if command -v gh >/dev/null 2>&1; then
    local patterns=(--pattern "${asset}" --pattern "${asset}.sha256")
    if [[ "${require_config}" == "1" ]]; then
      patterns+=(--pattern "${asset}.config")
    fi
    if GH_PROMPT_DISABLED=1 gh release download "${release}" \
      --repo "${repo}" \
      "${patterns[@]}" \
      --dir "${tmp_dir}" \
      --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi

  command -v curl >/dev/null 2>&1 || return 1
  local base_url="https://github.com/${repo}/releases/download/${release}"
  curl -fsSL --retry 3 "${base_url}/${asset}" -o "${tmp_dir}/${asset}"
  curl -fsSL --retry 3 "${base_url}/${asset}.sha256" -o "${tmp_dir}/${asset}.sha256"
  if [[ "${require_config}" == "1" ]]; then
    curl -fsSL --retry 3 "${base_url}/${asset}.config" -o "${tmp_dir}/${asset}.config"
  fi
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

release="${SPOREVM_KERNEL_RELEASE:-v0.6.3}"
linux_version="${SPOREVM_KERNEL_VERSION:-6.1.155}"
repo="${SPOREVM_KERNEL_REPOSITORY:-}"

case "${kind}" in
  run | sporevm)
    repo="${repo:-sporevm/kernels}"
    asset="sporevm-arm64-linux-${linux_version}-Image"
    ;;
  initrd)
    repo="${repo:-buildkite/cleanroom-kernels}"
    asset="cleanroom-darwin-vz-minimal-initrd-arm64-linux-${linux_version}-Image"
    ;;
  rootfs)
    repo="${repo:-buildkite/cleanroom-kernels}"
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
config_dest=""
require_config=0
if [[ "${kind}" == "run" || "${kind}" == "sporevm" ]]; then
  config_dest="${dest}.config"
  require_config=1
fi

if verify_kernel "${dest}" "${sha_dest}" "${config_dest}"; then
  abs_path "${dest}"
  exit 0
fi

if [[ -n "${config_dest}" ]]; then
  rm -f "${dest}" "${sha_dest}" "${config_dest}"
else
  rm -f "${dest}" "${sha_dest}"
fi
mkdir -p "${dest_dir}"
tmp_dir="$(mktemp -d "${dest_dir}/download.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "downloading managed kernel ${repo}@${release}:${asset}" >&2
download_asset "${repo}" "${release}" "${asset}" "${tmp_dir}" "${require_config}" || die "failed to download ${asset} from ${repo}@${release}"
verify_kernel "${tmp_dir}/${asset}" "${tmp_dir}/${asset}.sha256" "${config_dest:+${tmp_dir}/${asset}.config}" || die "verification failed for ${asset}"

mv "${tmp_dir}/${asset}" "${dest}"
mv "${tmp_dir}/${asset}.sha256" "${sha_dest}"
if [[ -n "${config_dest}" ]]; then
  mv "${tmp_dir}/${asset}.config" "${config_dest}"
  chmod 0444 "${dest}" "${sha_dest}" "${config_dest}" || true
else
  chmod 0444 "${dest}" "${sha_dest}" || true
fi

abs_path "${dest}"
