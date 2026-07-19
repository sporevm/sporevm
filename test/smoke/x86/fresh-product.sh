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

[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || die "x86 product smoke requires Linux/x86_64"
[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}"
if [[ -n "${seed_dir}" ]]; then
  for suffix in "" .config .sha256; do
    [[ -f "${seed_dir}/${asset}${suffix}" ]] || die "missing managed seed asset: ${seed_dir}/${asset}${suffix}"
  done
fi
[[ -z "${SPOREVM_KERNEL_IMAGE:-}" && -z "${SPOREVM_RUN_INITRD:-}" ]] || die "boot artifact overrides must be unset"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-product.XXXXXX")"
runtime_dir="${workdir}/runtime"
kernel_cache="${workdir}/kernel-cache"
vm_name="x86-product-$$"
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
if [[ -n "${seed_dir}" ]]; then
  managed_dir="${kernel_cache}/sporevm-kernels/${release}"
  mkdir -p "${managed_dir}"
  for suffix in "" .config .sha256; do
    cp "${seed_dir}/${asset}${suffix}" "${managed_dir}/${asset}${suffix}"
    chmod 0444 "${managed_dir}/${asset}${suffix}"
  done
fi

run_env=(env SPOREVM_RUNTIME_DIR="${runtime_dir}" SPOREVM_KERNEL_CACHE_DIR="${kernel_cache}")

"${run_env[@]}" "${spore_bin}" run --backend kvm --memory 512mib --vcpus 1 \
  --env SPORE_X86_PRODUCT=ok -- /bin/sh -lc \
  'set -e; test "$(/bin/nproc)" = 1; /usr/bin/env; /bin/writeout; /bin/rngcheck' \
  >"${workdir}/run.stdout" 2>"${workdir}/run.stderr"
grep -Fxq "SPORE_X86_PRODUCT=ok" "${workdir}/run.stdout" || die "literal environment was not delivered"
grep -Fxq "spore stdout" "${workdir}/run.stdout" || die "one-shot stdout was not delivered"
grep -Fxq "spore stderr" "${workdir}/run.stderr" || die "one-shot stderr was not delivered"
grep -Fxq "rng ok" "${workdir}/run.stdout" || die "virtio RNG was not functional"

"${run_env[@]}" "${spore_bin}" create "${vm_name}" --backend kvm --memory 512mib --vcpus 1 \
  >"${workdir}/create.stdout" 2>"${workdir}/create.stderr"
created=1

"${run_env[@]}" "${spore_bin}" exec "${vm_name}" -- /bin/writeout \
  >"${workdir}/exec.stdout" 2>"${workdir}/exec.stderr"
grep -Fxq "spore stdout" "${workdir}/exec.stdout" || die "named exec stdout was not delivered"
grep -Fxq "spore stderr" "${workdir}/exec.stderr" || die "named exec stderr was not delivered"

printf 'stdin-ok' | "${run_env[@]}" "${spore_bin}" exec -i "${vm_name}" -- /bin/cat \
  >"${workdir}/stdin.stdout" 2>"${workdir}/stdin.stderr"
[[ "$(cat "${workdir}/stdin.stdout")" == "stdin-ok" ]] || die "named interactive stdin did not round trip"
[[ ! -s "${workdir}/stdin.stderr" ]] || die "named interactive stdin wrote unexpected stderr"

"${run_env[@]}" "${spore_bin}" exec -t "${vm_name}" -- /bin/sh -lc \
  'printf tty-out; printf tty-err >&2' >"${workdir}/tty.stdout" 2>"${workdir}/tty.stderr"
grep -Fq "tty-out" "${workdir}/tty.stdout" || die "TTY stdout was not delivered"
grep -Fq "tty-err" "${workdir}/tty.stdout" || die "TTY stderr was not merged"
[[ ! -s "${workdir}/tty.stderr" ]] || die "TTY wrote separate stderr"

"${run_env[@]}" "${spore_bin}" rm "${vm_name}" >/dev/null
created=0
if find "${runtime_dir}" -mindepth 2 -print -quit | grep -q .; then
  find "${runtime_dir}" -mindepth 2 -maxdepth 3 -print >&2
  die "named lifecycle left runtime residue"
fi

echo "smoke:x86-fresh-product ok"
