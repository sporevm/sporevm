# Security

SporeVM is an isolation boundary written in Zig, which is not memory-safe.
This file names every surface where attacker-influenced bytes enter, the
invariants that hold there, and the fuzz tests that cover it. Change it in the
same change that alters a surface.

## Threat model

| Party | Trust |
| --- | --- |
| Host user | Trusted. Owns the `spore` binary, kernels, the runtime root, the rootfs and kernel caches, and the monitor sockets. Local callers of a monitor are the same user. |
| Guest | Untrusted. Runs hostile code and controls guest memory, virtqueues, MMIO and port I/O exits, vsock streams, network frames, and everything it prints. It must not escape the VMM, crash it, or gain host authority. |
| Images and registries | Untrusted content. OCI manifests, layers, layouts, rootfs tars, image archives, Dockerfiles, and remote `ADD` sources are parsed with bounds and fail closed. Image code runs only as guest code. |
| Image stores | Untrusted transport; every file but a tag is checked against a digest. Through a digest ref a store can only deny service; through a tag it chooses the whole image or checkpoint, including a checkpoint's memory and network policy. |
| Network peers | Untrusted. DNS resolvers, remote `ADD` servers, and guest egress destinations can deny service or return wrong data, but gain no host authority: DNS answers never pass the network hard floor, and an `ADD` server chooses only a file's bytes, its name (reduced to one safe component), and its mtime. |

Local caches share the host user's trust domain: whoever can write them can
also replace the binary or kernel. Cache integrity is enforced where bytes
enter: every install verifies content against the expected digest before
publishing it read-only. Opens trust installed entries without re-hashing
them, but still require a regular file of the exact size with no symlinks, and
fail closed otherwise. This verify-at-install, trust-at-open contract assumes a
per-user cache on a single-tenant host; a shared cache would need open-time
verification and is out of scope.

Not goals:

- Hardened multi-tenant public cloud isolation.
- Secret handling; credential mediation belongs to consumers. Per-exec `--env`
  values are never written to host metadata or manifests, but like any guest
  data they can enter a later save. OCI `Config.Env` is persisted in
  `exec_defaults`, so images must not put credentials there.
- Confidentiality of pushed checkpoints. A checkpoint carries guest memory,
  so its store needs the access control its contents need.

## Rules

- **ReleaseSafe only for shipping builds.** ReleaseFast is for benchmarks;
  release packaging never overrides `build.zig`.
- **Guest RAM goes through `guestmem.GuestRam`**, so bounds checks live in one
  place.
- **Content is verified before use.** A memory chunk, disk object, or index
  read from a checkpoint, store, or archive is checked against its BLAKE3
  digest before it is mapped into guest memory, parsed, or installed.
- **Fail closed.** Unknown versions, unsatisfiable platform contracts, and
  unverifiable content are errors, never degraded behavior.
- **Live runtimes root their storage.** A lazy disk publishes its runtime lease
  under the rootfs cache lock before it opens its index, and keeps it until the
  disk closes, so GC and prune cannot remove an object a running VM may read.
- **Caller paths are validated** before a helper spawns or a socket binds;
  for example, against the 104-byte macOS `sun_path` limit.
- **The device model is frozen**: virtio-mmio console, blk, net, vsock, rng,
  mem, and the generation device. An addition updates
  `docs/spore-format.md`, this file, and the relevant design doc.
- **New parsers come with fuzz tests** in the same change. `zig build test` runs
  every fuzz test over its seed corpus (CI does this on every commit);
  `zig build test --fuzz` searches beyond it.

## Attack surfaces

Fuzz tests are listed by their exact `test` names.

### Virtio devices and VM exits

Input: guest memory, rings, MMIO registers, and x86 port I/O and MMIO exits.

- A queue becomes ready only if its size is a power of two no larger than 256
  and its descriptor table, available ring, and used ring are aligned (16, 2,
  and 4 bytes) and lie wholly inside guest RAM. Otherwise it stays disabled and
  the device reports `DEVICE_NEEDS_RESET`. Size and address writes are ignored
  while a queue is ready. Restore applies the same checks to serialized
  queues.
- Ring index accesses carry acquire/release barriers, so another vCPU's chains
  are parsed only after they are published.
- A chain has at most 64 descriptors, and indirect descriptors are rejected.
  Segments alias guest RAM that other vCPUs can rewrite, so devices read a
  header or payload into host memory once and validate that copy.
- One notify processes at most 256 chains (`queue.max_notify_chains`). On
  aarch64, a virtio-blk notify only wakes the disk's worker thread, which runs
  requests without the device lock and returns them before a queue reset or
  pause proceeds.
- The transport clears `FEATURES_OK` unless the accepted features are a subset
  of those offered, and validates restored feature state.
- `WRITE_ZEROES` is offered only during rootfs growth. A request must be exactly
  a 16-byte header, one range of at most 4 MiB, and a status byte, with only
  `UNMAP`, and is fully validated before any mutation. Full-machine capture
  refuses a transport that offers it.
- vsock drops a guest packet unless its chain holds the whole payload, at most
  64 KiB. Receive splits packets across guest buffers without truncating and
  honors the guest's credit window.
- On x86-64, a port I/O exit must carry at most 4 KiB, and only a fixed list of
  one-byte accesses (CMOS, keyboard-controller status and reset, the `0x80`
  delay) is allowed. MMIO exits must be naturally aligned 1-, 2-, or 4-byte
  accesses inside one device window (8-byte also in the generation window).
  The poweroff doorbell accepts only a 32-bit write of `0x46464f50` at
  offset `0x20` of the generation window; any other write touching it fails,
  and reads return zero. The bzImage planner bounds every offset with checked
  arithmetic and fails before writing guest RAM.
- Restored multi-vCPU GIC state is validated before use.

Fuzz tests: `fuzz virtqueue parsing`, `fuzz mmio register interface`,
`fuzz block request handling`, `fuzz write zeroes state transitions`,
`fuzz console queue handling`, `fuzz net tx handling`, `fuzz net rx delivery`,
`fuzz vsock tx handling`, `fuzz vsock rx delivery splitting`,
`fuzz rng queue handling`, `fuzz virtio-mem queue handling`,
`fuzz generation mmio`, `fuzz multi-vCPU GICv3 validation`,
`fuzz KVM_EXIT_IO envelope decoder`, `fuzz finite x86 PIO policy`,
`fuzz x86 KVM MMIO exit router`,
`fuzz x86 generation control never launders a poweroff`,
`fuzz x86 bzImage parser and placement planner`.

### Guest agent requests and exec streams

Input: guest bytes on vsock, and requests the trusted initrd agent parses.

- SPIO v1 is the only exec stream protocol. Frame headers, stream ids, lengths,
  flags, and offsets are bounded; a malformed frame fails the run.
- The agent parses every request with one strict parser: one newline-terminated
  object, a known type, exactly that type's members once each. Generation
  params are walked in the same pass: members the agent uses must be
  non-negative integers or strings of at most 127 bytes; other members are
  validated and skipped.
- A host unit test checks that the agent's request, argv, environment, path,
  SPIO payload, and retained-output limits match the host's.
- `tty` output and copy stderr are untrusted guest output: the CLI escapes
  control bytes in copy stderr and drops it under `--json`.
- Named create keeps at most 16,381 bytes of initial output per stream in the
  guest, with explicit truncation flags.
- A saved session's output offsets only select what the agent replays from
  output it still holds; any other offset fails the attach.
- The shipped initrd holds only the agent, a pinned Toybox, `/bin/sh`,
  `/bin/true`, and `/bin/false`; smoke helpers need `-Dsmoke-helpers`.

Fuzz tests: `fuzz host stream frame parsing`, and `fuzz guest build request
parser`, which runs the agent's request parser for every request kind with
generation params and runs only on aarch64 Linux.

### Checkpoints, indexes, chunks, and pins

Input: checkpoint directories on disk or pulled from a store; disk indexes;
pin records; runtime disk-fork messages between local monitors.

- `manifest.json` is format v7, at most 64 MiB, and strictly validated before
  anything is mapped; versions 0 to 6 fail as too old. Saves validate the same
  way before writing. Machine state is normalized architectural state, never
  raw KVM or Hypervisor.framework structures.
- Elastic memory is bounded to 8192 blocks of 2 MiB, with sorted,
  non-overlapping ranges checked with overflow-safe arithmetic, and is refused
  on multi-vCPU manifests.
- Memory chunks are 2 MiB and BLAKE3-addressed; zero chunks are elided.
- A disk index is at most 64 MiB, checked against its manifest descriptor's
  BLAKE3 digest before parsing, and must be canonical `spore-disk-index-v2`.
  Ranges that are empty, overlapping, out of order, out of bounds, or
  incomplete are rejected; zero ranges stay compressed, so small input cannot
  force large allocations.
- `ram.backing` and its proof (at most 16 KiB) are optional accelerators,
  opened without following symlinks. The proof is an HMAC, keyed per user,
  over the memory index and the backing file's identity: host-local
  provenance, not byte integrity. Anything absent, stale, or mismatched falls
  back to verified chunks.
- Saved lifecycle metadata are hints. Restore never opens the saved
  `console_log_path`; `exec_defaults` is bounded to 64 environment entries
  and one absolute working directory.
- Pin records are strict versioned JSON of at most 64 KiB; v1 and v2 fail as
  too old. A save is published in order: objects, index, completeness stamp,
  pin, manifest. A pin reference must be a hard link to its cache-side anchor
  with exactly two links, so a copy or extra link fails closed. Unknown or
  corrupt pins make GC keep all CAS storage.
- `spore checkpoint rm` reads only a regular `manifest.json`. A running VM's
  lease names the rootfs cache, not the checkpoint, so removing a checkpoint
  does not affect VMs restored from it.
- Runtime disk forks: prepare and claim requests are strict JSON lines of at
  most 8,192 bytes; a claim needs a 256-bit one-use token; a batch has at most
  32 children, 4 KiB of names, 2 MiB per descriptor and 64 MiB in total. The
  claim reply is one 16-byte frame carrying exactly one `SCM_RIGHTS` fd, which
  must be an unlinked regular `O_RDWR` file of the exact size.

Fuzz tests: `fuzz manifest parsing`, `fuzz memory manifest decoder`,
`fuzz elastic memory state validation`, `fuzz manifest-bound disk index
parser`, `fuzz v2 ranged disk index decoder`, `fuzz saved spore pin parsers`,
`fuzz runtime disk claim request parser`, `fuzz runtime disk claim frame
header`, `fuzz runtime disk fork descriptor parser`.

### Image stores

Input: store refs, tags, and the files a directory, HTTP(S), or S3 store
serves; AWS credentials in the environment.

- Refs are absolute directories, `file:///` paths, `http(s)://` URLs, or
  `s3://bucket/prefix`, with no userinfo, query, fragment, percent escapes,
  backslashes, or empty, `.`, or `..` segments. Tags match
  `[a-z0-9][a-z0-9._-]{0,127}`.
- A tag file is exactly `blake3:<64 lowercase hex>\n`. Over plain HTTP, a tag
  is accepted only from `127.0.0.1` or `[::1]`, since nothing authenticates it;
  digest refs work over any scheme.
- Requests follow no redirects, require status 200 and identity encoding, and
  read at most: tag 72 bytes, manifest 64 KiB, config and index 64 MiB, object
  exactly its indexed length. Only connection failures, timeouts, 429, and 5xx
  are retried. HTTP(S) requests send no credentials. Store hosts are not
  checked against the public-target policy, because stores may be private.
- An image's manifest, config, and index must recompute the requested image
  digest for the selected platform before the index is installed. Explicit
  acquisition/export may select a recorded foreign platform without executing
  it; runtime reads still require the host execution platform.
- `spore image pull` holds the cache lock through missing-object fetch and
  complete image publication, and publishes its requested local tag only after
  the closure is complete. Native ext4 export shares the verified sparse chunk
  assembler, writes an independent caller-writable file, and never replaces an
  existing output or links writable output into immutable cache storage.
- An object is fetched on the first guest read of its chunk (with up to 7
  following chunks in the background) and verified before it reaches guest
  memory or the cache. An HTTP(S) object fetch makes at most 3 attempts within
  10 s. If a read's own fetch fails, the guest gets an I/O error and the disk
  is poisoned and fetches nothing more. Directory stores read only regular
  files but have no deadline.
- Saving a VM whose disk has a store attached first fetches every missing
  object, at most 16 at a time, before memory is written or the cache lock is
  taken. If that fails, the save fails before writing anything, the disk is
  not poisoned, and a named VM keeps running. Stopping a VM cancels the fetch.
- S3 reads go only to `https://<bucket>.s3.<region>.amazonaws.com`; a set
  `AWS_ENDPOINT_URL` or `AWS_ENDPOINT_URL_S3` fails the read. Requests are
  SigV4-signed from the standard `AWS_*` variables, whose characters are
  checked so none can inject a header; the secret and derived keys are zeroed
  after use.
  Credentials never appear in refs, logs, errors, trace output, or the
  catalog. `spore image push` to S3 runs the `aws` CLI on staged, verified
  objects and uploads the tag last.
- `spore checkpoint push` refuses a disk that is not complete locally,
  verifies everything it uploads, drops `memory.backing`, and writes the tag
  last.
- `spore checkpoint pull` accepts a manifest (at most 64 MiB) only if its bytes
  hash to the ref and it decodes. Before creating the output directory, it
  refuses `memory.backing`, a rootfs without a disk, and more than 128 GiB of
  nonzero RAM. Every chunk and object is verified, the disk is leased under
  the cache lock, and the pinned manifest is published last; a fetch failure
  removes the directory. A pulled checkpoint is restore input like any other,
  including its network policy.

Fuzz tests: `fuzz image store tag`, `fuzz image-manifest parser`,
`fuzz canonical image-config parser`; pulled manifests use
`fuzz manifest parsing`.

### Registries, OCI images, tar, and ext4

Input: registry responses, local OCI layouts, rootfs tars, native image
archives, and OCI image configuration.

- Images are built outside the monitor process from digest-pinned refs, and
  every blob is verified.
- Registry fetches require HTTPS. Before each request, including each of at
  most 5 redirects, every resolved address must pass the public-target policy
  in `host_fetch_policy.zig` (no loopback, private, link-local, multicast, or
  reserved targets); at most 4 addresses are tried. Cross-origin redirects
  drop `Authorization`. `SPOREVM_DOCKER_HUB_MIRROR` gets the same policy.
- Platform selection never falls back to another architecture and rejects two
  eligible matches.
- One tar record iterator reads layout tars, layers, and image archives.
  Extraction is path-safe and byte-bounded; PAX xattrs are limited to
  `security.capability`. Layers are applied into ext4 by the native writer
  with no host staging or e2fsprogs.
- `spore image unpack` requires the archive's SHA-256, the image's BLAKE3
  identity, and the platform. It hashes the same open file it parses, accepts
  only the canonical entries, and publishes the local ref last.
- OCI `Entrypoint` and `Cmd` obey the guest request limits; `User` must be root.

Fuzz tests: `fuzz OCI manifest parsing`, `fuzz OCI layout index selection`,
`fuzz OCI layout tar extraction`, `fuzz OCI tar layer parsing`,
`image archive extraction is fuzzed from a packed archive`,
`fuzz native ext4 writer planner and metadata emitter`,
`fuzz OCI root user validation`.

### Monitor socket, protocol, and jail

Input: requests on a named VM's control socket from same-user processes, and
the guest bytes a monitor relays.

- The socket lives in `/tmp/sporevm-control-<uid>` under a digest of the
  runtime root and VM name, bound to the VM's registry directory by an owner
  symlink, so collisions fail closed. That directory and the runtime root
  must be real directories with no group or other permission bits, so only
  the same user can reach a monitor.
- A VM is live while its monitor holds an exclusive `flock` on the entry's
  `lock` file, never by pid. `spore vm rm` deletes an entry only while holding
  that lock; the monitor writes its entry only through a directory fd, and
  reads its configuration, including network policy, from the private spec.
- Startup succeeds only after the guest agent answers its readiness request
  and the socket answers `hello` with schema `spore.monitor.hello.v1`, the same
  SporeVM version, and the same helper contract.
- Requests are a closed set decoded strictly; unknown types, unknown fields,
  and duplicates fail. A request line must arrive within 1 s. The accept thread
  answers `hello`, `shutdown`, and disk-fork claims itself; guest operations run
  on at most 8 handler threads, and further requests get "monitor busy".
- Output frames have a 25 ms send deadline, so a slow client aborts its exec
  instead of blocking the VMM.
- Guest session ids include a random per-monitor nonce, so a restored guest
  cannot replay an earlier monitor's request.
- `spore vm copy-out` treats the guest's archive as hostile: at most 4 GiB;
  relative paths with no empty, `.`, `..`, or NUL components; only regular files
  and directories, created with `O_EXCL` or `mkdirat` under parent fds opened
  one component at a time with `O_NOFOLLOW`, into a destination that must not
  exist; permission bits only. A failure removes the partial destination.
- `spore vm create --options @FILE` is bounded to the lifecycle metadata limit
  and runs the same validators as the flags.
- After spawning its helpers, a monitor denies process execution: on macOS
  with a sandbox profile, on Linux with a seccomp filter that kills any other
  audit arch or any x32 syscall and denies `execve` and `execveat`.
  `test/smoke/monitor/jail.sh` checks it.

Fuzz tests: `fuzz monitor request decoding`, `fuzz copy archive extraction`,
`fuzz create options file parsing`.

### spore-netd and network policy

Input: guest Ethernet frames, DNS answers from the host resolver, and the
policy argument.

- netd bounds every length-prefixed guest frame before parsing it.
- The hard floor (loopback, private, link-local, CGNAT, multicast, and other
  reserved IPv4 ranges) is checked first and wins over unrestricted egress,
  CIDR allows, and DNS-learned hosts.
- DNS learning follows only in-order CNAME chains from the query name within
  one response, with bounded chain length and name decoding.
- Under an allowlist, netd forwards only A/IN queries for allowed names; other
  names get REFUSED and other query types for allowed names get NODATA.
- At most 64 forwarded DNS queries are in flight, each on its own socket; one
  without an answer in 1 s gets SERVFAIL and excess queries are dropped.
- The policy reaches the monitor and netd as one JSON argument with a strict
  parser (every field required, unknown fields rejected) that reruns the CLI
  validators. Egress is `unrestricted` or an `allowlist` (empty denies all
  public egress) with no default, so a missing egress fails closed.
- Bound services pass guest TCP bytes to declared host Unix sockets; their
  providers must treat them as guest-exposed.

Fuzz tests: `fuzz spore-netd frame stream, ARP, IPv4, UDP, and DNS handling`,
`fuzz spore-netd TCP gateway guest frames`,
`fuzz spore-netd TCP Ethernet and IPv4 frame classification`,
`fuzz spore-net policy DNS answer learning`,
`fuzz spore-net policy argument parser`.

### spore build

Input: Dockerfiles, build contexts, remote `ADD` responses, and RUN commands
with everything they do inside the build VM.

- The Dockerfile parser accepts at most 1 MiB and a fail-closed subset;
  expansion is bounded and validated before any fetch or boot.
- The context is walked fd-relative without following symlinks; each input is
  hashed into a private spool and checked for concurrent changes before use.
- Every RUN runs under a trusted supervisor in its own PID, mount, cgroup, IPC,
  and UTS namespaces, with procfs from its PID namespace, masked proc paths, a
  minimal `/dev`, and a cgroup device policy that denies block devices and
  consoles. A seccomp filter kills other syscall ABIs (including x32) and
  denies `io_uring_setup` and `AF_VSOCK` sockets. The capability set excludes
  `CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, and `CAP_NET_ADMIN`. The command inherits
  no initrd fd: every agent fd is close-on-exec. The rootfs is moved over `/`
  before the chroot, as switch_root does, so a nested chroot with the granted
  `CAP_SYS_CHROOT` cannot walk `..` out of it, and as in BuildKit's default
  profile the filter denies `CLONE_NEWUSER` to `clone` and `unshare` and
  returns `ENOSYS` for `clone3`. A setup or cleanup failure blocks every
  publication.
- Cache mounts and context binds are at most 8 each per RUN. Cache IDs become
  BLAKE3 keys, never host paths; binds are read-only regular files whose
  targets must not overlap `/proc`, `/dev`, `/sys`, `/run/sporevm`,
  `/run/buildkit`, or `/etc/resolv.conf`.
- COPY resolves sources and destinations under the rootfs with
  `RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS` or a confined walk, capped at
  65,536 entries.
- Remote `ADD` fetches only public HTTPS URLs: every request and redirect goes
  through `host_fetch_policy.zig`, sends no `Authorization`, and is bounded to
  64 instructions, 1 GiB, and 10 minutes per build. Bodies are staged,
  synced, and hashed before cache lookup. The file name, from
  `Content-Disposition` or the URL path, is joined into the destination, so
  `safeFileName` is the path-traversal guard: it keeps one component that is
  not `.` or `..` and has no control characters. `Last-Modified` sets only
  the mtime. `--chmod` must be octal `0` to `07777`.
- Rootfs growth validates the ext4 superblock in the trusted initrd before the
  first writable mount; the host independently checks the reported geometry.
- Step records are at most 16 MiB and publish only after their storage is
  complete; the destination ref is replaced last and never on failure. Unknown
  future record kinds stay GC roots.

Fuzz tests: `fuzz Dockerfile subset parser`, `fuzz Dockerfile variable
expansion`, `fuzz dockerignore parser`, `fuzz path pattern`,
`fuzz guest build request parser`, `fuzz build control request framing`,
`fuzz build copy request framing`, `fuzz guest copy tree`,
`fuzz guest proc stat parser`, `fuzz guest build resolv target`,
`fuzz remote ADD URL redirect and response scalar parsing`,
`fuzz remote ADD numeric chmod`, `fuzz rootfs grow response parser`,
`fuzz guest ext4 geometry parser`, `fuzz guest ext4 growth source preflight`.

### CLI inputs

Input: caller-supplied files and values.

- `--generation FILE` (`spore run --from`, `spore attach`, `spore vm restore`)
  is at most 3,840 bytes and checked by `generation.validateFanoutParams`: one
  JSON object with every required field, each count nonzero and each index
  below its count, and the strings the agent reads at most 127 bytes without
  NUL. Unit tests cover it; the agent's fuzz test covers the guest's parse.
- `--inject ID=PATH` takes at most 16 regular, non-symlink files and 16 MiB in
  total. They are appended to the initrd and copied into tmpfs in the guest,
  and refused with `--save` and `--from` so they never persist by accident.
- `--commit` publishes only after the command exits zero, the filesystem is
  frozen, and the disk is quiescent, and replaces the ref last.

## Reporting

This repository is currently private. Report issues directly to the
maintainers. A public disclosure policy lands with the public release.
