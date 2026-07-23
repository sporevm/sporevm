#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"
seed_dir="${SPOREVM_X86_MANAGED_KERNEL_SEED_DIR:-}"
release="${SPOREVM_KERNEL_RELEASE:-v0.7.0}"
asset="sporevm-x86_64-linux-6.1.155-bzImage"

die() {
  echo "error: $*" >&2
  exit 1
}

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
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"
if [[ -n "${seed_dir}" ]]; then
  for suffix in "" .config .sha256; do
    [[ -f "${seed_dir}/${asset}${suffix}" ]] || die "missing managed seed asset: ${seed_dir}/${asset}${suffix}"
  done
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-closed.XXXXXX")"
runtime_dir="${workdir}/runtime"
kernel_cache="${workdir}/kernel-cache"
vm_name="x86-closed-$$"
fork_name="x86-fork-rejected-$$"
created=0
cleanup() {
  if ((created)); then
    env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_KERNEL_CACHE_DIR="${kernel_cache}" \
      "${spore_bin}" rm "${vm_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT
mkdir -p "${runtime_dir}"
chmod 0700 "${runtime_dir}"
run_env=(env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_KERNEL_CACHE_DIR="${kernel_cache}")

expect_failure run-auto-memory "--memory auto was removed" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory auto -- /bin/true
expect_failure run-vcpus "requires --vcpus 1" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --vcpus 2 -- /bin/true
expect_failure run-rootfs "rootfs, OCI, networking, and build integration have not landed" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --rootfs "${workdir}/missing.ext4" -- /bin/true
expect_failure run-network "rootfs, OCI, networking, and build integration have not landed" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --net -- /bin/true
expect_failure run-commit "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --image local/missing:dev --commit local/rejected:dev -- /bin/true
expect_failure create-auto-memory "--memory auto was removed" \
  "${run_env[@]}" "${spore_bin}" create rejected-auto-$$ --backend kvm --memory auto
expect_failure run-save "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --save "${workdir}/saved.spore" -- /bin/true
expect_failure run-resume "fresh execution only" \
  "${run_env[@]}" "${spore_bin}" run --backend kvm --from "${workdir}/missing.spore" -- /bin/true
expect_failure restore "resume is unavailable" \
  "${run_env[@]}" "${spore_bin}" restore "${workdir}/missing.spore" --name restored-$$ --backend kvm
expect_failure attach "X86ResumeUnsupported" \
  "${run_env[@]}" "${spore_bin}" attach "${workdir}/missing.spore"
expect_failure build "X86BuildUnsupported" \
  "${run_env[@]}" "${spore_bin}" build -t local/x86-rejected:dev -f "${workdir}/missing-Dockerfile" "${workdir}/missing-context"
[[ ! -e "${workdir}/saved.spore" ]] || die "rejected save created output"
[[ ! -e "${kernel_cache}" ]] || die "rejected requests performed managed kernel work"

managed_dir="${kernel_cache}/sporevm-kernels/${release}"
if [[ -n "${seed_dir}" ]]; then
  mkdir -p "${managed_dir}"
  for suffix in "" .config .sha256; do
    cp "${seed_dir}/${asset}${suffix}" "${managed_dir}/${asset}${suffix}"
    chmod 0444 "${managed_dir}/${asset}${suffix}"
  done
fi
"${run_env[@]}" "${spore_bin}" create "${vm_name}" --backend kvm --memory 512mib --vcpus 1 >/dev/null
created=1
expect_failure named-save "capture is unavailable" \
  "${run_env[@]}" "${spore_bin}" save "${vm_name}" --out "${workdir}/named.spore"
"${run_env[@]}" "${spore_bin}" exec "${vm_name}" -- /bin/true
[[ ! -e "${workdir}/named.spore" ]] || die "rejected named save created output"
expect_failure named-fork "capture is unavailable" \
  "${run_env[@]}" "${spore_bin}" fork --vm "${vm_name}" --count 1 --name "${fork_name}"
"${run_env[@]}" "${spore_bin}" exec "${vm_name}" -- /bin/true
if [[ -e "${runtime_dir}/vms/${fork_name}" ]]; then
  die "rejected named fork created child state"
fi
"${run_env[@]}" "${spore_bin}" rm "${vm_name}" >/dev/null
created=0
if find "${runtime_dir}" -mindepth 2 -print -quit | grep -q .; then
  find "${runtime_dir}" -mindepth 2 -maxdepth 3 -print >&2
  die "fail-closed checks left runtime residue"
fi

echo "smoke:x86-fail-closed ok"
