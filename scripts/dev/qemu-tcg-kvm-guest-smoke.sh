#!/bin/sh
set -eu

spore="${SPOREVM_TCG_GUEST_SPORE:-/workspace/zig-out/qemu-tcg/bin/spore}"
work="$(mktemp -d /tmp/sporevm-qemu-smoke.XXXXXX)"
runtime="${work}/runtime"
output="${work}/output"
forward_port="${SPOREVM_TCG_FORWARD_PORT:-18082}"
allow_host="${SPOREVM_TCG_ALLOW_HOST:-detectportal.firefox.com}"
allow_url="${SPOREVM_TCG_ALLOW_URL:-http://detectportal.firefox.com/success.txt}"
forward_pid=""

cleanup() {
  if [ -n "$forward_pid" ] && kill -0 "$forward_pid" 2>/dev/null; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'smoke:qemu-tcg-kvm failed: %s\n' "$*" >&2
  exit 1
}

run_spore() {
  HOME=/root SPOREVM_RUNTIME_DIR="$runtime" "$spore" "$@"
}

assert_contains() {
  file="$1"
  expected="$2"
  grep -F "$expected" "$file" >/dev/null ||
    fail "expected '$expected' in $file"
}

test -c /dev/kvm || fail "/dev/kvm is unavailable"
test -x "$spore" || fail "SporeVM binary is unavailable at $spore"
mkdir -p "$runtime" "$output"
run_spore host-info >"${output}/host-info.txt"

printf 'smoke:qemu-tcg-kvm fresh run\n'
run_spore run -- /bin/writeout >"${output}/writeout.stdout" 2>"${output}/writeout.stderr"
assert_contains "${output}/writeout.stdout" "spore stdout"
assert_contains "${output}/writeout.stderr" "spore stderr"

printf 'smoke:qemu-tcg-kvm guest networking\n'
run_spore run --net -- /bin/netcheck >"${output}/netcheck.txt"
assert_contains "${output}/netcheck.txt" "100.96.0.2"
assert_contains "${output}/netcheck.txt" "100.96.0.1"

printf 'smoke:qemu-tcg-kvm restricted egress\n'
run_spore run --net --allow-host "$allow_host" -- /bin/wget -qO- "$allow_url" \
  >"${output}/allow.txt"
assert_contains "${output}/allow.txt" "success"

if run_spore --debug run --net --allow-host 169.254.169.254 -- \
  /bin/wget -qO- http://169.254.169.254/ \
  >"${output}/deny.stdout" 2>"${output}/deny.stderr"; then
  fail "link-local metadata address was unexpectedly reachable"
fi
grep -E 'denied egress|hard.floor|hard-floor|169\.254\.169\.254' \
  "${output}/deny.stdout" "${output}/deny.stderr" >/dev/null ||
  fail "link-local denial did not explain the blocked address"

printf 'smoke:qemu-tcg-kvm save and restore\n'
run_spore run --memory 256mib --net --save "${work}/saved.spore" -- /bin/true \
  >"${output}/save.txt"
run_spore run --from "${work}/saved.spore" -- /bin/writeout \
  >"${output}/restore.stdout" 2>"${output}/restore.stderr"
assert_contains "${output}/restore.stdout" "spore stdout"
assert_contains "${output}/restore.stderr" "spore stderr"

printf 'smoke:qemu-tcg-kvm host port forwarding\n'
run_spore run --net --forward "127.0.0.1:${forward_port}:8080" -- \
  /bin/httpd 8080 >"${output}/forward.stdout" 2>"${output}/forward.stderr" &
forward_pid="$!"

attempt=0
while [ "$attempt" -lt 40 ]; do
  if grep -Fxq "httpd ready" "${output}/forward.stdout"; then
    break
  fi
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    wait "$forward_pid" || true
    fail "port-forwarded guest exited before becoming ready"
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done

grep -Fxq "httpd ready" "${output}/forward.stdout" ||
  fail "port-forwarded guest did not report ready"
wget -q -O "${output}/forward.fetch" "http://127.0.0.1:${forward_port}/" ||
  fail "port-forwarded HTTP server was unreachable"
assert_contains "${output}/forward.fetch" "spore forward ok"
wait "$forward_pid" || fail "port-forwarded guest exited unsuccessfully"
forward_pid=""

printf 'smoke:qemu-tcg-kvm ok\n'
