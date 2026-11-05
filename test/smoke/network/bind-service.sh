#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_spore_bin

smoke_tempdir workdir "/tmp/sporevm-bs"
sock="${workdir}/metadata.sock"
server_pid=""
cleanup() {
  [[ -z "${server_pid}" ]] || kill "${server_pid}" 2>/dev/null || true
}

python3 - "${sock}" <<'PY' &
import os
import socket
import sys

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)

while True:
    conn, _ = server.accept()
    with conn:
        conn.recv(4096)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 18\r\nConnection: close\r\n\r\nspore metadata ok\n")
PY
server_pid="$!"

for _ in $(seq 1 50); do
  [[ -S "${sock}" ]] && break
  sleep 0.1
done
[[ -S "${sock}" ]] || die "metadata Unix socket did not become ready"

set +e
"${spore_bin}" run --net --bind-service "metadata=unix:${sock}" -- /bin/wget -qO- http://metadata.spore.internal/ >"${workdir}/wget.stdout" 2>"${workdir}/wget.stderr"
wget_rc="$?"
set -e

if [[ "${wget_rc}" != "0" ]]; then
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore run bound service wget exited ${wget_rc}, expected 0"
fi

grep -Fxq "spore metadata ok" "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "bound service did not return the expected body"
}

echo "smoke:run-net-bind-service ok"
