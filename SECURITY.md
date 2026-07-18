# Security Posture

SporeVM is an isolation boundary written in Zig, which is not memory-safe.
That is a deliberate tradeoff, bought back structurally. This document is a
founding constraint, not a retrofit: it must be updated in the same change
that alters the attack surface.

## Threat Model

An untrusted guest must not escape the VMM. The current threat model is self-hosted
CI and agent isolation: hostile code runs inside the guest, and chunk data may
arrive from untrusted peers. We do not claim hardened multi-tenant public
cloud isolation.

Secrets never enter the VMM process or the spore format. Credential mediation
belongs to consumers (for example cleanroom's host gateway).

Local caches (rootfs cache, kernel cache, distribution chunk cache) live in
the same host trust domain as the `spore` binary itself: a principal who can
write to them can also replace the binary or kernel image. Cache integrity is
therefore enforced where bytes enter a cache — every install verifies content
against the expected digest before publishing it read-only — and ordinary
product open paths trust installed entries without re-hashing them. The build
executor is stricter when a managed kernel is actually needed: it derives
cache identity from the canonical read-only checksum sidecar, then reads the
Image once, verifies those opened bytes against that digest, and boots the
same allocation. Structural checks
(no symlinks, regular file, exact size) still apply at open time and fail
closed. This verify-at-install, trust-at-open contract assumes a per-user
cache on a single-tenant host; a shared or multi-tenant cache would need
open-time verification and is out of scope today.

## Attack Surface

Every path that parses attacker-influenced data is enumerated here and carries
fuzz targets from the slice that introduces it:

Saved-spore durable pin records are host-private, strict versioned JSON bounded
to 64KiB and fuzzed. A pin binds the staged manifest hash and exact validated
disk storage descriptor. Publication is serialized with GC/prune: objects and
the canonical index are durable before the derived completeness stamp, the
stamp is durable before the pin, and the pin is durable before final save
publication. A continuing named monitor acquires the exact new active lease,
durably replaces its source registry spec, and only then releases the old
lease; a failed handoff leaves the old spec and lease intact. Restore and pack
fail closed on missing or mismatched
pin, index, and object shape; lazy restore and pack keep content verification at
their existing boundaries. Unknown or corrupt pin records make GC and
destructive prune retain all CAS. Raw filesystem deletion can leak a pin but
cannot expose live data to collection. Raw copies share a pin identity, so
explicit removal or expert-only force-unpin can invalidate every copy; the
cache lists exact IDs and index health but does not infer orphan status from a
global reference registry. Portable unpack and pull instead materialize a
descriptor-bound local CAS inside the saved-spore directory. Destructive
removal classifies that authority only after verifying the canonical index and
every referenced object against their BLAKE3 digests; a simultaneous
host-private pin reference fails closed. Foreground and named restore publish
host-private active saved-spore leases before releasing the registry lock that
serializes authority selection with removal. Removal refuses any live lease
for the canonical directory, regardless of the descriptor currently named by
its manifest, then holds the same lock through deletion. This changes no
portable manifest, device, or public API format.

| Surface | Input source | Status |
|---|---|---|
| Rootfs-growth virtio-blk profile and initrd resize control | guest virtqueue descriptors and guest-supplied control-stream output | Rootfs-growth sessions alone offer `VIRTIO_BLK_F_WRITE_ZEROES` (bit 14) on the existing root virtio-blk device; ordinary and savable attachments retain the frozen feature surface. The shared virtio-mmio transport clears `FEATURES_OK` when the selected features are not a subset of those offered, latches the accepted set until reset, and validates restored or serializable feature state before applying it to a device. Both HVF and KVM full-machine capture reject any transport that offers the growth profile; rootfs-only checkpoints may inspect the queue for quiescence but serialize no growth transport state. `WRITE_ZEROES` is accepted only after negotiation and only as an exact three-descriptor request: a 16-byte header, one 16-byte range, and a one-byte status. The command-level sector must be zero, the historical `ioprio` field is ignored, the nonzero range is capped at 4 MiB, only `UNMAP` is accepted, and all shape, flag, overflow, capacity, and backend-writability checks complete before mutation. Parser, malformed-chain, status, and stateful before/after fuzz coverage enforce this boundary. Whole chunks become logical zero-map entries without payload writes; partial boundary chunks are read and lazy-CAS verified before mutation. A backend failure after a validated request permanently poisons the unpublished head, and snapshot, fork, head export, step-record publication, and image publication then fail closed. The bounded `spore-rootfs-grow-v1` request is a strict two-member object containing exactly one type and one nonempty bounded session identifier; missing, duplicate, unknown, over-limit, trailing, or embedded-NUL input is rejected, and the request carries no capacity or shell authority. Before the first writable mount, the trusted initrd agent opens `/dev/vda` read-only and decodes the primary ext4 superblock. It rejects journal presence, recovery or journal-device flags, filesystem error or orphan state, a nonzero legacy orphan head, and the orphan-file pending-cleanup flag; a frozen journal-less checkpoint need not carry the clean-unmount bit. The product default then mounts with internal `noinit_itable` so new inode tables initialize synchronously; only the master-gated engineering negative control can omit it. The agent derives target geometry from `BLKGETSIZE64`, re-reads and validates the same source-state fields before invoking `EXT4_IOC_RESIZE_FS`, calls `syncfs`, validates those fields again, and requires the filesystem block count to increase without exceeding the target or falling short by a complete ext4 block group. `statfs` supplies only bounded usable/free/inode diagnostics. The exact response is capped at 1,024 bytes, and the host independently enforces the same block-count progression, terminal-group bound, requested device size, and arithmetic constraints. Preflight rejection, source-state regression, nonzero exit, malformed output, or geometry mismatch aborts growth before user or Dockerfile work. No selected rootfs package, shell, or `resize2fs` binary is trusted or required. |
| `spore build` rootfs PREPARE cache and publication | local parent indexes, host cache records, and guest-produced rootfs state | The current `sporevm-build-v9` cache ABI represents capacity normalization as a typed synthetic `PREPARE`, keyed by the exact parent index digest, absolute target, platform, and kernel/initrd plus block/control producer identity. PREPARE lookup remains enabled under `--no-cache`; a hit must match the recomputed key and explicit fields, name a child whose logical size is exactly the target, pass normal rootfs descriptor/index validation, and have a completeness stamp. The exclusive rootfs cache lock spans preparation and the remaining build through destination-ref publication. On a miss, the quiesced rootfs checkpoint durably publishes verified objects first and the canonical index second, then publishes the completeness stamp; only a successful thaw permits the atomic PREPARE step record. Final image metadata and the mutable destination ref are published only after the resulting storage has been revalidated. The ordinary step-record GC inspection roots complete PREPARE children. Resize, freeze, queue-quiescence, poisoned-head, snapshot, completeness, record, metadata, or ref failure cannot make incomplete storage reachable and leaves the destination ref unchanged. |
| Virtqueue descriptors, rings, and device request headers | guest memory | shared queue/MMIO paths and current console/blk/vsock/rng device paths fuzzed; virtio notify handlers process at most one shared descriptor-chain budget per MMIO notify before returning to the VMM loop; virtio-net TX/RX frame-boundary handling, short virtio-net headers, oversized frames, queue exhaustion, reset, shutdown paths, and the grow-only virtio-mem request parser are fuzz/unit covered; vsock receive delivery splits stream packets to fit guest-posted buffer chains and never truncates, honors the guest's advertised credit window before sending, volunteers credit updates while consuming guest stream data, and resets abandoned or unknown stream connections; guest-controlled receive descriptor layouts driving the split path are fuzz covered; new device parsers require fuzz targets in the same slice |
| `spore-netd` frame stream, ARP, IPv4/UDP/TCP, DNS, and policy parsers | guest-originated Ethernet frames via virtio-net | length-prefixed frame bounds, ARP reply handling, IPv4/UDP DNS dispatch, DNS name parsing, malformed DNS handling, bound-service `*.spore.internal` answers, policy-gated DNS forwarding, TCP frame classification, hard-floor policy, CIDR allow rules, DNS-learned host allow rules, and DNS-rebinding hard-floor precedence are unit and fuzz covered. DNS answer learning follows bounded in-order CNAME chains from the query name within a single response; A or CNAME records not chained from the query name are ignored, chain length and name decoding are bounded, and the resolver-response answer parser carries a dedicated fuzz target. Explicit bound services proxy guest-controlled TCP bytes to declared host Unix stream sockets, so service providers must treat bound sockets as guest-exposed. Named lifecycle monitors spawn the optional `spore-netd` helper before applying the monitor jail, then own helper shutdown with the VM |
| Guest memory access during dirty scans | guest | KVM dirty-log and HVF write-protect harness paths have landed; dirty pages plus VMM-originated virtio writes are coalesced to fixed 2MiB chunks, zero chunks are elided, and non-zero chunks are BLAKE3-addressed before being recorded in the manifest. |
| Lazy RAM fault handling | guest page faults plus spore CAS chunks | KVM userfaultfd and HVF abort-exit paths are opt-in; faults materialize whole verified chunks and fail closed on malformed manifests or chunk mismatches; KVM pager failures wake the run loop and return a VM error rather than exiting the embedding process |
| Spore manifest decode | registry, disk | manifest v2 and v3 parsing/validation fuzzed; v0/v1 fail with a format-too-old error, and unknown versions or malformed manifests fail closed |
| CAS chunk reads | peers, registry, disk | BLAKE3 verified before restore; malformed memory manifests are fuzzed; compression is unsupported |
| Local RAM backing and proof sidecar | local disk | Product restore paths treat the fixed `ram.backing` and `ram.backing.proof` paths as optional accelerators: they inspect each path without following symlinks, open only regular files, and read at most 16KiB from the proof. An optional path that is absent, symlinked, non-regular, or size-mismatched, or a proof that is stale, foreign, malformed, or cryptographically mismatched, may select verified chunks. Malformed authoritative memory/index/backing metadata, verified-chunk corruption, allocation failure, unexpected host I/O, and backend/platform/topology failures remain errors rather than being hidden by fallback. Fork keeps the proven parent fd open while linking children and verifies every child link against the proof-bound parent file identity before writing a child proof, so pathname replacement cannot bless a different inode. Schema v2 proof creation first measures an existing Linux fs-verity digest without changing permissions. For a new owned read-only backing, it temporarily adds owner-write permission on the already-open fd, enables and measures verity, then restores the exact original permission bits. The kernel may change mtime while enabling verity, so publication requires stable device, inode, owner, and size, binds the proof to the post-enable mtime and measured digest, and re-stats that complete post-enable identity before writing the proof. Existing-verity and schema-v1 paths still require exact mtime stability. Every exit after the permission change attempts exact restoration; restoration failure is fatal and no proof is published. A process crash in that bounded interval can leave an owner-writable file but cannot publish authority for it. Chunks remain authoritative and an absent proof selects verified chunks. Restore re-measures the opened fd and falls back to chunks if the kernel digest is unavailable or mismatched. Without verity metadata, the proof remains host-local provenance for a `MAP_PRIVATE` fd, not portable byte-integrity authority |
| Bundle metadata, chunkpack index, pack segments, and pull/push URIs | peers, registry, disk, S3, HTTP(S) | `bundle.json`, `rootfs.index.json`, and chunkpack index parsing are fuzzed; unpack/pull only accept canonical metadata paths, canonical child ids, canonical pack paths, verified rootfs artifact paths, descriptor-derived rootfs/disk CAS index/object paths, absolute undecoded `file://` pull sources, and digest-pinned `s3://...@sha256:<bundle>` or `http(s)://...@sha256:<bundle>` pull sources. S3 and HTTP(S) pull download only the canonical files named by validated metadata, verify the canonical bundle digest before materialization, then verify segment SHA256 plus logical BLAKE3 chunk IDs and rootfs/disk CAS index/object digests before writing chunks or attaching writable disks. Remote S3 and HTTP(S) pulls bound metadata, declared payload objects, and aggregate materialization bytes before or while writing to disk instead of relying on later digest validation to reject oversized responses. HTTP(S) pull targets are resolved and rejected before each GET if any answer is loopback, link-local, private, multicast, or reserved. HTTP(S) redirects, mutable query strings, fragments, userinfo, percent-encoded paths, and path traversal are rejected |
| Node-local distribution chunk cache | local disk | `spore pull` stores memory chunks by BLAKE3 id only after verifying source bytes, re-verifies cache hits before hard-linking or copying them into a materialized spore, and fails closed on corrupt, non-file, or symlinked cache entries |
| Immutable rootfs artifact resolution | manifest, local rootfs cache, bundle rootfs artifacts | product restore paths only accept the immutable ext4 rootfs kind, validate virtio-blk binding, and open the identity-addressed materialization cache read-only under the verify-at-install, trust-at-open cache contract: the open refuses symlinked or non-regular entries and size mismatches without re-hashing installed bytes. Exact fd-backed installs still verify content against the manifest digest and size before atomically publishing the entry read-only; chunked rootfs installs publish flat materializations only after verifying the descriptor-selected index and BLAKE3 chunk objects. User-supplied rootfs paths are always copied for exact fd-backed records so later edits cannot alias cache entries; metadata-only rootfs bundle policy is accepted only with an explicit materialization flag and a trusted cache hit under the same local-cache contract |
| Manifest-bound chunked rootfs storage descriptor and disk index | manifest, registry, disk, bundle, peers | `rootfs.storage` is parsed as a separate storage authority from OCI provenance, requires `chunked-ext4-rootfs-v0`, BLAKE3, exact `rootfs/blake3` namespace, matching rootfs device binding, 64KiB disk chunks, logical size matching the ext4 artifact size, `base_identity == index_digest`, and `rootfs.artifact.digest == index_digest`; writable disks use `disk.kind: "chunk-index-disk-v0"` with the same descriptor fields and name their `spore-disk-index-v1` by `disk.base`; index bytes are BLAKE3-checked against the descriptor before bounded parse, fuzzed, descriptor/coverage validated, canonically re-encoded, and required to match the input exactly, rejecting legacy or unknown kinds, reordered or differently formatted JSON, uppercase or malformed digests, duplicate or out-of-range chunks, implicit or overlapping zero-fill, descriptor mismatches, and unsupported namespaces; product restore opens the selected disk/rootfs index over a sparse base when the flat cache is absent, verifies and promotes every lazy CAS source across the complete logical read before copying disk payload, and fails missing or corrupt multi-chunk, multi-descriptor requests by writing only the virtio I/O-error status; bundle pack holds the rootfs cache lock and copies only the descriptor-bound canonical index plus BLAKE3-verified objects, without treating the derived flat materialization as authority; bundle unpack/pull serialize shared-cache publication against GC, install verified objects before publishing their descriptor-bound index, and publish the completeness sidecar only after the full storage value is durable |
| Same-version runtime disk-fork claim, descriptor, and overlay fd | local child/source monitors | The private prepare and claim requests are strict, versioned JSON lines capped at 8,192 bytes; both parsers are fuzzed. Prepare validates batch/name/count/copy policy before pausing; HVF/KVM then pause every vCPU, reject pending virtio-blk or vsock work, capture RAM/machine state without sealing the writable disk, clone every required physical head at that one epoch, and resume the source after atomic registration or cleanup. The claim is bound to a 256-bit random one-use token, batch, validated child name/index, and exact baseline kind/digest. The registry rejects duplicate or oversized batches before allocation (32 children, 4KiB rendered names, 2MiB per descriptor, 64MiB aggregate), expires claims, and closes every unclaimed head on cancellation or shutdown. A successful claim switches the one-shot Unix stream to a fixed 16-byte binary frame whose first bytes carry one `SCM_RIGHTS` fd; the receiver rejects missing/multiple fds, `MSG_CTRUNC`, ancillary data on later reads, short/trailing bytes, and unknown tags or versions. The private descriptor is exact-length and fuzzed, and binds the baseline to a 64KiB logical geometry plus disjoint, zero-padded physical-overlay and logical-zero bitmaps. Its internal `sparse` clone method is accepted only with no physical-overlay bits; it is used when an exact committed baseline owns every clean byte, while native-clone failure for remaining physical overrides is closed unless an explicit slow-copy caller opts in. Adoption independently reopens and checks that baseline, and accepts only one unlinked regular exact-size `O_RDWR` fd without append semantics; `FD_CLOEXEC` is set immediately when ancillary data is parsed. Runtime overlays honor absolute `TMPDIR`, retain that factory root with the live disk, and reject cross-filesystem fd adoption; transient APFS clone names therefore stay on the source overlay filesystem. Every linked APFS clone exists only inside a private `0700` directory, then is opened and unlinked before ownership transfer. A validated lifecycle lease keeps cache-backed indexes/objects or the saved-spore authority rooted through destructive prune and GC after the source disappears. The existing monitor-jail smoke exercises an fd round trip after applying the unchanged jail. |
| `spore run` legacy and SPIO frames | guest vsock stream | bounded host buffers; legacy exit/timing string parser is unit and fuzz covered; SPIO v1 frame headers, stream ids, payload lengths, flags, per-stream offsets, terminal output frames, and resize payloads are unit covered; malformed frames fail the run. The dedicated named-startup readiness request succeeds only after required rootfs and network setup and does not spawn a guest process. `start-v1` and `attach-v1` setup requests fail closed on unsupported stdio modes, and input attach validates the saved guest session had an interactive stdin pipe or PTY before accepting host bytes. TTY mode exposes a guest PTY to the child process and treats merged terminal bytes as untrusted guest output |
| `spore run --inject` files | caller-provided local files | host validates flat injected file ids and regular non-symlink source files, appends bytes to the existing initrd as `newc` entries, and the initrd agent copies only flat regular files into `/run/sporevm/injected` tmpfs before exec. The bytes are not rootfs cache inputs, and injection is rejected with `--save` and `--from` to avoid ambiguous persistence. Disk-only `--commit` permits injection because tmpfs is outside the root disk; an explicit guest copy onto the root disk is intentional persisted state |
| `spore run --commit` image publication | guest-written root disk, local rootfs CAS, local mutable image ref | commit is fresh-image and non-interactive only; optional absolute disk growth rejects shrinking, grows only the private sparse head, and completes the shared growth-only virtio-blk/direct-ioctl path before the user command. Publication begins only after guest exit zero, sends the fixed `fsfreeze-v1` request, requires virtio-blk queue quiescence, seals the root disk through the existing bounded disk-index path, and publishes only a complete `chunked-ext4-rootfs-v0` descriptor. The exclusive rootfs cache lock spans snapshot sealing, completeness publication, image metadata, and atomic local-ref replacement so GC cannot race unpublished objects. Source refs are resolved before execution and destination refs are replaced last; growth, command, freeze, snapshot, validation, or publication failure leaves the destination ref unchanged |
| OCI manifest, OCI layout, rootfs tar, and layer decode | registry, local OCI layout, local rootfs tar | rootfs builder only, outside the monitor process; mutable tags are resolved into digest-pinned refs before build materialization, registry fetches require HTTPS and reject loopback, link-local, private, multicast, or reserved resolved targets before each GET including manual redirects, cross-origin redirects drop Authorization, local refs resolve to digest-pinned local identities, blobs are verified, layout tar extraction is path-safe and byte-bounded, layer/rootfs tar application is path-safe, tar metadata records and PAX xattr handling are bounded, PAX xattrs are limited to deliberately supported capability records, and JSON/tar fuzz targets cover parser inputs |
| Remote URL `ADD` fetches | Dockerfile URL operands and numeric mode expressions; public DNS answers; HTTPS response headers, redirects, and bodies | The selected plan's deterministic RUN/COPY/ADD/WORKDIR semantics are preflighted before any ADD fetch or guest execution. Response-derived filenames and effective destinations are validated after the bounded fetch and before cache locking or guest startup. Every request and redirect re-resolves through the public-target policy and uses the resolved address for TLS. URLs, redirects, response heads, instruction count, aggregate bytes, and total fetch time are bounded. Opaque bytes are privately staged, synced, made read-only, and content-hashed before cache lookup; failures publish no authority, and the next staging session scavenges abandoned files after a crashed process. Optional `--chmod` is expanded from the instruction-start snapshot and must resolve to an octal value from `0` through `07777` before any GET; symbolic, empty, malformed, duplicate, or out-of-range modes fail closed with the source line. |
| Attacker-controlled build RUN process and operation-owned filesystem view | Dockerfile shell or exec command, descendants, syscalls, rootfs state, procfs paths, device nodes, sockets, and attached build-input disks | Every build RUN executes beneath a trusted supervisor in dedicated PID, mount, cgroup, IPC, and UTS namespaces. Mount propagation is recursively private, the command enters a descriptor-clean rootfs confinement and is PID 1 behind a procfs mounted from that PID namespace, so `/proc/1/root` cannot name the initrd or agent namespace. BuildKit-compatible read-only and masked proc paths deny guest-global sysctl mutation and sensitive kernel pseudo-files, preventing unrecorded state from affecting a later RUN or cache reconstruction. A fresh minimal `/dev` exposes only standard character devices, devpts, shared memory, and mqueue; auxiliary virtio block and console nodes are absent. A cgroup device policy rejects reads and writes to every block device and console alias, including attacker-created nodes, while retaining BuildKit-compatible harmless `mknod` behavior. A fixed seccomp filter rejects `socket(AF_VSOCK)`, `socketpair(AF_VSOCK)`, and `io_uring_setup`, closing the direct and asynchronous socket-creation paths to the agent/host control transport while leaving ordinary IP networking available. The command receives only the pinned default BuildKit capability set, excluding `CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, and `CAP_NET_ADMIN`; sysfs and the scoped cgroup view are read-only, and setup descriptors are closed before exec. The supervisor mirrors exit or signal status, and namespace destruction plus cgroup kill-and-empty verification owns teardown after success, nonzero exit, signal, timeout, setup failure, or control loss. Any setup or cleanup failure blocks checkpoint, cache-record, and destination-ref publication. This boundary adds no mount syntax, secret or credential authority, device type, or manifest field. |
| `spore build` Dockerfile subset, `.dockerignore`, build-context hashing, context/stage disks, and build executor control | local build contexts and caller-selected Dockerfiles; guest-originated RUN/COPY output after the first executor miss; host-generated read-only ext4 context disks and immutable stage rootfs disks parsed by the guest kernel | The builder supports only an explicit fail-closed Dockerfile subset, source-spanned multi-stage plans, and named OCI-layout build contexts; unsupported syntax, context escape attempts, missing sources, forward stage references, and special-file COPY inputs fail before image publication. A single unquoted, non-chomping COPY heredoc is bounded by the 1 MiB Dockerfile limit, consumed with its exact source span during the full-file parse, and validated by the existing Dockerfile-parser fuzz target. Its body expands through the bounded instruction-start engine while preserving literal quotes, then enters the typed COPY transition as one BLAKE3-addressed root-owned `0644` regular file; quoted/chomping delimiters, multiple or mixed sources, COPY flags, malformed expansion, and unterminated bodies fail closed before execution. The selected target graph is resolved before execution, and only its reachable external bases are fetched. The bounded path-pattern parser implements the accepted COPY and ordered `.dockerignore` dialects, is fuzz/unit covered, and never replaces the fd-relative, no-follow context traversal or immutable capture boundary. Context `COPY --parents` accepts only the strict boolean context form: destinations derive from cleaned `CopyRoot.rel` values below the normalized destination, and ordered roots plus captured modes and bytes enter typed COPY identity. Context-root operands `.` and `./`, internal `/./` pivots, and compositions with `--from`, `--link`, heredocs, or other flags fail during full-file planning. Its explicit-directory synthetic v4 tree merges each reconstructed directory only with a directory; root and nested non-directory conflicts fail before unlinking the existing inode, while ordinary and build-input COPY request shapes retain their prior overwrite behavior. The existing Dockerfile fuzz target covers the flag grammar; the v4 request parser/framing, immutable capture, and fd-relative no-follow confinement boundary remain unchanged, while parents-specific apply semantics add the strict conflict rule inside the walker. RUN cache identity uses length-framed typed fields for network, ENV/ARG, memory, vCPU count, and `nofile`, plus the exact canonical instruction text, so guest-observable resource, environment, shell/exec form, and argv changes cannot alias. Duplicate inherited `Config.Env` keys are normalized in the current stage before hashing and serialization with the same last-value-wins rule as runc, while their raw order remains available for OCI publication and reconstruction by a later `FROM`. Effective RUN entries that are bare empty strings, have an empty `=value` name, or contain an embedded NUL fail before cache lookup or executor startup; nonempty entries without `=` become empty-valued `NAME=` entries in the effective environment to match the pinned BuildKit/runc path, while the raw OCI list remains unchanged. On executor misses, each regular context input is streamed once through BLAKE3 into a private sparse spool, checked for concurrent mutation, and emitted only from that sealed slice; resolved heredoc bytes instead remain bounded inline data and are emitted through the same immutable, complete-stamped, read-only context-disk authority. `COPY --from` attaches at most two already-complete stage/local/OCI rootfs artifacts as additional read-only instances of the existing virtio-blk device type. Chunk-indexed inputs remain lazy, verify CAS chunks through the existing storage authority, never receive a writable overlay, and are mounted `MS_RDONLY,noload` under an initrd-owned path. The strict v4/v5 guest COPY JSON parsers and SPIO framing are fuzzed separately from the filesystem walker: requests select context or stage input by a bounded index and validate relative source plus absolute destination paths. V5 accepts only immutable build-input disks and requires the explicit `link` destination policy; ordinary context, heredoc, and stage COPY continues through v4. The walker caps source traversal and link-conflict removal at 65,536 entries, resolves every source and destination fd-relatively, and has a generated-tree fuzz harness covering files, directories, bounded and escaping symlink targets, hardlinks, special inodes, and entry-count failures; focused unit tests cover parent-symlink confinement and symlink-target bounds. Cross-stage copies preserve source entry modes, ownership, mtimes, hardlink topology within each source tree, and bounded `security.capability` only for regular files under the managed v0.6.3 kernel with `CONFIG_EXT4_FS_SECURITY=y`. Every copied inode kind and every existing overwrite destination is inspected without following the final symlink; directories, symlinks, overwrite destinations, and regular files carrying any other visible `security.*` xattr fail closed before destination mutation. Cross-stage link policy never follows lower destination symlinks, replaces conflicting lower subtrees within the shared bound, and merges only directory-on-directory results. A single RUN heredoc is accepted only when one unquoted, non-chomping `<<NAME` token is the complete command after the bounded default cache flags. Its non-empty body must not contain NUL or begin with a shebang; it is source-spanned and fuzzed during the full-file parse, preserved with its final newline, and streamed as the ordinary shell command, so ARG/ENV expansion, quoting, escaping, unset behavior, and parameter operators remain guest-shell semantics. Shell-prefix, quoted, chomping, multiple, empty, shebang/direct-exec, exec-form, malformed, and unterminated RUN heredocs fail before executor startup. All shell RUN commands are capped at 64 KiB and reuse the existing v1 or cache-mounted v3 request, so this syntax adds no guest parser or protocol authority. Exec RUN uses a distinct versioned request with a non-empty array of at most 16 JSON strings, a non-empty argv zero, at most 4 KiB of decoded argv, and a fully serialized host preflight before executor startup. Unmounted exec RUN uses v2; cache-mounted shell or exec RUN uses v3 with an exact bounded mount list. One strict version-policy parser accepts only the exact newline-terminated object, requires every documented field once, rejects aliases, duplicates, unknown fields, malformed scalars or arrays, trailing commas, and trailing non-whitespace bytes, and carries both versions through the same fuzz coverage. The shared guest request boundary rejects full-buffer truncation and duplicate top-level type keys for every request kind. Its JSON strings require valid raw UTF-8, decode Unicode escapes and valid surrogate pairs to UTF-8, and reject embedded NULs and invalid or unpaired scalars. Exec form performs no implicit shell expansion. For a slashless executable, PATH lookup skips candidates that fail lookup, rejects an executable relative match, selects the first executable absolute candidate, and calls `execve` exactly once; failure to execute the selected program cannot fall through to a different binary. The Dockerfile parser and guest request parser fuzz targets cover malformed arrays and objects, heredoc markers and bodies, embedded NULs, raw and escaped JSON controls and Unicode, duplicate and unknown fields, missing newlines, trailing input, truncation, and bounds. Environment/workdir/COPY controls have matching host/guest limits, and `nofile` is validated before `setrlimit`. Each RUN executes in a dedicated cgroup leaf, then all descendants are killed and reaped before success. Build boots deliberately leave rootfs `/tmp` and `/run` on ext4 so Docker-visible state enters checkpoints; normal `spore run` keeps its ephemeral tmpfs contract. Network resolver injection remains an initrd-owned bind mount. A missing symlink target is scaffolded only on the rootfs device; the agent records what it created, unmounts and removes it before freeze, then revalidates the current link, refreshes resolver contents, and remounts after thaw. Cleanup or restore failure blocks reusable step-record and destination-ref publication; any complete orphaned CAS snapshot remains unreachable and collectable, and helper bytes never enter a checkpoint. Capacity preparation uses only the bounded `spore-rootfs-grow-v1` request. The trusted initrd validates the ext4 source before writable mount, the host exposes transient root-vda `WRITE_ZEROES`, and the initrd derives geometry from `BLKGETSIZE64` before invoking `EXT4_IOC_RESIZE_FS`; the selected image contributes no executable, parser, or capacity authority. The obsolete `spore-build-resize-v1` request is rejected. Freeze/thaw and resize controls fail closed, rootfs snapshots require virtio-blk quiescence, and step records publish only after CAS completeness. COPY and WORKDIR resolve from an fd for `/mnt/rootfs` with `openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)` or a confined component walk, so symlinks cannot escape into the initrd namespace. Current builder-v9 typed SCRATCH, PREPARE, and Dockerfile step records root their complete CAS children and bind COPY destination policy explicitly. Valid complete builder-v8, builder-v7, and builder-v6 records cannot hit v9 keys but remain retained roots; malformed or incomplete known records and semantically stale current-v9 records are pruneable, while genuinely unknown future record kinds or builder versions remain conservative roots. |
| Generation device inputs | guest | MMIO register surface and fork/restore parameter schemas are fuzz/unit covered |
| Control socket JSON and named exec/copy SPIO stream | local consumers | local-only lifecycle monitor protocol is implemented for HVF and KVM, including fixed-RAM multi-vCPU create, exec, file copy, save, restore, and fork; named startup publishes ready metadata only after the guest agent answers the dedicated readiness request, then requires the socket to answer a `hello` request carrying the `spore.monitor.hello.v1` schema, an exact SporeVM version match, and the monitor helper contract before create, restore, or fork-child startup reports success, and control operations other than shutdown re-verify the same handshake; disk-backed children validate and adopt their baseline plus one-shot overlay fd before probing guest readiness; all attached named exec and named file copy use streaming control requests plus the same bounded SPIO frame parser for optional stdin, terminal input, resize, separate stdout/stderr or merged terminal output, and exit; output frames use fail-fast local backpressure, aborting the exec when a disconnected or slow consumer cannot accept a complete frame within the 25 ms socket send deadline so the VMM/control loop cannot block indefinitely; monitor-generated guest session ids include a random per-process nonce so a restored guest cannot replay a prior monitor's cached request id, and host-side vsock ports advance from that random nonce for readiness and every request; detaching a completed stream drops queued packets for its old four-tuple before the next stream is attached; copy requests accept explicit regular files or directory trees, reject non-absolute guest paths plus `.`/`..` components, reject symlinks and special files, publish copy-in through no-overwrite temp paths, and create copy-out host destinations with no-overwrite flags; monitor processes deny child process execution through an embedded macOS sandbox profile or Linux seccomp filter; malformed requests fail closed and the socket is protected by private runtime-directory permissions |
| Named create options JSON | local callers, toolchains | `spore create --options @file.json` is bounded to the lifecycle metadata size limit, parsed into the same create option validators as CLI flags, rejects unknown schema versions and mixed file/field configuration, and is fuzz covered |
| Saved lifecycle metadata | input spore directories and bundles | Saved lifecycle fields are compatibility hints, not fresh host authority. In particular, `console_log_path` is untrusted and restore never opens or truncates it; named restore currently configures no console log until a future explicit restore option selects a new host path. Ready, list, result, and failure output expose only the path actually configured for the live monitor. |
| Embedded initrd Toybox shell and applets | host-selected guest argv and guest workload input | the default initrd builds Toybox from pinned source with a minimal applet config and runs it only as guest child workload code; Toybox does not add host parsers, VMM devices, monitor control requests, or rootfs cache authority. Unsupported applets are absent, existing SporeVM helper binaries win over Toybox symlinks, and exact argv still uses `execve(argv[0], ...)` without guest PATH lookup |

RUN cache mounts add no host credential or portable-state authority. The
parser accepts at most eight `type=cache,target=...` entries with an optional
opaque `id` and `sharing=shared|locked`. Target, ID, and sharing expand through
the bounded builder-owned engine; an omitted ID is `path.Clean` of the resolved
target, while every resolved ID becomes a domain-separated BLAKE3 key before
it can select storage. Raw IDs therefore never become host paths or lock names.
Empty, NUL-containing, oversized, malformed, unsupported, or contradictory
same-ID declarations fail during semantic preflight before remote ADD
preparation or guest execution. Reachable base resolution/import may already
have populated its cache because inherited OCI configuration is required for
that resolution; after a cache option fails semantic preflight, no remote ADD
request, aggregate-cache open or mutation, VM/runtime activity, snapshot, step
record, or destination publication occurs. A strict newline-terminated v3
request requires every field once, canonical absolute targets, lowercase fixed-length keys, and
complete input consumption; it shares the existing request-parser fuzz entry
point. The host opens one fixed-size regular no-follow ext4 file while holding
an exclusive aggregate cache-store lock and exposes it as a transient writable
virtio-blk device only to build VMs. The guest creates and opens targets through
the rootfs-confined resolver and bind-mounts only the selected cache directories
onto those targets before entering the operation-owned RUN sandbox. The
aggregate mount and sibling cache keys remain outside the sandbox chroot; its
scoped procfs, minimal `/dev`, device policy, capability set, and syscall filter
close namespace, raw-device, console, vsock, and io_uring paths back to them.
After killing and reaping RUN descendants, the agent unmounts selected targets
in reverse order, calls `syncfs`, cleanly unmounts the aggregate disk, and
removes builder-created mountpoints before acknowledging exit or allowing a
rootfs freeze. Mount-target and created-component device/inode identities plus
a no-symlink walk make path replacement fail closed, including for a target
that already existed. Pre-existing symlink ancestry is rejected during setup
before the command runs. Empty created ancestors are removed, while
an `ENOTEMPTY` ancestor is preserved because it now contains ordinary rootfs
state written beside the mount. Actual unmount failure, a nonempty mountpoint,
or unverifiable ownership poisons the guest build session, returns exit 125,
and blocks step-record and ref publication. Dirty,
symlinked, non-regular, size-mismatched, bad-magic, or host-visible unclean cache
disks are discarded; a guest mount rejection remains a build error. Both
`shared` and `locked` use the same safe serialization: the aggregate lock spans
the uncached executor session, and the existing coarse rootfs-cache lock
currently serializes the whole build. Spore does not claim BuildKit's
concurrent shared-writer scheduling. Fully cached builds never open or attach
the aggregate. BuildKit result identity retains cache options only for a shared
ID whose value equals the resolved destination; Spore matches that value-based
rule without trying to recover whether the ID was written explicitly. Cache
bytes are never rootfs CAS, manifest, secret, SSH, or credential input.

Default context bind mounts accept only one expanded literal relative source
and one expanded target per declaration on ordinary shell-form RUN. Exec-form
and heredoc RUN combinations fail during the full-file parse. Planning resolves the source
through `.dockerignore`, rejects missing paths, directories, symlinks, special
files, globs, parent traversal, and non-context authorities, and records the
normalized source/target, read-only policy, mode, and BLAKE3 bytes in ordered
RUN cache identity. Captured mtime is intentionally excluded from that semantic
identity to match BuildKit's mtime-only cache hits. A miss validates the source
mtime against ext4's nanosecond timestamp range, binds its presence and value
to the context-disk transport identity, selecting v2 whenever a captured mtime
is present, and seals each regular file through the existing mutation-checked
context snapshot. Context disks without captured mtime retain the unchanged v1
identity, and ordinary COPY/ADD entries plus rootfs/import producers retain
their existing zero-timestamp behavior and identity. The live host path is
never mounted or opened by the VM. Out-of-range seconds or
nanoseconds fail before execution rather than being truncated or wrapped. The strict
newline-terminated v4 request accepts at most eight canonical captured source
paths and absolute targets, rejects duplicate, unknown, malformed, trailing,
overlapping cache/bind, and bind/bind fields, and shares the existing
attacker-input request fuzz target. Targets overlapping the sandbox-owned
`/proc`, `/dev`, and `/sys` views, the agent-owned `/run/sporevm` path, the
inert SSH compatibility path at `/run/buildkit`, or the managed resolver target
fail before setup; this includes ancestors that would hide a protected path and
descendants that would alter one.

The trusted agent opens the selected context-disk source and rootfs target
component-by-component without following symlinks, mounts the regular file
with `MS_RDONLY|MS_NOSUID|MS_NODEV`, and exposes it only through the
operation-owned RUN sandbox. Existing regular-file targets remain the lower
inode; absent targets and parent components carry recorded device/inode
ownership. After descendants are killed and reaped, binds unmount in reverse
order, descriptors close, the owned target is removed, and only still-empty
owned ancestors are removed. `ENOTEMPTY` on an ancestor preserves legitimate
rootfs sibling state; unmount failure, non-regular or replaced paths, symlinked
ancestry, or unverifiable ownership poisons the build session with exit 125 and
blocks checkpoint, step-record, and ref publication. Bind sources, target
mountpoints, setup scaffolding, and context-disk transport inodes never enter
rootfs CAS or portable state. Ordinary files that RUN deliberately writes from
bind data remain normal rootfs output.
Writable/custom, directory, stage/image/named-context, tmpfs, secret, and
credential-bearing bind authorities remain rejected.

The only accepted SSH syntax is one exact default
`RUN --mount=type=ssh` declaration with no caller-supplied input. Full-file
planning rejects every option, duplicate, required or custom socket, secret,
and credential-bearing form. The builder adds BuildKit's inert
`SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0` value to that RUN only when its
effective environment lacks the key; it creates no socket, directory, guest
request field, file descriptor, host/VMM transport, broker, CLI option, or
durable state. The resolved environment and typed `ssh_declared_absent` state
are separate RUN cache inputs so a future credential-bearing operation cannot
reuse the result. A command that requires the nonexistent socket exits through
the ordinary RUN failure path, which publishes no step record or image ref.

Builder-owned Dockerfile expansion is part of the full-file parse boundary.
Expansion-capable operands retain their exact quote and escape spelling through
parsing, and the bounded stable `$NAME`, `${NAME}`, default, and alternate
grammar is validated before any base fetch or guest boot. Unset variables
resolve to empty, automatic platform args derive from the selected platform,
and every ENV instruction resolves all pairs from one instruction-start
snapshot; malformed or unsupported modifiers remain fail-closed. The existing
Dockerfile parser fuzz target and a dedicated expansion fuzz target cover
malformed quoting, escaping, nesting, substitutions, and modifier bytes.
Expansion depth, each resolved word, and aggregate builder variable state are
capped at 64 levels, 1 MiB, and 64 MiB respectively, with a source-spanned
failure before executor startup or image publication.

The accepted remote `ADD` surface is one public HTTPS URL with a literal scheme
and authority plus one destination. The optional numeric mode, URL path/query,
and destination are expanded. Full-file parsing and deterministic selected-plan
semantic preflight complete before any ADD fetch or guest execution;
response-derived filename/destination validation completes after fetching but
before guest startup.
Each build performs a fresh GET, and every request and redirect independently
resolves all DNS answers through `host_fetch_policy.zig`; loopback, private,
link-local, multicast, reserved, HTTPS downgrade, URI userinfo, fragment, Git,
excessive-redirect, missing-location, non-200, non-identity content encoding,
malformed length, and over-budget inputs fail closed with the source line. The
builder sends no `Authorization` header and does not consult host credential
stores. Requested query strings and server-provided HTTPS redirect targets
remain ordinary URL data. URLs and redirect locations are capped at 64 KiB,
and each response-head buffer is capped at 16 KiB.
At most 64 remote ADD instructions may run in one build, their combined body
bytes are capped at 1 GiB, and their combined host-fetch time is capped at ten
minutes or the smaller build timeout. Response bytes stream into a private
exclusive `0600` staging file, remain bounded even without `Content-Length`,
are synced, made read-only, and BLAKE3-hashed before cache lookup. Failure
deletes every staged file and cannot publish a step record or destination ref.
A process crash leaves no reusable authority; the next remote ADD staging
session scavenges abandoned files while no live session holds the directory
lock. The typed ADD key binds the resolved
URL/destination, safe response `Content-Disposition` filename or URL-path
fallback, actual content digest, resolved numeric result mode (default `0600`),
validated optional `Last-Modified` timestamp, ENV/ARG snapshot, platform,
parent rootfs, and executor identity. A valid HTTP-date is applied through an
fd opened by the shared rootfs-confined resolver after COPY; absent or malformed
dates apply the Unix epoch. The current `spore-build-copy-v4` request is a bounded exact
object whose fields appear once, whose timestamp is a JSON `null` or signed
64-bit integer, and whose object plus required newline consumes the complete
request. The existing read-only context-disk and guest COPY protocol perform
the filesystem apply, so the host fetch adds no guest network or credential
authority. URL, redirect, content-disposition, HTTP-date, streaming, cache,
cleanup, and v4 framing behavior has focused unit or differential coverage. URL
operands, numeric mode values, content-disposition values, HTTP dates, and v4
scalar framing have dedicated fuzz coverage. ADD flags other than numeric
`--chmod`, symbolic modes, local inputs, ambient authentication, remote Git,
SSH, archive extraction, and special files remain rejected.

Cross-stage `COPY --link=true` uses the strict newline-terminated
`spore-build-copy-v5` object. Every documented field appears exactly once,
unknown fields and malformed destination policies fail closed, and the host
preflights the complete serialized request before boot. V5 selects only an
immutable bounded build-input disk. Its source operand follows final symlinks
through a root-confined, depth-bounded resolver, while symlinks below a copied
directory remain data. The filesystem walker constructs real
destination directories without following lower symlinks, removes conflicting
lower subtrees with fd-relative no-follow traversal capped at 65,536 entries,
and rejects unsupported destination security xattrs before mutation. The
Dockerfile parser, v5 request parser, generated-tree walker, stage-source cache
transitions, and pinned BuildKit destination conflicts have focused fuzz,
unit, or differential coverage. Local-context link policy remains rejected.

Builder-v9 RUN/COPY/ADD/WORKDIR cache keys bind the same exact kernel/initrd and
agent-contract identity used for PREPARE. On the managed default, the identity
uses the canonical SHA-256 from the bounded read-only kernel sidecar and the
build-generated SHA-256 of the embedded initrd, so a fully cached build reads
neither artifact body. A later miss reads the kernel once, verifies the opened
bytes against the bound digest, and boots that same allocation. Explicit
kernel/initrd overrides remain eager: the builder loads, hashes, retains, and
boots those exact bytes. A different producer cannot reuse downstream results
merely because it happens to emit the same prepared rootfs index. Malformed
sidecars, digest mismatch, or changed custom bytes fail closed.

Build capacity policy is fixed: a validated parent below 16 GiB normalizes
once to exactly 16 GiB, while a parent already at or above that cap is never
enlarged automatically. Block or inode ENOSPC after an executor instruction is
terminal for that invocation; SporeVM does not replay a potentially
side-effecting step and publishes neither its step record nor the destination
ref. The supported growth envelope is SporeVM's journal-less native ext4
profile plus journal-less layouts from SporeVM's e2fsprogs writer, or
equivalent layouts that pass the pre-mount recovery/error/orphan checks and
that the pinned guest kernel can online-grow under the product-default
synchronous inode-table policy. Unsupported features or inconsistent geometry
fail before publication, without a `resize2fs` fallback.

When a valid source ends in a partial final chunk, growth verifies any CAS
authority and preserves the old prefix before exposing a sparse-zero suffix.
It materializes at most that one boundary chunk; failed reads, writes, or
resize leave the logical map and digest authority unchanged.

## Structural Rules

- **ReleaseSafe only for shipping builds.** ReleaseFast is for benchmarks.
  `build.zig` prefers ReleaseSafe; release packaging must never override it.
- **Chunks are verified before use.** Any chunk received from any source is
  checked against its BLAKE3 id before being mapped into guest memory or
  parsed. A malicious peer can deny service, never inject state.
- **Live lazy runtimes root their CAS.** Before a cache-backed lazy disk opens
  its index, the runtime publishes its validated baseline lease while holding
  the rootfs cache lock. Foreground runs and named monitors retain that root
  until the runtime disk closes, so GC or destructive prune cannot remove an
  unread object during the VM lifetime.
- **Fail closed.** Unknown manifest versions, unsatisfiable platform
  contracts, and unverifiable chunks are errors, never degraded behavior.
- **Caller-influenced paths are validated before use.** Platform limits such
  as the 104-byte macOS `sun_path` bound are enforced with actionable errors
  before spawning helpers or binding sockets; unvalidated path input must
  never reach a code path that can panic.
- **The stable monitor scope is local named lifecycle.** `spore create`,
  `spore exec`, `spore save`, `spore restore --name`, `spore fork --vm`, `spore ls`, and
  `spore rm` are available on supported backends, with fixed-RAM multi-vCPU
  create, exec, explicit file/directory copy, save, restore, and disk-backed
  fork. Monitor processes deny child process
  execution through an embedded macOS sandbox profile or Linux seccomp filter
  after optional startup helpers are spawned, covered by
  `mise run smoke:monitor-jail`. Startup fails closed unless the guest agent
  completes its readiness request and the local control socket answers the
  same-version monitor handshake. Disk-backed named spores preserve
  immutable-rootfs identity and sealed writable disk indexes; image-created VMs
  use chunked rootfs storage, and explicit `--rootfs PATH` VMs use exact rootfs
  artifacts.
- **The device model stays minimal.** Every device addition expands both the
  attack surface and the portability contract, and requires updating
  `docs/spore-format.md`, this document, and the relevant durable design doc.
  Rootfs growth adds no device, slot, backend-specific register, or manifest
  field: it is a transient, non-resumable feature profile on the existing root
  virtio-blk device, implemented in shared device code and rejected by both
  backends' full-machine save paths.
- **Fuzzing runs continuously in CI**, not as a one-off audit.

## Reporting

This repository is currently private. Report issues directly to the
maintainers. A public disclosure policy lands with the public release.
