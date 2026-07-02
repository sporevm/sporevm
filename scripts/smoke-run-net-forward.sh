#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spore_bin="${SPORE_BIN:-${repo_root}/zig-out/bin/spore}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${spore_bin}" ]] || die "spore binary not executable: ${spore_bin}; run mise run build"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-smoke-run-net-forward.XXXXXX")"
run_pid=""
trap '[[ -n "${run_pid}" ]] && kill "${run_pid}" 2>/dev/null || true; rm -rf "${workdir}"' EXIT

host_port="$(python3 - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

"${spore_bin}" run --net --forward "127.0.0.1:${host_port}:8080" -- /bin/httpd 8080 >"${workdir}/run.stdout" 2>"${workdir}/run.stderr" &
run_pid="$!"

ready=0
for _ in $(seq 1 120); do
  if grep -Fxq "httpd ready" "${workdir}/run.stdout"; then
    ready=1
    break
  fi
  if ! kill -0 "${run_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

if [[ "${ready}" != "1" ]]; then
  cat "${workdir}/run.stdout" >&2 || true
  cat "${workdir}/run.stderr" >&2 || true
  die "guest HTTP service did not become ready"
fi

python3 - "${host_port}" "${workdir}/fetch.out" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out = sys.argv[2]
with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
    sock.settimeout(5)
    sock.sendall(b"GET / HTTP/1.1\r\nHost: spore\r\nConnection: close\r\n\r\n")
    chunks = []
    while True:
        data = sock.recv(4096)
        if not data:
            break
        chunks.append(data)
body = b"".join(chunks)
open(out, "wb").write(body)
if b"spore forward ok\n" not in body:
    sys.exit(1)
PY

set +e
wait "${run_pid}"
run_rc="$?"
set -e
run_pid=""

if [[ "${run_rc}" != "0" ]]; then
  cat "${workdir}/run.stdout" >&2 || true
  cat "${workdir}/run.stderr" >&2 || true
  die "spore run forwarded service exited ${run_rc}, expected 0"
fi

grep -Fq "spore forward ok" "${workdir}/fetch.out" || {
  cat "${workdir}/fetch.out" >&2 || true
  cat "${workdir}/run.stdout" >&2 || true
  cat "${workdir}/run.stderr" >&2 || true
  die "host fetch did not receive guest response"
}

echo "smoke:run-net-forward ok"
