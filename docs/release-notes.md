# Release Notes

## Next

`spore build` now keeps large accepted COPY heredocs cacheable. Step-record
publication and both record readers share a 16 MiB bound, so a record larger
than the previous 256 KiB read cap can be reused by a warm build and inspected
as a normal GC root instead of becoming a perpetual miss and an unknown
conservative record. The bound is inclusive: the shared reader reserves one
extra byte as its overflow sentinel, so an exact 16 MiB record remains readable
while the writer rejects anything larger before atomic replacement.

Image-backed named VMs now retain OCI `Config.Env` and `WorkingDir` for the
detached create command and every normal, interactive, and TTY exec. `spore
exec` accepts repeatable `--env KEY[=VALUE]` and `--workdir PATH` overrides;
the existing run precedence applies, including `KEY=` replacing an inherited
value with an empty value. Image defaults persist through live forks, named
save/restore, offline forks, and bundle transport as bounded optional
`exec_defaults` manifest metadata, while per-exec values remain request-local
and are never saved as lifecycle or manifest metadata.

Named VM startup now waits five milliseconds between monitor-readiness attempts
during the normal startup window, after ten initial one-millisecond waits. The
previous twenty-millisecond cadence was a material and variable part of fast
local-backed restores, so the public restore-to-ready latency could miss the
release's two-times eager/local speedup floor even though RAM materialization
was correctly eliminated. Longer failures return to the existing
twenty-millisecond cadence; the timeout, PID validation, versioned monitor
hello, and failure diagnostics are unchanged.

`spore rm --spore` now removes disk-backed spores produced by `spore unpack`
or `spore pull`. These portable spores carry their authoritative disk index
inside the directory and do not have a host-private durable pin, so removal
deletes and syncs the self-contained directory while reporting
`pin_removed: false`. Machine-local disk-backed saves retain the existing
validate-delete-sync-unpin ordering, and an unpinned disk manifest without a
verified complete local authority still fails closed without deleting the
directory. Portable removal also fails closed while a foreground or named
restore owns the directory for lazy disk reads.

`spore build` now accepts context-form `COPY --parents[=true|false]` with
multiple regular-file, directory, and glob sources. The true form reconstructs
each selected source's cleaned root-relative path below the destination,
including destinations resolved from inherited `WORKDIR`; false retains
ordinary context COPY behavior. Source order, resolved roots, destination,
captured modes and bytes, environment state, parent rootfs, and executor
identity remain typed cache inputs, while the existing immutable context disk
and COPY v4 request retain confinement and checkpoint behavior. Ordinary COPY
keeps its existing overwrite rules, while the parents synthetic tree rejects
root and nested non-directory conflicts without replacing them. The
context-root operands `.` and `./`, internal `/./` source
pivots, `--from`, `--link`, heredocs, and all other flag compositions remain
fail-closed. Spore deliberately keeps its
existing deterministic Unix-epoch timestamps for ordinary context COPY, so it
differs from BuildKit's source-mtime transport metadata; mtime-only source
changes still hit the semantic COPY result, and the frozen Buildkite workload
does not read those mtimes.

`spore build` now accepts expanded explicit `id` and
`sharing=shared|locked` on bounded `RUN --mount=type=cache` declarations.
Explicit and omitted IDs both select digest-named subdirectories inside the
existing single 4 GiB aggregate disk, so raw IDs never become host paths and
equal resolved IDs share storage. Both sharing modes are conservatively
serialized by the aggregate lock and the existing whole-build cache lock;
Spore does not provide BuildKit's concurrent shared-writer scheduling. Result
caching matches BuildKit v0.30.0's value-based asymmetric contract: cache
options remain in identity only when a shared ID equals the resolved target;
other ID and sharing values are cleared. An explicit equal-target ID therefore
behaves like the historical absolute omitted-ID case, while an omitted relative
target joined to `WORKDIR` is cleared. Cache contents remain
outside rootfs snapshots and portable manifests, fully cached builds do not
open the aggregate, and unsupported sharing modes or contradictory same-ID
declarations fail during full-plan semantic preflight.

`spore build` now accepts default read-only context-file bind mounts on
ordinary shell-form RUN, such as
`RUN --mount=type=bind,source=Gemfile,target=Gemfile ...`. Source and target
expand from the instruction-start snapshot; sources must resolve through
`.dockerignore` to one literal regular file, and relative targets resolve under
`WORKDIR`. Ordered normalized paths, source mode, and actual BLAKE3 content are
RUN cache inputs. Misses reuse the existing immutable context capture and
read-only context disk, while the strict v4 RUN request exposes only selected
files inside the operation-owned sandbox. Missing or symlinked sources,
directories, special files, writable/custom binds, stage/image/named-context
sources, overlapping targets, and broader mount options fail closed before
execution.

Bind source mtime follows BuildKit's split contract. A race-checked captured
mtime selects the v2 context-disk transport identity, but mtime is excluded
from semantic RUN cache identity. An mtime-only edit can therefore reuse the
prior RUN result; a later miss observes the new nanosecond value. Context disks
without captured mtime retain v1, while ordinary COPY/ADD entries and
rootfs/import emission retain their existing deterministic zero-timestamp
behavior and identities.

Bind mounts and setup-owned target scaffolding are removed before every rootfs
checkpoint, so the transport inode and mountpoint never enter the snapshot;
ordinary files that RUN writes from bind data remain persistent output.
Existing regular-file targets are restored unchanged, while owned absent-target
scaffolding is removed only while empty so ordinary sibling rootfs content is
preserved. Root targets, trailing-slash targets, and targets overlapping
`/proc`, `/dev`, `/sys`, `/run/sporevm`, `/run/buildkit`, or
`/etc/resolv.conf` fail during planning, including protected ancestors and
descendants. Unmount failure, target replacement, or unverifiable ownership
poisons the build session and prevents step, cache-record, and destination-ref
publication. The accepted form composes with optional-absent SSH and default
cache mounts, but adds no writable bind, credential, device, manifest,
stage-input, or generic mount authority.

`spore build` now accepts one exact default `RUN --mount=type=ssh`
declaration when no SSH input is supplied. This is optional-absent syntax and
result compatibility, not forwarding support: the RUN receives BuildKit's
inert `SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` value only when its effective
environment did not already define the key, while no socket or
`/run/buildkit` path is created. The typed absent declaration and resolved
environment are cache inputs, and a command that requires the agent fails
normally without publishing the failed step. Options, duplicates, required or
custom sockets, host inputs, secrets, and every credential-bearing SSH form
still fail during full-file planning. No guest protocol, device, manifest,
credential broker, CLI option, or durable secret state is added.

`spore build` now accepts one unquoted, non-chomping RUN heredoc as the complete
command after optional default cache mounts, for example `RUN <<EOF`. A
non-empty body without NUL or a leading shebang is preserved byte-for-byte,
including its final newline, and executes through the existing `/bin/sh -c`
path. Dockerfile ARG/ENV values, quotes, escapes, unset variables, and parameter
operators therefore retain ordinary guest-shell behavior rather than COPY-style
builder expansion. Exact canonical body text, effective environment, workdir,
network, resources, ordered normalized cache mounts, parent rootfs, and executor
identity remain cache inputs, while the existing per-instruction timeout and
RUN sandbox own execution and cleanup. Shell-prefix, quoted, chomping, multiple,
empty, shebang/direct-exec, and exec-form heredocs still fail during full-file
parsing. The accepted form reuses the existing shell v1/v3 request and does not
add a guest protocol, credential-bearing input, device, or manifest field.

`spore build` now accepts a single unquoted, non-chomping COPY heredoc source,
for example `COPY <<EOF /etc/example`. The body keeps its final newline and
literal quote bytes while builder-owned ARG and ENV expansion follows the same
instruction-start snapshot, unset-to-empty behavior, stable parameter
operators, and escape handling as other COPY operands. The resolved bytes are
BLAKE3-addressed as a root-owned `0644` regular file in the existing immutable
context disk, and the normal strict COPY v4 path applies it, so exact-file,
directory-destination, conflict, checkpoint, and cleanup behavior stay shared
with context COPY. The delimiter supplies the filename when the destination is
a directory. The canonical source, delimiter, resolved content digest,
destination, workdir, environment state, parent rootfs, and executor identity
remain cache inputs. Quoted or tab-chomping delimiters, multiple or mixed
sources, and heredoc COPY flags still fail during full-file parsing.

`spore build` now matches Docker's frontend behavior for continued tokens,
bracket-prefixed shell commands, parent-relative `WORKDIR`, and step timeouts.
Removing a line-continuation escape no longer inserts a space, so identifiers
and COPY source names may continue across physical lines without changing.
`RUN`, `CMD`, and `ENTRYPOINT` text beginning with `[` falls back to shell form
when it is not valid JSON, while valid JSON arrays containing non-string values
still fail closed. `WORKDIR ..` and other parent components normalize within
the guest root, while COPY paths retain their stricter rejection of parent
segments. The build timeout now applies independently to each Dockerfile
instruction; multi-request COPY operations share one instruction budget, and
aggregate instruction timing remains available in build diagnostics.

Every `spore build` RUN now executes in an operation-owned Linux isolation
view. Shell and exec forms retain their existing environment, workdir, stdio,
networking, exit, and rootfs behavior, while a private PID and mount view gives
the command a scoped procfs and a fresh minimal `/dev`. The initrd and agent
namespace are unreachable through `/proc/1/root`; BuildKit-compatible
read-only and masked proc paths prevent guest-global sysctl mutation and hide
sensitive kernel pseudo-files. Auxiliary context and stage virtio disks plus
the VM console have no device nodes. A cgroup device
policy rejects raw access through attacker-created aliases. The seccomp filter
rejects `socket` and `socketpair` with `AF_VSOCK`, and rejects
`io_uring_setup` entirely, so io_uring is unavailable inside build RUNs and
cannot create an asynchronous path to the agent or host control transport.
Ordinary IP networking stays unchanged. The command receives the pinned
BuildKit default capability set, and namespace destruction plus cgroup
kill-and-empty verification owns cleanup before checkpoint publication.
Secret/SSH forwarding, new device types, and manifest changes remain
unsupported.

`spore build` accepts one or more `RUN --mount=type=cache,target=...`
mounts. The original default form omits `id` and `sharing`; its target expands
from the
instruction-start ENV/ARG snapshot; BuildKit's default ID is
`path.Clean(expanded target)`, so repeated separators, dot segments, and a
trailing slash share one persistent host-local directory. Relative targets are
mounted below `WORKDIR` while retaining their cleaned relative default ID.
Cache bytes persist across steps, failed RUNs, and later builds, but the mount
and any target directories created for it are removed before every rootfs
checkpoint. If a RUN writes ordinary rootfs content beside a nested cache
target whose parent was created for the mount, that nonempty parent and its
content remain in the checkpoint while the mountpoint and cache bytes do not.
A single 4 GiB sparse aggregate ext4 cache disk and exclusive host lock
serialize default shared writers conservatively without changing the portable
device or manifest contracts. Cache contents do not enter RUN result-cache
identity. Ordered targets remain semantic inputs, while ID and sharing are
retained only for BuildKit's shared value-equals-resolved-destination case and
canonicalized away otherwise. Each RUN accepts at most eight mounts; current
`spore rootfs df`, prune, and GC do not account for or remove the aggregate.
Builds that also need a context disk and two stage-input disks fail before
execution because the frozen eight-device envelope has no cache-disk slot.
Nested or duplicate targets, `sharing=private`,
writable/custom/directory or non-context bind mounts, exec-form or heredoc RUN
combinations, tmpfs/secret mounts, and
credential-bearing SSH mounts remain unsupported.

`spore build` now accepts numeric `--chmod` on the public HTTPS single-file
`ADD` form. Octal values from `0` through `07777`, including ARG-expanded and
leading-zero spellings, apply to the downloaded regular file; the default
remains `0600`. The resolved mode participates in ADD cache identity, while
the existing strict COPY v4 request and confined guest copy path preserve mode,
destination-conflict, and `Last-Modified` behavior. Empty, malformed,
duplicate, out-of-range, and symbolic values fail closed before the ADD GET.
Local ADD, archive extraction, COPY chmod, credentials, Git, and SSH forwarding
remain unsupported.

`spore build` now accepts `COPY --link` for immutable cross-stage and named
build inputs. True link policy builds the destination result without reading or
following lower destination symlinks, replaces lower file/directory conflicts,
and merges matching directories, so the flattened ext4 result matches pinned
BuildKit even though Spore conservatively keeps the current parent in its cache
key. `--link=false` retains ordinary cross-stage COPY behavior. Source-stage
operands follow a rootfs-confined final symlink, while symlinks encountered
inside a copied directory remain symlink entries, matching BuildKit. Source-stage
rootfs identity, resolved operands, instruction-start ENV/ARG state, workdir,
platform, parent rootfs, executor identity, and the explicit destination policy
are cache inputs; changed source-stage bytes miss while unchanged rebuilds hit.
The strict guest v5 request accepts link policy only from bounded immutable
build-input disks, and conflict removal shares COPY's 65,536-entry limit.
Local-context `--link`, COPY `--chmod`, `--parents`, non-single-source COPY
heredocs, OCI layer rebasing, and credential-bearing SSH remain unsupported.

`spore build` now accepts one public HTTPS URL and one destination in `ADD`.
The builder resolves both operands from the instruction-start ENV/ARG snapshot,
including automatic `TARGETOS` and `TARGETARCH`, then performs a fresh host-side
GET on every build. Every request and redirect is re-resolved through the
public-address policy; URI userinfo, HTTP downgrades, Git sources, fragments,
non-success responses, excessive redirects, encoded responses, and over-budget
bodies fail closed. The URL scheme and authority are literal; only its
path/query and the destination expand. The builder sends no `Authorization`
header and does not consult host credential stores; requested query strings and server-provided HTTPS redirect
targets remain URL data. A build accepts at most 64 remote ADD instructions,
1 GiB of combined response bodies, and ten minutes of combined host-fetch time
or the smaller build timeout. The downloaded bytes are staged privately, synced, and
BLAKE3-hashed before cache lookup. ADD keys bind the resolved URL and
destination, safe response `Content-Disposition` filename or URL-path fallback,
downloaded content digest, resolved numeric mode (default `0600`), platform,
validated `Last-Modified` timestamp, ENV/ARG state, parent rootfs, and executor
identity, so unchanged bytes may reuse downstream work while changed mutable
content or metadata misses. A valid HTTP-date is applied as the destination
mtime through the confined guest COPY path; absent or malformed dates use the
Unix epoch, as they do in BuildKit. Remote archives remain opaque files. ADD
flags other than numeric `--chmod`, symbolic modes, local sources, Git, ambient
authentication, archive unpacking, and heredocs remain unsupported.

`spore build` now resolves builder-owned variables with Docker-compatible
instruction-start snapshots, quote and escape handling, unset-to-empty
behavior, and the stable `:-`, `-`, `:+`, and `+` parameter operators. The
selected platform supplies automatic BUILD/TARGET platform args, including
`TARGETOS` and `TARGETARCH`; a stage still declares an automatic arg before
using it. FROM, ARG defaults, ENV, COPY source/destination operands, and WORKDIR
use the shared resolver; `COPY --from` remains literal. Shell-form RUN remains
guest-shell text and exec-form RUN remains exact literal argv.
Expansion-capable operands retain their original parser spelling,
malformed or unsupported modifiers fail during full-file parsing, and resolved
COPY/WORKDIR inputs plus their instruction-start ENV/ARG state remain cache
inputs. The environment-state digest has a new identity so records produced by
the older quote-stripping resolver miss safely. Expansion depth, individual
resolved words, and aggregate variable state are bounded and fail with the
responsible Dockerfile line before executor startup.

`spore build` now accepts bounded exec-form `RUN` JSON arrays. It executes the
decoded argv directly, preserves spaces, empty arguments, quotes, and literal
`$NAME` text, and searches absolute entries in the effective build PATH when
the executable contains no slash. Empty PATH and relative matches fail closed,
matching BuildKit. PATH lookup now selects the first executable candidate
before one execution attempt, so a missing shebang interpreter fails the step
instead of falling through to a later program, while lookup-time errors such
as a symlink loop remain skippable. ENV and ARG state, workdir, network,
resources, parent
rootfs, exact instruction text, and the embedded executor identity remain cache
inputs, so a changed argv or effective environment misses while an unchanged
rebuild hits. Duplicate inherited environment keys now follow runc's
last-value-wins rule before the effective RUN environment is hashed or sent to
the guest, including PATH selection after later Dockerfile `ENV` updates in the
current stage. Raw entries retain their Docker-compatible order in the
published OCI config, and a later `FROM` reconstructs its effective environment
from that published list just as BuildKit does. Inherited entries that are bare
empty strings, have an empty `=value` name, or contain an embedded NUL now fail
before RUN cache lookup or executor startup. Matching the pinned path, nonempty
entries without `=` become empty-valued `NAME=` entries in the effective
environment without rewriting OCI config. A bare inherited `PATH` is therefore
authoritative as an empty PATH and does not receive the conventional default.
Malformed, empty, NUL-containing, or oversized arrays fail during full-file
parsing before a build VM starts. The versioned guest request also requires its
exact fields once and rejects aliases, unknown fields, trailing commas, and
trailing non-whitespace bytes. It now requires its framing newline. The shared
guest request boundary rejects full-buffer truncation and duplicate top-level
type keys for every request kind, validates raw UTF-8 in JSON strings, and
decodes Unicode escapes and valid surrogate pairs to UTF-8 so raw and
equivalently escaped JSON produce identical argv bytes. Shell-form RUN remains
`/bin/sh -c`; only the later narrow single-body RUN heredoc and bounded default
cache mounts extend that form.

Cold OCI base imports no longer scan the complete merged filesystem for every
regular-file replacement. The importer keeps per-inode hardlink reference
counts and removes non-directory paths directly, preserving source lifetime
and directory-subtree semantics while avoiding quadratic work in overwrite-
heavy layers. Opt-in rootfs profiling now reports each OCI layer separately,
and build output splits executor session time into guest instructions,
snapshots, checkpoint control, and remaining overhead.

Named saves now seal independent dirty disk chunks across at most eight workers
and fsync the shared object directory once before publishing the canonical
index. In the controlled scale-100 pgbench workload, median source pause fell
from 38.46 seconds to 18.30 seconds and median disk publication from 36.88
seconds to 16.79 seconds. Zero-length overlay reads and writes now report
unexpected EOF or a short write instead of logging them as success.

Distribution pulls now publish bytes already verified from portable storage
without rereading or rehashing them, and incomplete or invalid completed host
cache entries are repaired durably before reuse. For the fixed 2,621-object
Node 22 Alpine benchmark bundle, profiled median pull time fell from
approximately 3.94 seconds to 1.82 seconds.

Compatibility: the host-local builder cache ABI advanced from v7 in v0.13.1 to
v9. Complete v6, v7, and v8 records remain conservative GC roots, but the first
v9 build misses them and writes new v9 records; existing rootfs indexes and
local images remain readable. `SPORE_ABI_VERSION` remains 15, and no portable
spore, device, or manifest format changed after v0.13.1.

Bounded named exec now has a documented lossless JSON representation for
arbitrary stdout and stderr bytes. Valid UTF-8 remains a JSON string, while an
invalid UTF-8 stream is emitted as an integer byte array; Zig, C, and Go callers
therefore preserve exact output without changing existing valid-text results.

`spore build` now supplies the conventional `HOME=/root` process environment
to root `RUN` steps when the effective HOME is absent or empty. This matches
Docker/BuildKit for tools such as Go that require a cache home. Explicit
non-empty HOME values remain authoritative; `ENV HOME=` remains empty in the
published OCI config while root `RUN` receives `/root`. ENV and ARG follow
Dockerfile instruction order for build execution without publishing ARG.
Affected RUN cache keys include the effective value, so records produced by the
older environment contract miss safely; HOME normalization does not affect
COPY or WORKDIR identities. Stages without PATH also receive and publish
BuildKit's conventional Linux PATH, including `FROM scratch`. Explicit PATH
values remain authoritative in the published config, while later ARG values
affect only subsequent build-time state according to Dockerfile instruction
order.
The stage PATH participates in RUN, COPY, and WORKDIR cache identities, so older
records created without it miss safely. Build help also lists the existing
memory, vCPU, timeout, and `nofile` controls, and missing Dockerfiles, contexts,
or base inputs receive a concrete diagnostic instead of a bare `FileNotFound`.

Named persistent restore now uses the same proof-gated local RAM backing as
one-shot `spore run --from` and attach. Restore selection is centralized across
KVM and HVF, and the plan owns the backing fd until the private mapping has been
created. Optional missing, stale, foreign, non-regular, or mismatched backing
inputs still fall back to verified chunks, while malformed authoritative
metadata, allocation failure, unexpected I/O, corruption, and backend or
platform failures remain errors.

Named monitor timing now separates backend RAM, machine-state, and pre-run
restore work from vsock request delivery, connect, guest response, and ready
publication. The named-restore benchmark consumes those structured fields, so
a proof fallback cannot be mistaken for a slow guest readiness handshake.

Linux proof creation now measures existing fs-verity state before changing
permissions. New owned read-only backings temporarily regain owner-write only
for enablement, then restore their exact mode and stable device, inode, owner,
and size before a schema-v2 proof can be published. The proof binds the
post-enable mtime and digest after an exact re-stat; failure leaves chunks
authoritative.

Named monitors now advance host-side vsock ports from a random per-process
offset for readiness and every control stream. Completing a stream also drops
queued packets for its old four-tuple before the next attach, preventing stale
credit or control traffic from crossing into a repeated named exec.
Multi-vCPU HVF and KVM now dispatch completed hypervisor exits before handling
concurrent network wakes, so virtio MMIO operations cannot be dropped and
re-executed while the guest is inside an interrupt handler. After multi-vCPU
HVF delivers a host vsock request and raises its SPI, it exits the running vCPUs
once so an idle guest observes the interrupt promptly; empty polls do not wake.
Multi-vCPU HVF capture and restore also use one shared virtual-counter authority
for every vCPU. Per-vCPU timer deadlines are translated into that counter domain
with wrapping arithmetic, preventing cross-CPU time skew from surfacing as RCU
stalls after restore while preserving enabled, masked, and expired timers.

Named lifecycle console paths are now optional and truthful. Ready, list,
result, and failure output report a path only when `--console-log` is configured,
and restore ignores console paths embedded in saved lifecycle metadata so
an input spore cannot select or truncate an arbitrary host file.

The named-restore release harness pins v0.12.0 archives and managed-kernel
assets by digest and requires an exact clean current commit on Linux ARM64/KVM
and macOS ARM64/HVF. Its five-row matrix separates correctness from
performance, covers one- and two-vCPU local backing plus deliberate eager
fallback, requires zero reported
RAM materialization on every valid local-backing row, and retains the measured
eager materialization cost. It also records proof-write and validation timing,
fan-out validation, Linux fs-verity v2, tmpfs v1, cross-filesystem fallback,
and signal-safe named cleanup in a path-sanitized evidence artifact. The Linux
release lane ignores the general benchmark scratch and requires a dedicated
host-provisioned ext4 path that passes an fs-verity enable-and-measure
preflight before parent capture.

Fork now retains the proven parent backing fd across child creation and checks
each opened child hardlink against the proof-bound parent file identity before
writing a child proof. Path replacement, identity mismatch, and unexpected I/O
remove the link and fail closed. KVM and HVF continue to map every child with
`MAP_PRIVATE`, so parent and sibling writes remain isolated.

The additive saved-spore removal Zig/C/Go API raises the libspore C ABI version
to 15. Clients can compare
`spore_build_info(SPORE_BUILD_INFO_ABI_VERSION, ...)` with `SPORE_ABI_VERSION`
before using `spore_remove_saved_json`.

`spore rm --spore DIR` now removes valid diskless single- and multi-vCPU saves
as well as disk-backed saves. Text and JSON results distinguish the diskless
case instead of inventing a pin identity; the existing disk-backed
validate-delete-sync-unpin ordering is unchanged.

Writable-disk saves now reference the machine's global rootfs CAS through an
opaque durable pin in host-private lifecycle metadata. In the cache-backed
steady state, where the parent is already in the global CAS, saves no longer
hardlink or copy every unchanged parent object, remain valid after directory moves, and
survive rootfs GC and destructive prune. Raw moves are supported, but raw copies
share one pin identity and are not independently removable; removing one may
invalidate the others. Use fork for an independent machine-local lifecycle or
pack/unpack for portability. Raw deletion safely leaks a pin. `spore cache pins` lists IDs and
canonical-index health but does not detect orphans; expert-only
`spore cache unpin PIN_ID --force` removes a known ID with an explicit warning.
This pre-1.0 contract adds no global reference registry. `spore pack` still
copies and verifies every required index and object into a self-contained
portable bundle.

Indexed unpack and pull now retain descriptor-bound chunked rootfs authority
inside the output spore while populating the selected host cache from the same
verified object reads. A fresh host can reinstall that local CAS into an empty
cache; an exact index-valid, complete host cache remains the trusted warm-open
path. `spore pack` continues to deep-verify a present local rootfs CAS, so host
cache state cannot mask loss of the spore's claimed self-containment.

On exact-head KVM and HVF runs using the pinned Node arm64 base, the first save
after portable restore migrated 2,621 verified objects / 171,769,856 bytes and
all four later saves migrated zero. KVM measured a 4,688 ms first-migration
source pause versus 4,562–4,566 ms steady; HVF measured 2,808 ms versus
2,029–2,044 ms. The independent empty-cache product pack, fresh named restore,
five-save sequence, and public saved-spore cleanup all completed on both
backends. These results are separate from the earlier augmented dense 1 GiB
same-/cross-filesystem export fixture.

Offline pinned-disk fork results now report cache-lock wait separately from the
lock-held pin and batch publication interval in human output, JSON, and
`libspore.ForkResult`.

Save publication durably orders writable-disk objects, the canonical index,
and its completeness stamp before publishing the pin and save. A named VM can
therefore continue after its first save is removed and collected, publish a
second save, restore it, and fast-fork the restored VM from that exact new
baseline. The continuing VM's active lease and durable registry spec move to
that baseline before the old lease is released, so a failed handoff retains the
old authority instead of persisting a split view.

Named saves now acquire the global cache lock before pausing vCPUs. A contended
save remains pending while the guest runs, reports the accumulated lock wait
separately, and starts its measured source-pause interval only after acquiring
the lock that spans capture and durable publication.

Offline fork output remains batch-owned: children share RAM chunks through
batch-relative `../shared-chunks` links. The complete batch may be moved, but
an individual child directory is not independently movable; pack/unpack is the
portable per-child boundary.

`spore fork --vm` now fast-forks disk-backed named VMs with one writable rootfs
device. The source monitor pauses once, drains virtio-blk, captures shared
RAM/machine state, and prepares up to 32 independent disk heads from the same
epoch without sealing dirty disk state. APFS clone and Linux `FICLONE` are the
default path when the live head has physical overrides; native-clone failure is
closed unless the caller explicitly uses `--allow-slow-copy`. When a successful
save has committed the exact canonical baseline and no later overrides exist,
children receive fresh sparse heads without a filesystem clone or slow-copy.
The `sparse` clone method is private runtime descriptor metadata, not a durable
spore-format change. Networked named fork remains unsupported.

Fork children claim their unlinked overlay fd through a random, one-use,
child-bound local token and do not publish readiness until they have reopened
the immutable baseline and adopted the disk head. Durable baseline leases keep
live children valid after source removal and destructive cache GC/prune, and
children can fork again or save/restore normally. `spore --json fork` and
`libspore.NamedForkResult` report RAM capture, disk preparation, source pause,
and child readiness phases separately. Monitor-generated guest session IDs now
include a per-process random nonce, preventing a restored or forked guest from
replaying a source monitor's cached first exec response.
Writable overlays and lazy sparse rootfs bases now follow absolute `TMPDIR`,
so Linux hosts can place the fast-fork path on reflink-capable scratch storage;
child adoption rejects a head from a different filesystem before readiness.

`spore build` now prepares small root filesystems to a fixed sparse 16 GiB
capacity without recursive growth or user tuning. The host appends known-zero
chunks, a transient growth VM negotiates virtio-blk `WRITE_ZEROES`, and the
managed initrd calls `EXT4_IOC_RESIZE_FS` directly; capacity preparation no
longer invokes the selected image's shell or needs e2fsprogs/`resize2fs`.
Builder-v7 stores this normalization as a typed `PREPARE` derivation, so
unrelated Dockerfiles and `--no-cache`
builds reuse it while ordinary Dockerfile cache semantics remain unchanged.
RUN/COPY/WORKDIR keys bind the same exact executor kernel/initrd identity.
Managed-default cache hits avoid kernel/initrd body reads; a miss verifies and
boots the same once-opened kernel bytes, while explicit overrides are eagerly
retained. This prevents cross-producer cache reuse or artifact-path races after
a PREPARE hit.
Old build records miss once but remain conservative GC roots; old rootfs
indexes and local images stay readable. There is no build capacity knob in
this version: 16 GiB is both the automatic target and cap because the next
useful quantum is not safe for a fully dense index under the current 64 MiB
canonical-index limit.

`spore build` now supports ordinary multi-stage Dockerfiles with named and
numeric earlier-stage references, target pruning, `scratch`, public/local/OCI
bases, named OCI-layout build contexts, OCI config inheritance, and literal
`COPY --from`. Immutable source stages are attached as bounded read-only
virtio-blk inputs, and cache keys bind the exact source index plus the exact
kernel, initrd, and embedded build-agent identity. Cross-stage COPY preserves
modes, ownership, mtimes, symlinks, hardlinks within each source tree, and regular-file
`security.capability`; every other visible `security.*` xattr fails closed.
RUN mount forms beyond bounded default cache mounts, advanced RUN/COPY heredoc
forms, advanced COPY flags, and non-root build execution remain unsupported.

Automatic growth is limited to SporeVM's journal-less native and e2fsprogs
ext4 profiles, or equivalent layouts accepted by the pinned guest kernel.
Before the first writable mount, the managed initrd rejects journal presence,
recovery/error/orphan state, and pending orphan cleanup. Unsupported small
sources remain readable but fail growth before a build step, image, or mutable
destination ref is published. After mount, the agent repeats the same source
state validation before the resize ioctl and after the resized filesystem is
synced.

`spore run --image SOURCE --commit local/name:tag -- COMMAND` can now publish a
successful one-shot run's writable root disk as an indexed local image. The
commit path freezes the guest filesystem, reuses the quiesced rootfs snapshot
and CAS machinery, preserves source OCI config, permits transient `--inject`
inputs, and leaves the destination ref unchanged on nonzero command exit or
commit failure. It composes with the existing save/fork path: commit stable disk
preparation once, save one warm machine, then fork children.
Image commit also accepts `--disk-size SIZE` to sparsely grow the root block
device before the setup command. The size is absolute, 64 KiB aligned, and
cannot shrink the resolved source. SporeVM records the appended capacity as
known-zero chunks, enables growth-session virtio-blk `WRITE_ZEROES`, and asks
the managed initrd agent to invoke `EXT4_IOC_RESIZE_FS` directly from verified
device geometry. Growth does not invoke the image shell, and no `resize2fs` or
e2fsprogs package is required in the image. Growth sessions use internal
`noinit_itable` handling so
checksum-enabled ext4 layouts finish inode-table initialization before commit.
The same pre-mount source check and around-ioctl revalidation apply to commit.
Source/index validation, growth, bounded geometry validation, and setup all fail
closed before the destination ref is replaced.

This release breaks saved-spore, disk, memory, and rootfs cache formats.
Existing pre-unified saved spores and old flat/disk-layer cache entries should
be treated as invalid and rebuilt from source images or recreated from fresh
runs.

Disk state now uses `spore-disk-index-v1` chunk indexes everywhere. Writable
rootfs saves write `chunk-index-disk-v0` manifests whose identity is the BLAKE3
digest of the disk index, not a linear hash of flat ext4 bytes or a layer-chain
head. RAM manifests use the same index shape with their own chunk size, so disk
and memory now share the same parser and canonical index digest machinery.
The v1 parser enforces the canonical indent-2 JSON bytes already emitted by disk
and rootfs producers, including fixed field order and lowercase digest
references, so reformatting cannot create a second identity for the same map.
Existing official disk/rootfs index identities remain unchanged. Local RAM
backing proofs created with the earlier compact fingerprint safely fall back to
verified chunks and are regenerated with the shared canonical encoding by a
subsequent save or fork.

Cold starts from chunked rootfs storage no longer need to rebuild the whole
flat ext4 file before boot. When the flat materialization cache is absent or
stale, SporeVM opens the verified index over a sparse runtime base and faults
local CAS chunks in on first read. Missing or corrupt chunk objects fail the
complete multi-chunk virtio-blk request before any disk payload bytes are copied;
only the request's I/O-error status byte is written.

Live lazy rootfs runtimes now publish a process-owned cache lease before they
open the index. Destructive rootfs prune and CAS GC preserve unread chunks for
the full foreground-run or named-monitor lifetime, then reclaim them normally
after the runtime disk closes.

`spore pack` now emits chunked rootfs bundles directly from the canonical CAS
index and verified objects. It no longer assembles and rescans a full flat ext4
materialization before export. Packing chunked storage now requires that
canonical CAS; a surviving flat materialization does not repair missing index
or object bytes.

The disk backend is now one chunk-mapped implementation with map-copy fork
support. Forked writable disks get an independent overlay and do not create a
read-depth chain; durable children still come from snapshot plus open.

`spore cache gc --rootfs` is available for the unified rootfs CAS. It marks
reachable indexes and chunk objects from cache metadata, image refs, and live
runtime manifests, and dry-runs by default.
