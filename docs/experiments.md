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

Result: operationally useful, no performance claim. `--timeout-ms` helps avoid
rebuilding for long or tight probe windows, but it does not reduce hot resume
TTI.

### Pending: Agent-Ready Snapshot Point

Hypothesis: the current benchmark base is a completed session. Resuming from it
forces the agent through the completed-session path before starting the next
command. Capturing at "agent ready, no session" could avoid that baggage while
keeping `run --from` as a fresh-session contract.

Smallest experiment: add a hidden ready request that validates rootfs/network
readiness, returns success, closes the client, and leaves `session` untouched.
Then reuse the existing snapshot-on-probe-complete backend path. The only extra
care is ensuring the host observes client close before snapshotting, so the
guest is not captured halfway through the ready RPC.

Expected readout: if this still lands around 12-13 ms, the remaining gap is
probably the guest fork/exec/userspace path rather than snapshot restore or
vsock setup.

### Decision

Do not keep optimizing the host-side vsock connect path unless a new profile
shows it has become dominant again. The useful next experiment is the
agent-ready/no-session snapshot point. If that fails to move the median, focus
on guest process startup mechanics or accept low-teens ms as the current
general-purpose hot-resume floor.
