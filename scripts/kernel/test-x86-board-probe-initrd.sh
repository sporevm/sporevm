#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
generator="${script_dir}/make-x86-board-probe-initrd.sh"
source_file="${repo_root}/guest/x86-board-probe/init.c"

fail() {
  echo "x86 board-probe initrd test: $*" >&2
  exit 1
}

bash -n "${generator}"
bash -n "$0"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${generator}" "$0"
fi

help="$(${generator} --help)"
[[ "${help}" == *"x86_64-linux-musl"* ]] || fail "help omits target architecture"
[[ "${help}" == *"0xd0001000"* ]] || fail "help omits generation GPA"

required_source_tokens=(
  'GENERATION_GPA UINT64_C(0xd0001000)'
  'GENERATION_MAGIC UINT32_C(0x4e475053)'
  'cpu_online=%s cpu_count=%u'
  'virtio_count=%zu'
  'console=hvc0 stdout=ok'
  'detail=bad-magic'
  'status=ready'
  'sporevm.probe_mode='
  'poweroff-native'
  'POWEROFF_DOORBELL_OFFSET 0x020U'
  'POWEROFF_COMMAND UINT32_C(0x46464f50)'
  '"write-returned"'
  'sync();'
)
for token in "${required_source_tokens[@]}"; do
  grep -Fq "${token}" "${source_file}" || fail "source omits ${token}"
done

compiler_available=0
if [[ -n "${CC:-}" ]] || command -v zig >/dev/null 2>&1; then
  compiler_available=1
elif command -v mise >/dev/null 2>&1 && [[ -n "$(mise which zig 2>/dev/null || true)" ]]; then
  compiler_available=1
fi
if (( compiler_available == 0 )); then
  echo "x86 board-probe initrd test: source checks passed; build skipped (no compiler)"
  exit 0
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-x86-board-probe-test.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
first="${workdir}/first.cpio"
second="${workdir}/second.cpio"
SOURCE_DATE_EPOCH=0 "${generator}" "${first}" >/dev/null
SOURCE_DATE_EPOCH=0 "${generator}" "${second}" >/dev/null
cmp -s "${first}" "${second}" || fail "repeated builds are not deterministic"
if SOURCE_DATE_EPOCH=+1 "${generator}" "${workdir}/invalid.cpio" >/dev/null 2>&1; then
  fail "accepted a non-decimal SOURCE_DATE_EPOCH"
fi

if command -v cpio >/dev/null 2>&1; then
  listing="$(cpio -it <"${first}" 2>/dev/null | LC_ALL=C sort)"
  expected=$'.\ndev\ninit\nproc\nsys'
  [[ "${listing}" == "${expected}" ]] || fail "unexpected newc archive contents"
fi

echo "x86 board-probe initrd test: passed"
