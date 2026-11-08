#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
# shellcheck source=src/managed_kernel.env
source "${repo_root}/src/managed_kernel.env"
release="${SPOREVM_KERNEL_RELEASE:-${managed_kernel_release}}"
asset="sporevm-x86_64-linux-${managed_kernel_linux_version}-bzImage"

expect_failure() {
  local label="$1"
  local needle="$2"
  shift 2
  if "$@" >"${workdir}/${label}.stdout" 2>"${workdir}/${label}.stderr"; then
    die "${label} unexpectedly succeeded"
  fi
  grep -Fqi -- "${needle}" "${workdir}/${label}.stderr" || {
    cat "${workdir}/${label}.stderr" >&2 || true
    die "${label} did not explain the x86 restriction"
  }
}

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 fail-closed smoke requires Linux/x86_64"
require_spore_bin
if [[ -n "${seed_dir}" ]]; then
  for suffix in "" .config .sha256; do
    [[ -f "${seed_dir}/${asset}${suffix}" ]] || die "missing managed seed asset: ${seed_dir}/${asset}${suffix}"
  done
fi

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-x86-closed"
runtime_dir="${workdir}/runtime"
kernel_cache="${workdir}/kernel-cache"
vm_name="x86-closed-$$"
fork_name="x86-fork-rejected-$$"
created=0
cleanup() {
  if ((created)); then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_KERNEL_CACHE_DIR="${kernel_cache}" \
      "${spore_bin}" vm rm "${vm_name}" >/dev/null 2>&1 || true
  fi
}
mkdir -p "${runtime_dir}"
chmod 0700 "${runtime_dir}"
run_env=(env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_KERNEL_CACHE_DIR="${kernel_cache}")

expect_failure run-auto-memory "--memory auto was removed" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory auto -- /bin/true
expect_failure run-vcpus "requires --vcpus 1" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --vcpus 2 -- /bin/true
expect_failure create-auto-memory "--memory auto was removed" \
  "${run_env[@]}" "${spore_bin}" vm create rejected-auto-$$ --backend kvm --memory auto
expect_failure run-save "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --save-checkpoint "${workdir}/saved.spore" -- /bin/true
expect_failure run-resume "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --checkpoint "${workdir}/missing.spore" -- /bin/true
expect_failure restore "resume is unavailable" \
  "${run_env[@]}" "${spore_bin}" vm restore restored-$$ --checkpoint "${workdir}/missing.spore" --backend kvm
expect_failure attach "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" checkpoint resume "${workdir}/missing.spore"
expect_failure checkpoint-fork "checkpoint fork is unavailable" \
  "${run_env[@]}" "${spore_bin}" checkpoint fork "${workdir}/missing.spore" --count 1 --output "${workdir}/children"
expect_failure build-vcpus "X86VcpuCountUnsupported" \
  "${run_env[@]}" "${spore_bin}" build --platform linux/amd64 --vcpus 2 --tag local/x86-rejected:dev -f "${workdir}/missing-Dockerfile" "${workdir}/missing-context"
expect_failure build-memory "X86ExperimentalMemorySizeUnsupported" \
  "${run_env[@]}" "${spore_bin}" build --platform linux/amd64 --memory 1gb --tag local/x86-rejected:dev -f "${workdir}/missing-Dockerfile" "${workdir}/missing-context"
[[ ! -e "${workdir}/saved.spore" ]] || die "rejected save created output"
[[ ! -e "${workdir}/children" ]] || die "rejected checkpoint fork created output"
[[ ! -e "${kernel_cache}" ]] || die "rejected requests performed managed kernel work"

managed_dir="${kernel_cache}/${managed_kernel_repository//\//-}/${release}"
if [[ -n "${seed_dir}" ]]; then
  mkdir -p "${managed_dir}"
  for suffix in "" .config .sha256; do
    cp "${seed_dir}/${asset}${suffix}" "${managed_dir}/${asset}${suffix}"
    chmod 0444 "${managed_dir}/${asset}${suffix}"
  done
fi
"${run_env[@]}" "${spore_bin}" vm create "${vm_name}" --backend kvm --memory 512mib --vcpus 1 >/dev/null
created=1
expect_failure named-copy-in "does not support copying files" \
  "${run_env[@]}" "${spore_bin}" vm copy-in "${vm_name}" "${workdir}/missing-host-input" /tmp/input
expect_failure named-copy-out "does not support copying files" \
  "${run_env[@]}" "${spore_bin}" vm copy-out "${vm_name}" /tmp/output "${workdir}/host-output"
[[ ! -e "${workdir}/host-output" ]] || die "rejected named copy-out created output"
expect_failure named-save "capture is unavailable" \
  "${run_env[@]}" "${spore_bin}" vm save "${vm_name}" --output "${workdir}/named.spore"
"${run_env[@]}" "${spore_bin}" vm exec "${vm_name}" -- /bin/true
[[ ! -e "${workdir}/named.spore" ]] || die "rejected named save created output"
expect_failure named-fork "capture is unavailable" \
  "${run_env[@]}" "${spore_bin}" vm fork "${vm_name}" --count 1 --name-prefix "${fork_name}"
"${run_env[@]}" "${spore_bin}" vm exec "${vm_name}" -- /bin/true
if [[ -e "${runtime_dir}/vms/${fork_name}-0" ]]; then
  die "rejected named fork created child state"
fi
"${run_env[@]}" "${spore_bin}" vm rm "${vm_name}" >/dev/null
created=0
if find "${runtime_dir}" -mindepth 2 -print -quit | grep -q .; then
  find "${runtime_dir}" -mindepth 2 -maxdepth 3 -print >&2
  die "fail-closed checks left runtime residue"
fi

echo "smoke:x86-fail-closed ok"
