# Experiments

Use this file for measured experiments that should be remembered. Each entry
should use this shape:

- Title: `## Adopted: ...`, `## Rejected: ...`, or `## Pending: ...`.
- Question: the thing the experiment tried to answer.
- Hypothesis: the expected mechanism or result.
- Method: enough detail to rerun it or find the artifact.
- Result: the measured outcome, including numbers when available.
- Decision: what to keep, reject, or try next.

Keep titles outcome-first so another agent can scan this file without reading
every paragraph.

## Adopted: Flat Artifact Base For Warm Resume (Trust-At-Open)

**Status:** shipped. Warm `run --from` TTI dropped about 5x on local HVF.

### Question

Why was warm `run --from` TTI (391ms median, CI profile, HVF,
`node:22-alpine`) three times slower than cold `spore run --image` (124ms),
when restore itself took only ~6ms?

### Hypothesis

Phase timings put the cost inside the guest: `node -v` took ~300ms in a
resumed guest versus ~15ms cold. `SPOREVM_ROOTFS_TRACE` showed the resumed
guest issuing ~7,000 4KiB virtio-blk reads served by `CasBlockSource`, with
487 chunk misses each paying a path alloc + `open()` + 64KiB read + BLAKE3 +
heap copy while the vCPU was blocked. Cold runs served the same reads with
plain preads on the flat cached ext4 fd. Preferring the flat digest-addressed
artifact as the COW base should recover cold-path read performance.

### Method

`mise run benchmark:ci` before and after changing `runtime_disk.open` to
prefer the flat by-digest artifact (trust-at-open: symlink-safe, regular
file, exact size; no re-hash) with CAS chunks as the fallback for chunk-only
pulls. Same host, same image, same profile.

### Result

Warm `warm_spore_tti/sequential` median 391ms -> 73ms; burst 453ms -> 78ms;
guest `node -v` in the resumed VM ~300ms -> ~22ms; cold TTI unchanged. This
also removed the historical full-file re-hash for spores without
`rootfs.storage` (previously ~3.35s for a 512MiB artifact on verify-on-open).

### Decision

Adopted, with the cache contract changed to verify-at-install,
trust-at-open (SECURITY.md). Install boundaries still verify all bytes;
user-supplied rootfs paths are always copied into the cache, never
hardlinked. After this change the next dominant warm-TTI slice is the
~15ms resumed vsock accept delay plus `spore` CLI process startup.

## Adopted: Trust-At-Open Managed Kernel Cache

**Status:** shipped. Cold `spore run --image` dropped ~20-25ms per run.

### Question

How much of the remaining cold-start host overhead was the managed kernel
cache hit path, which re-hashed the cached kernel image on every run?

### Hypothesis

`managedKernelCacheHit` ran a full SHA-256 of the 7.3MiB cached Image plus
sidecar reads on every cache hit, verified against a `.sha256` file in the
same cache directory — corruption detection, not tamper resistance, since an
attacker who can replace the kernel can replace the sidecar. Skipping the
re-hash should recover the cost with no security regression under the
verify-at-install, trust-at-open cache contract.

### Method

A/B on local HVF with a cached `node:22-alpine` rootfs: five `spore run`
cold runs with the default managed-kernel resolution versus five with
`SPOREVM_KERNEL_IMAGE` pointing at the same cached Image (which bypasses the
cache-hit verification entirely), then re-measure after removing the re-hash.

### Result

Baseline 70-80ms wall clock per cold run; bypass 50ms consistently. After
removing the re-hash, cold runs match the bypass at ~50ms across ten runs.
The config-symbol check stays on cache hits because the required symbol list
belongs to the running binary, which may demand more symbols than the binary
that installed the cache entry. Warm resume is unaffected: `run --from` never
resolves the managed kernel.

### Decision

Adopted. The kernel cache follows the same verify-at-install, trust-at-open
contract as the rootfs cache: download verifies the release checksum and
config symbols before atomically installing read-only files; cache hits check
shape (read-only, regular, no symlink) plus config symbols only.

## Rejected: Host-Side Hot Resume Handoff Optimizations

**Status:** recorded after the
[Substrate snapshot benchmark comparison](https://benchmarks.substrate.so/?view=snapshot).
Local RAM backing materially changed the hot-resume cost shape. The later
experiments did not improve median hot `run --from` TTI on the AWS dev KVM
host.

### Question

Can SporeVM close the remaining hot `run --from` gap to Substrate's public
[`substrate-mmap` snapshot numbers](https://benchmarks.substrate.so/?view=snapshot)
by changing host/guest handoff mechanics, rather than by assuming faster
hardware or benchmark-specific behavior?

### Adopted: Local RAM Backing Baseline

Hypothesis: RAM restore was the dominant warm path cost, and same-host local
RAM backing plus `MAP_PRIVATE` restore would move hot resume into the low-ms
range.

Result: supported. After local backing, the 2GiB AWS dev KVM benchmark showed
normal `spore run --from` at roughly:

| Metric | Median |
| --- | ---: |
| `spore_exec_response_ms` | 13 ms |
| `spore_backend_restore_to_reply_ms` | 17 ms |
| vsock connect/request delivery | 4-5 ms |
| guest accept-to-exit | 8 ms |

This made RAM restore no longer the dominant slice. The remaining gap to the
public Substrate `substrate-mmap` number, 8.881 ms in the benchmark data used
for comparison, is mostly in exec handoff and guest userspace work.

### Adopted: Resumed Vsock Port Readiness

Hypothesis: resumed children could stall or overpay because they reused a stale
host/guest vsock tuple from the parent.

Result: fixed correctness and attribution, not a new TTI step-change. The
durable fix was to derive resumed host ports from the request and emit reusable
debug timings for attach, connect, request delivery, first output, and response.
That made the residual cost measurable and removed a readiness failure class,
but it did not make hot resume match Substrate mmap timings by itself.

### Rejected: Child-Exit Wakeup As A TTI Lever

Hypothesis: the guest agent might sit in a polling sleep after the child exits,
so a signal-driven wakeup could cut response latency.

Result: useful cleanup, not a visible hot-resume breakthrough. The path is still
bounded by request delivery plus fork/exec/stdio/exit handling. Current same-host
hot `run --from` measurements stayed in the low-teens ms after this class of
change.

### Rejected: Preconnected Parked Vsock

Hypothesis: Substrate's warm path might avoid the connect/request handshake
entirely. Capturing a guest with an already accepted but parked vsock stream
should remove the 4-5 ms connect/request delivery slice.

Method: prototype only, behind `SPOREVM_EXPERIMENT_PRECONNECTED_VSOCK`. The
fresh capture sent a hidden park request, snapshotted the guest with the stream
open, and resumed by writing the real start request onto that restored stream.

Result: falsified. The host-side handshake disappeared, but total hot response
got worse on the AWS dev KVM host:

| Path | Median response | Comparable backend + reply | Connect/request delivery |
| --- | ---: | ---: | ---: |
| normal `run --from` | 13 ms | 17 ms | 4-5 ms |
| preconnected parked stream | 16 ms | 20 ms | 0 ms |

The prototype proved that connect/request delivery is not the dominant remaining
cost. Removing it exposed or added guest-side overhead, so this is not worth
landing as a product feature.

Artifacts from that run were uploaded under:

```text
s3://cleanroom-dev-apse2-arm-ap-southeast-2-724772075326/sporevm/remote-benchmark/sporevm-preconnected-20260626T115317Z
```

### Adopted: Timeout Knob For Operability

Hypothesis: slow dev hosts and larger fanout reproductions need a tunable resume
probe timeout.

Result: operationally useful, no performance claim. `--timeout` helps avoid
rebuilding for long or tight probe windows, but it does not reduce hot resume
TTI.

### Rejected: Agent-Ready Snapshot Point

Hypothesis: the current benchmark base is a completed session. Resuming from it
forces the agent through the completed-session path before starting the next
command. Capturing at "agent ready, no session" could avoid that baggage while
keeping `run --from` as a fresh-session contract.

Result: rejected by measurement before implementation, after the flat-artifact
rootfs change removed the disk-dominated warm cost. Phase timings on local HVF
(`node:22-alpine`, 512mb) show the guest-side window this experiment targets —
request accept through process spawn, including completed-session bookkeeping
and generation apply — is under 1ms. On a quiet host with settled forks, the
host vsock connect completes in 0-1ms and hot `run --from` lands around 30ms
backend elapsed, of which ~6ms is restore and ~22ms is the guest `node -v`
execution itself. Moving the snapshot point has nothing left to remove.

The 15-25ms "connect delay" that motivated this experiment reproduces only in
two transient conditions: the first resume after the host page cache has
evicted the flat rootfs artifact and RAM backing pages (a 20-minute-old fork
showed 161ms on its first resume and 32ms on an immediate second resume, and
fork itself only writes ~200KB per child — the backing is a hardlink), and
general host load. Neither is addressed by a different snapshot point.

### Decision

Do not build the agent-ready snapshot. The general-purpose hot-resume floor on
quiet hardware is ~30ms backend elapsed, dominated by restore (~6ms) and the
guest command's own execution. If first-resume-after-idle latency matters for
a real workload, the follow-up is page-cache readahead on the RAM backing and
rootfs artifact at restore, not vsock or snapshot-point mechanics. The
`spore resume` 25ms rx-delay workaround was subsequently removed: it existed to
paper over stale-vsock-tuple collisions from the fixed resume host port, and
deriving the resume host port from the request (as `run --from` already did)
removes the collision class the delay was guarding, along with the wake thread
and delayed-RX gating it required.
