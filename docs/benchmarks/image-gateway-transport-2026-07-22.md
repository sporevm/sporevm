# Image Gateway Transport Evidence — 2026-07-22

This evidence closes the G0 eager-transport decision without making the
benchmark batch framing part of the gateway protocol. Every reported case has
five samples, rotates mode order, verifies the complete object closure, and
uses 16-way bounded concurrency with persistent connections.

## Small S3 workload

[Buildkite build 310](https://buildkite.com/buildkite/sporevm-benchmarks/builds/310)
ran both target architectures from clean SporeVM commit
`0dcb113121443e410d7a89ca793f366d0551ba53` against S3 in
`ap-southeast-2`. Alpine 3.22 was the target and Alpine 3.23 supplied the real
overlap fixture. The related images shared one 64 KiB object on each
architecture.

| Platform | Mode | Cold median | Partial median | Cold response | Data requests |
| --- | --- | ---: | ---: | ---: | ---: |
| `linux/arm64` | objects | 1,270 ms | 1,312 ms | 9.93 MB | 150 |
| `linux/arm64` | archive | 319 ms | 313 ms | 4.24 MB | 1 |
| `linux/arm64` | batch | 473 ms | 465 ms | 9.94 MB | 1 |
| `linux/amd64` | objects | 853 ms | 868 ms | 9.67 MB | 146 |
| `linux/amd64` | archive | 331 ms | 354 ms | 3.92 MB | 1 |
| `linux/amd64` | batch | 512 ms | 514 ms | 9.68 MB | 1 |

No S3 trial retried. Batch composition had a 244–250 ms cold median because
the gateway still read every source object. The archive was both the smallest
response and the fastest end-to-end transport on each architecture.

## `buildkite-sporevm` workload

The workload pins Buildkite at
`e446c1b8a74d317a7abd08c42140152a5d9e8462` and applies the benchmark wrapper
at `ad8967125968098b917090e49b6410dd5a6b19c5`. The outer image embeds the
same saved dependency archives used by that wrapper. These trials use the
loopback gateway, so they measure closure shape, local staging, verification,
and composition; they do not predict object-store or wide-area latency.

| Platform | Closure payload | Objects | Archive | Related-image reuse |
| --- | ---: | ---: | ---: | ---: |
| `linux/arm64` | 4.81 GB | 73,458 | 1.59 GB | 1,142 objects / 74.8 MB |
| `linux/amd64` | 4.53 GB | 69,089 | 1.64 GB | 4,527 objects / 296.7 MB |

| Platform | Mode | Cold median | Partial median | Cold response | Partial response |
| --- | --- | ---: | ---: | ---: | ---: |
| `linux/arm64` | objects | 66.6 s | 55.7 s | 4.82 GB | 4.75 GB |
| `linux/arm64` | archive | 67.5 s | 63.0 s | 1.60 GB | 1.60 GB |
| `linux/arm64` | batch | 64.0 s | 57.3 s | 4.83 GB | 4.76 GB |
| `linux/amd64` | objects | 61.5 s | 51.7 s | 4.54 GB | 4.24 GB |
| `linux/amd64` | archive | 64.1 s | 59.4 s | 1.65 GB | 1.65 GB |
| `linux/amd64` | batch | 69.6 s | 48.9 s | 4.54 GB | 4.25 GB |

The local backend makes concurrent raw-object reads unusually cheap, so
objects or partial batches can beat gzip extraction by a few seconds. That
result does not survive the intended placement: the S3 trials include backend
request cost, and the large archive removes 2.9–3.2 GB from the client network
path. Real overlap saves only 1.6% of ARM64 payload bytes and 6.5% of AMD64
payload bytes, which is not enough to justify a dynamic batch protocol in G1.

AMD64 conversion and transport evidence is clean at
`7960d90f29c73ba90efb5fd2c38b1b2c6fb83c77`. Its direct-OCI medians were
118.0 seconds for the base and 143.5 seconds for the outer image. The ARM64
fixture was produced during the earlier `4daa59ba` harness iteration while
script-only changes were uncommitted; its final transport replay is clean at
`7960d90f`. The ARM64 conversion timings are therefore diagnostic only, not
exact-head acceptance evidence. Cross-architecture latency comparisons are
also invalid because both local workloads ran on the same ARM64 host.

## Decision

G1 should publish an immutable compressed archive as the eager bulk-transfer
accelerator. Per-object storage remains authoritative, and the
manifest-authorized single-object endpoint remains required for verification
and future lazy pulls. Archive layout and compression stay outside image
identity, so the accelerator is rebuildable and replaceable.

The benchmark-only batch framing remains outside protocol v1 and moves to G2
unless production telemetry shows substantially more reusable payload than
these related-image fixtures. G1 acceptance still has to measure the archive
through the authenticated service, including redirect, retry, and client
network behavior; this evidence chooses the implementation direction rather
than claiming production latency.
