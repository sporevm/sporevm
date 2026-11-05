#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

backend="$(infer_backend)"
require_spore_bin

smoke_tempdir workdir "${TMPDIR:-/tmp}/sporevm-bs-oci"
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

image_ref="${SPORE_SMOKE_BOUND_SERVICE_IMAGE:-docker.io/library/alpine:3.20}"
smoke_memory="${SPORE_SMOKE_MEMORY:-${SPORE_SMOKE_MEMORY_MIB:-256}mib}"

set +e
"${spore_bin}" run \
  --backend "${backend}" \
  --memory "${smoke_memory}" \
  --image "${image_ref}" \
  --pull=never \
  --net \
  --bind-service "metadata=unix:${sock}" \
  -- /bin/sh -lc 'nslookup metadata.spore.internal >/dev/null && wget -qO- http://metadata.spore.internal/' \
  >"${workdir}/wget.stdout" 2>"${workdir}/wget.stderr"
wget_rc="$?"
set -e

if [[ "${wget_rc}" != "0" ]]; then
  if grep -Eq "image ref cache miss|local image rootfs cache miss" "${workdir}/wget.stderr"; then
    echo "smoke:run-net-bind-service-oci skipped (cached ${image_ref} rootfs not available)"
    exit 0
  fi
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "spore run OCI bound service lookup/fetch exited ${wget_rc}, expected 0"
fi

grep -Fxq "spore metadata ok" "${workdir}/wget.stdout" || {
  cat "${workdir}/wget.stdout" >&2 || true
  cat "${workdir}/wget.stderr" >&2 || true
  die "OCI bound service did not return the expected body"
}

echo "smoke:run-net-bind-service-oci ok backend=${backend} image=${image_ref}"
