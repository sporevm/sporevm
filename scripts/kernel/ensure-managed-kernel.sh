#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/kernel/ensure-managed-kernel.sh

Resolve, download, cache, and verify the managed SporeVM kernel for this host
from GitHub releases. Defaults come from src/managed_kernel.env. Prints the
absolute Image or bzImage path on stdout.

Environment:
  SPOREVM_KERNEL_IMAGE       explicit local Image path; skips download
  SPOREVM_KERNEL_RELEASE     kernel release tag override
  SPOREVM_KERNEL_VERSION     Linux version override
  SPOREVM_KERNEL_REPOSITORY  GitHub repo override
  SPOREVM_KERNEL_CACHE_DIR   cache directory override
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# shellcheck source=src/managed_kernel.env
source "$(dirname "${BASH_SOURCE[0]}")/../../src/managed_kernel.env"

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
  CONFIG_NAMESPACES
  CONFIG_PID_NS
  CONFIG_UTS_NS
  CONFIG_IPC_NS
  CONFIG_SECCOMP
  CONFIG_SECCOMP_FILTER
  CONFIG_POSIX_MQUEUE
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

kernel_arch="${SPOREVM_KERNEL_ARCH:-$(uname -m)}"
case "${kernel_arch}" in
  arm64 | aarch64) kernel_arch="arm64" ;;
  x86_64 | amd64) kernel_arch="x86_64" ;;
  *) die "unsupported managed kernel architecture: ${kernel_arch}" ;;
esac

required_x86_config_symbols=(
  CONFIG_X86_64 CONFIG_SMP CONFIG_X86_LOCAL_APIC CONFIG_X86_IO_APIC
  CONFIG_X86_MPPARSE CONFIG_HYPERVISOR_GUEST CONFIG_PARAVIRT
  CONFIG_PARAVIRT_CLOCK CONFIG_KVM_GUEST CONFIG_RELOCATABLE
  CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES CONFIG_DEVMEM CONFIG_STRICT_DEVMEM
)
forbidden_x86_config_symbols=(
  CONFIG_IO_STRICT_DEVMEM CONFIG_ACPI CONFIG_EFI CONFIG_PCI CONFIG_VIRTIO_PCI
  CONFIG_RTC_CLASS CONFIG_SERIAL_8250 CONFIG_KEYBOARD_ATKBD CONFIG_MOUSE_PS2
  CONFIG_SERIO_I8042
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
  if [[ "${kernel_arch}" == "x86_64" ]]; then
    for symbol in "${required_x86_config_symbols[@]}"; do
      if ! grep -Fxq "${symbol}=y" "${config_file}"; then
        echo "error: managed x86 kernel config ${config_file} is missing ${symbol}=y" >&2
        return 1
      fi
    done
    for symbol in "${forbidden_x86_config_symbols[@]}"; do
      if grep -Eq "^${symbol}=(y|m)$" "${config_file}"; then
        echo "error: managed x86 kernel config ${config_file} enables forbidden ${symbol}" >&2
        return 1
      fi
    done
  fi
  if ! grep -Fxq "# CONFIG_SECURITY is not set" "${config_file}"; then
    echo "error: managed run kernel config ${config_file} unexpectedly enables CONFIG_SECURITY" >&2
    return 1
  fi
}

verify_kernel() {
  local image="$1"
  local sha_file="$2"
  local config_file="$3"
  [[ -f "${image}" && -f "${sha_file}" ]] || return 1

  local expected actual
  expected="$(awk 'NF {print $1; exit}' "${sha_file}")"
  [[ -n "${expected}" ]] || return 1
  actual="$(sha256_file "${image}")"
  [[ "${actual}" == "${expected}" ]] || return 1
  if [[ "${kernel_arch}" == "x86_64" && "${actual}" != "${managed_kernel_x86_64_sha256}" ]]; then
    echo "error: managed x86 kernel does not match the approved candidate digest" >&2
    return 1
  fi
  verify_run_kernel_config "${config_file}"
}

download_asset() {
  local repo="$1"
  local release="$2"
  local asset="$3"
  local tmp_dir="$4"

  if command -v gh >/dev/null 2>&1; then
    if GH_PROMPT_DISABLED=1 gh release download "${release}" \
      --repo "${repo}" \
      --pattern "${asset}" --pattern "${asset}.sha256" --pattern "${asset}.config" \
      --dir "${tmp_dir}" \
      --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi

  command -v curl >/dev/null 2>&1 || return 1
  local base_url="https://github.com/${repo}/releases/download/${release}"
  local suffix
  for suffix in "" .sha256 .config; do
    curl -fsSL --retry 3 "${base_url}/${asset}${suffix}" -o "${tmp_dir}/${asset}${suffix}"
  done
}

case "${1:-}" in
  "") ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ -n "${SPOREVM_KERNEL_IMAGE:-}" ]]; then
  [[ -f "${SPOREVM_KERNEL_IMAGE}" ]] || die "SPOREVM_KERNEL_IMAGE not found: ${SPOREVM_KERNEL_IMAGE}"
  abs_path "${SPOREVM_KERNEL_IMAGE}"
  exit 0
fi

repo="${SPOREVM_KERNEL_REPOSITORY:-${managed_kernel_repository}}"
release="${SPOREVM_KERNEL_RELEASE:-${managed_kernel_release}}"
linux_version="${SPOREVM_KERNEL_VERSION:-${managed_kernel_linux_version}}"
if [[ "${kernel_arch}" == "x86_64" ]]; then
  asset="sporevm-x86_64-linux-${linux_version}-bzImage"
else
  asset="sporevm-arm64-linux-${linux_version}-Image"
fi

dest_dir="$(cache_root)/${repo//\//-}/${release}"
dest="${dest_dir}/${asset}"

if verify_kernel "${dest}" "${dest}.sha256" "${dest}.config"; then
  abs_path "${dest}"
  exit 0
fi

rm -f "${dest}" "${dest}.sha256" "${dest}.config"
mkdir -p "${dest_dir}"
tmp_dir="$(mktemp -d "${dest_dir}/download.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "downloading managed kernel ${repo}@${release}:${asset}" >&2
download_asset "${repo}" "${release}" "${asset}" "${tmp_dir}" || die "failed to download ${asset} from ${repo}@${release}"
verify_kernel "${tmp_dir}/${asset}" "${tmp_dir}/${asset}.sha256" "${tmp_dir}/${asset}.config" || die "verification failed for ${asset}"

for suffix in "" .sha256 .config; do
  mv "${tmp_dir}/${asset}${suffix}" "${dest}${suffix}"
done
chmod 0444 "${dest}" "${dest}.sha256" "${dest}.config" || true

abs_path "${dest}"
