# Docker inside a spore

Keep Docker's persistent state on the Spore-managed ext4 root disk. Use
`overlay2`, with `/var/lib/docker` as the data root. Put only the daemon socket,
PID, logs, and exec state under `/run`, which is tmpfs. Do not put
`/var/lib/docker` on tmpfs or attach an unmanaged host scratch disk: either
choice moves image and layer state outside SporeVM's portable rootfs snapshot
and CAS contract.

The source image in the examples is assumed to contain `dockerd`, the Docker
CLI, and their runtime dependencies:

```text
local/docker-capable:base
```

## Prepare a reusable image

Run Docker once, pull the fixed images and dependencies needed by the workload,
stop the daemon cleanly, and commit the resulting root disk:

```bash
spore run \
  --image local/docker-capable:base \
  --pull=never \
  --disk-size 20gb \
  --commit local/project-docker:prepared \
  --memory 4gb \
  --net \
  --allow-host auth.docker.io \
  --allow-host registry-1.docker.io \
  --allow-host production.cloudflare.docker.com \
  --allow-host production.cloudfront.docker.com \
  -- /bin/sh -lc '
set -eu
mkdir -p /var/lib/docker /run/docker
dockerd \
  --data-root=/var/lib/docker \
  --exec-root=/run/docker \
  --pidfile=/run/docker.pid \
  --host=unix:///run/docker.sock \
  --storage-driver=overlay2 \
  >/run/dockerd.log 2>&1 &
dockerd_pid=$!
cleanup() {
  kill -TERM "$dockerd_pid" 2>/dev/null || true
  wait "$dockerd_pid" 2>/dev/null || true
  sync
}
trap cleanup EXIT INT TERM

ready=0
for attempt in $(seq 1 60); do
  if docker --host unix:///run/docker.sock info >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
test "$ready" -eq 1
test "$(docker --host unix:///run/docker.sock info --format "{{.Driver}}")" = overlay2

docker --host unix:///run/docker.sock pull \
  docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

trap - EXIT INT TERM
cleanup
'
```

Replace the pinned image and network allowlist with the workload's registry
and fixed dependency set. Keep the readiness deadline and clean shutdown: an
unbounded daemon command never reaches commit, and abruptly killing `dockerd`
leaves application state for filesystem freeze to capture without an
application-level quiescence guarantee. The destination ref changes only when
the command exits zero and disk publication succeeds.

`--disk-size` is an absolute logical size. Growth is sparse, but data written by
Docker is not. Current v2 indexes pack contiguous chunk digests and zero ranges,
so snapshot capacity no longer pays for one JSON object per dense 64 KiB chunk;
a dense 32 GiB disk is covered by focused tests. Index bytes remain bounded, so
start with 20 GiB and increase it only when measured use requires more. The
memory setting is separate: `--memory` sizes guest RAM, not
Docker storage. Four GiB is a practical starting point for the daemon plus
small builds; larger builds need a larger value. A saved runtime captures that
RAM as well, so oversizing memory increases save, transfer, and restore work.

## Start runtimes from the prepared disk

An independent runtime can start directly from the committed image without
registry access:

```bash
spore run \
  --image local/project-docker:prepared \
  --pull=never \
  --memory 4gb \
  -- /bin/sh -lc '
set -eu
mkdir -p /var/lib/docker /run/docker
dockerd \
  --data-root=/var/lib/docker \
  --exec-root=/run/docker \
  --pidfile=/run/docker.pid \
  --host=unix:///run/docker.sock \
  --storage-driver=overlay2 \
  >/run/dockerd.log 2>&1 &
dockerd_pid=$!
cleanup() {
  kill -TERM "$dockerd_pid" 2>/dev/null || true
  wait "$dockerd_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
for attempt in $(seq 1 60); do
  docker --host unix:///run/docker.sock info >/dev/null 2>&1 && break
  test "$attempt" -lt 60
  sleep 1
done
docker --host unix:///run/docker.sock run --rm \
  docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc \
  /bin/echo ready
'
```

For low-latency fan-out, boot `dockerd` once, wait until it is ready, signal the
host `spore` process to save the running machine, then fork it offline:

```bash
spore run \
  --image local/project-docker:prepared \
  --pull=never \
  --memory 4gb \
  --save docker-base.spore \
  --save-on TERM \
  -- /bin/sh -lc '
set -eu
mkdir -p /var/lib/docker /run/docker
dockerd \
  --data-root=/var/lib/docker \
  --exec-root=/run/docker \
  --pidfile=/run/docker.pid \
  --host=unix:///run/docker.sock \
  --storage-driver=overlay2 \
  >/run/dockerd.log 2>&1 &
for attempt in $(seq 1 60); do
  docker --host unix:///run/docker.sock info >/dev/null 2>&1 && break
  test "$attempt" -lt 60
  sleep 1
done
echo docker-ready
wait
' >docker-base.log 2>&1 &
spore_pid=$!

for attempt in $(seq 1 60); do
  grep -q docker-ready docker-base.log && break
  test "$attempt" -lt 60
  sleep 1
done
kill -TERM "$spore_pid"
wait "$spore_pid"

spore checkpoint fork docker-base.spore --count 4 --out docker-children/
spore run --from docker-children/000000 -- /bin/sh -lc \
  'docker --host unix:///run/docker.sock run --rm \
    docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc \
    /bin/echo child-ready'
```

Each child gets its own writable disk head over the same committed rootfs and
shared CAS chunks. `spore run --from` resumes the saved daemon and starts a
fresh command in that child. `spore fanout` instead resumes only the saved
process session; use it when that session itself owns the work and has an
after-restore identity barrier described in [Fan-Out](fanout.md).

## What is captured

`--commit` captures the root disk only. It includes Docker images, layers,
volumes, and other bytes under `/var/lib/docker`. It does not include guest
memory, processes, vCPU state, network state, `/run/docker.sock`, PID files, or
other tmpfs state. The output is a normal local Spore image whose unchanged
chunks share the source image's CAS storage. This keeps the disk backend-neutral
and suitable for offline reuse; warm machine state remains the separate
save-and-fork layer.

Local image refs and their CAS objects remain local cache state and are not
pushed to an OCI registry. To move the prepared disk without guest memory or
other suspended state, export it with `spore image pack`, transport the archive
as an immutable artifact, and import it with `spore image unpack` on the target
architecture. The receiver can then use the resulting ordinary local ref with
`spore run --image local/... --pull=never`. Use the separate saved-machine
`spore pack`/`push`/`pull` workflow only when the receiver needs RAM, vCPU,
device, or process state and has a compatible backend and host class.

Remove disposable child and spore directories when finished, then inspect
cache cleanup before forcing it:

```bash
rm -rf docker-children/ docker-base.spore
spore system prune --rootfs --dry-run
spore cache gc --rootfs --dry-run
```

Use the corresponding `--force` forms only after confirming that no retained
local image, spore, build record, or active runtime still roots the data.
