#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/make-smoke-initrd.sh <out.cpio>

Build a tiny newc initrd containing a static /init that prints
"sporevm-initrd-tick N" once per second. Intended for KVM/HVF smoke tests.

Environment:
  CC   C compiler command to use (default: cc). May include simple arguments,
       for example: CC="zig cc -target aarch64-linux-musl". Must produce an
       aarch64 static binary for the current guest profile.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0 || exit 2
fi

out="$1"
read -r -a cc_cmd <<<"${CC:-cc}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-initrd.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/root"
cat >"${workdir}/init.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
  for (unsigned long i = 0;; i++) {
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "sporevm-initrd-tick %lu\n", i);
    if (n > 0) {
      ssize_t ignored = write(1, buf, (size_t)n);
      (void)ignored;
    }
    sleep(1);
  }
}
EOF

"${cc_cmd[@]}" -static -Os -s "${workdir}/init.c" -o "${workdir}/root/init"
chmod 0755 "${workdir}/root/init"

mkdir -p "$(dirname "${out}")"
(
  cd "${workdir}/root"
  find . | LC_ALL=C sort | cpio -o -H newc >"${out}"
)

echo "wrote ${out}"
