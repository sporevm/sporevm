#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
generator="${script_dir}/make-x86-profile-roundtrip-initrd.sh"
c_source="${repo_root}/guest/x86-profile-roundtrip/init.c"
assembly_source="${repo_root}/guest/x86-profile-roundtrip/profile_state.S"
abi_source="${repo_root}/guest/x86-profile-roundtrip/mailbox_abi.h"

fail() {
  echo "x86 profile roundtrip initrd test: $*" >&2
  exit 1
}

bash -n "${generator}"
bash -n "$0"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${generator}" "$0"
fi

help="$(${generator} --help)"
[[ "${help}" == *"Ambient CC is"* ]] || fail "help does not freeze ambient CC policy"
[[ "${help}" == *"0xcffff000"* ]] || fail "help omits mailbox GPA"
[[ "${help}" == *"CAPT/RSTR"* ]] || fail "help omits doorbell contract"

required_c_tokens=(
  'MAILBOX_GPA UINT64_C(0xcffff000)'
  'GENERATION_GPA UINT64_C(0xd0001000)'
  'CAPTURE_DOORBELL_OFFSET 0x028U'
  'RESTORED_DOORBELL_OFFSET 0x02cU'
  'RESTORED_COMMAND UINT32_C(0x52545352)'
  'CLOCK_MONOTONIC'
  'CLOCK_BOOTTIME'
  'CLOCK_REALTIME'
  'cpuid_count = CPUID_RECORD_COUNT'
  'xcr0 & UINT64_C(0x6)'
)
for token in "${required_c_tokens[@]}"; do
  grep -Fq "${token}" "${c_source}" || fail "C source omits ${token}"
done
required_abi_tokens=(
  '#define CAPTURE_COMMAND 0x54504143'
  '#define MAILBOX_TOTAL_BYTES 512'
  'sizeof(struct profile_mailbox) == MAILBOX_TOTAL_BYTES'
  'offsetof(struct profile_mailbox, observed_ymm) == MAILBOX_OBSERVED_YMM_OFFSET'
)
for token in "${required_abi_tokens[@]}"; do
  grep -Fq "${token}" "${abi_source}" || fail "mailbox ABI omits ${token}"
done
required_assembly_tokens=(
  'fldt    .Lexpected_x87(%rip)'
  'movdqu  .Lexpected_xmm(%rip), %xmm0'
  'vmovdqu .Lexpected_ymm(%rip), %ymm1'
  'movl    $CAPTURE_COMMAND, (%rdi)'
  'fstpt   MAILBOX_OBSERVED_X87_OFFSET(%rsi)'
  'vmovdqu %ymm1, MAILBOX_OBSERVED_YMM_OFFSET(%rsi)'
)
for token in "${required_assembly_tokens[@]}"; do
  grep -Fq "${token}" "${assembly_source}" || fail "assembly source omits ${token}"
done

compiler_available=0
if [[ -n "${SPOREVM_X86_64_LINUX_CC:-}" ]]; then
  compiler_available=1
elif command -v mise >/dev/null 2>&1 &&
     [[ -n "$(cd "${repo_root}" && mise which zig 2>/dev/null || true)" ]]; then
  compiler_available=1
fi
if (( compiler_available == 0 )); then
  echo "x86 profile roundtrip initrd test: source checks passed; build skipped (no pinned compiler)"
  exit 0
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-profile-roundtrip-test.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
first="${workdir}/first.cpio"
second="${workdir}/second.cpio"
ambient="${workdir}/ambient-cc.cpio"
SOURCE_DATE_EPOCH=0 "${generator}" "${first}" >/dev/null
SOURCE_DATE_EPOCH=0 "${generator}" "${second}" >/dev/null
cmp -s "${first}" "${second}" || fail "repeated builds are not deterministic"

# A common ambient macOS CC must not redirect the probe away from the pinned
# x86_64-linux-musl compiler.
CC=clang SOURCE_DATE_EPOCH=0 "${generator}" "${ambient}" >/dev/null
cmp -s "${first}" "${ambient}" || fail "ambient CC changed the initrd"

if command -v cpio >/dev/null 2>&1; then
  listing="$(cpio -it <"${first}" 2>/dev/null | LC_ALL=C sort)"
  expected=$'.\ndev\ninit\nproc'
  [[ "${listing}" == "${expected}" ]] || fail "unexpected newc archive contents"
fi

echo "x86 profile roundtrip initrd test: passed"
