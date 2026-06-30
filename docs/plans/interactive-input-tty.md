---
status: landed
last_reviewed: 2026-06-30
spec_refs:
  - docs/lifecycle.md
  - docs/libspore.md
  - SECURITY.md
  - src/run.zig
  - src/run_cli.zig
  - src/lifecycle.zig
  - src/monitor.zig
  - src/virtio/vsock.zig
  - guest/minimal-initrd/agent.c
---

# Interactive Input and TTY Support

## Summary

SporeVM should support human interactive commands without weakening the current
script-friendly default. Today `spore run` and `spore exec` stream guest output,
but host input is ignored and the guest process never gets a terminal. That is
the right default for CI, demos, `--events=jsonl`, capture smokes, and embedding,
but it keeps simple workflows like an Alpine shell, `cat` with piped input, or
debugging inside a named VM awkward.

The target user model is Docker-like:

```bash
echo hello | spore run -i --image docker.io/library/alpine:3.20 'cat > /tmp/msg'
spore run -it --image docker.io/library/alpine:3.20 -- /bin/sh
spore exec -it box -- /bin/sh
```

Default stdio remains non-interactive: stdin is closed or ignored, stdout and
stderr stay separate, exit codes remain command exit codes, and JSONL output
continues to be machine-readable. Interactive behavior is opt-in through `-i`
and `-t`.

## Problem

The current guest run protocol is one-way after the initial request. The host
sends one JSON start or attach request over vsock, then the guest agent sends
framed `stdout`, `stderr`, timing, and `exit` records back to the host. `spore
run` writes those frames to host stdout/stderr or JSONL events. Named `spore
exec` uses the same guest stream behind the monitor, but the monitor captures a
bounded stdout/stderr result and returns it over the local control socket.

That model is good for batch commands. It is not enough for:

- shell sessions in image rootfs environments;
- commands that read stdin, such as `cat`, package manager prompts, REPLs, and
  one-off debug scripts;
- terminal-aware programs that need a PTY, window size, job-control signals, or
  line discipline;
- reattaching input to a captured live process that was started interactively.

Trying to make every run implicitly terminal-like would regress the current
copy/paste and automation story. TTY mode merges stdout and stderr, changes
signal behavior, needs raw terminal cleanup, and makes JSONL output semantics
different. It must be explicit.

## Goals

- Preserve the current non-interactive default for `spore run`, `spore run
  --from`, and `spore exec`.
- Add `-i, --interactive` to forward host stdin to guest stdin.
- Add `-t, --tty` to allocate a guest PTY and expose terminal output.
- Support `-it` for the common human shell path.
- Make TTY output explicit in machine events instead of pretending merged PTY
  output is normal stdout/stderr.
- Keep `spore create` non-interactive. It may start a detached command, but it
  should not own the user's terminal.
- Add named interactive `exec` only after the monitor has a streaming control
  path. The existing bounded result path stays the default.
- Allow input attachment to restored live sessions only when the original guest
  session was created with an input-capable stdin or PTY endpoint.
- Fail closed when a backend, guest agent, rootfs environment, or host terminal
  cannot support the requested mode.

## Non-Goals

- No implicit stdin forwarding. Users must pass `-i`.
- No implicit TTY allocation just because host stdin/stdout are terminals.
- No `spore create -it`; use `spore create` followed by `spore exec -it`.
- No SSH-like daemon, TCP terminal service, or central `spore daemon`.
- No terminal multiplexing in the first version. Output-only attach can grow
  later, but input has one owner at a time.
- No attempt to make detached `spore create NAME 'command'` interactive. It
  keeps stdin/stdout/stderr attached to `/dev/null`.
- No public backend-specific CLI. Interactive support is a guest-agent and
  transport feature, not an HVF or KVM user contract.

## Current State

- `spore run` accepts shell commands by default and exact argv after `--`.
- `spore run --from DIR` without a command attaches to the captured default
  session's output stream.
- `spore create NAME 'command'` starts the command detached inside the guest and
  redirects stdio to `/dev/null`.
- `spore exec NAME 'command'` runs a named lifecycle command and prints captured
  stdout/stderr. The monitor response contains bounded base64 stdout/stderr plus
  truncation flags.
- `src/virtio/vsock.zig` parses guest-to-host frames for `stdout`, `stderr`,
  `exit`, `timing`, and `memory-pressure`.
- The current host-initiated vsock stream sends one fixed request payload after
  connect, then only parses guest output. It does not have a reusable
  host-to-guest outbound queue for stdin, resize, signal, or terminal frames.
- The named monitor already has a backend-neutral wake/poll hook that can attach
  a `HostStream` to a running VM. That hook should be reused for later streaming
  named exec instead of adding a second monitor transport.
- Named create starts detached guest commands with stdio redirected to
  `/dev/null`; named attach needs a retained session model before it can be a
  public contract.
- `guest/minimal-initrd/agent.c` starts children with separate stdout/stderr
  pipes or a resumed file-backed fallback. It does not create a stdin pipe or a
  PTY.
- The guest agent currently polls the connected client only for hangup/error.
  It never reads client bytes after the initial JSON request.
- HVF has a console-specific stdin poll path for boot-console input. That path
  is not the `spore run -i` architecture because it is backend-specific, writes
  to the guest console rather than the exec session, and cannot carry named exec
  or attach semantics.
- The minimal initrd mounts `/proc`, `sysfs`, cgroup2, `devtmpfs`, and devpts
  for one-shot PTY allocation.
- `docs/lifecycle.md` now documents `spore run -i` pipe-style stdin,
  `spore run -t/-it` one-shot TTY mode, and input/TTY attach for captured live
  `spore run --from` sessions. It also documents the streaming
  `spore exec -i/-t` named lifecycle path.

## Progress Snapshot

- Slice 1 is implemented, locally reviewed, and committed on
  `lox/tty-input-plan`.
- Slice 2 is implemented and committed. `spore run -t` requests `stdio:"tty"`,
  allocates a guest PTY, streams terminal output on SPIO stream 4, emits JSONL
  `terminal` events, applies resize frames, and uses raw host stdin for `-it`.
- Slice 3 is implemented and committed. `spore run --from` still uses legacy
  output-only attach by default; `-i` or `-t` selects `attach-v1`, validates the
  restored guest session capability, and starts host attachment state fresh for
  each restored spore or forked child.
- Slice 4 is implemented and validated locally. `spore exec -i/-t` uses a
  streaming monitor control request over the local Unix socket, while regular
  `spore exec NAME 'command'` stays on the bounded request/response path. The
  streaming path proxies SPIO stdin, terminal bytes, resize, and exit between
  the CLI and the existing guest `HostStream`.
- Validation for Slices 1-3 passed with `mise run test`, `mise run build`, `git diff --check`,
  `mise run smoke:run`, `mise run smoke:run-stdin`, `mise run smoke:run-tty`,
  and `mise run smoke:run-attach`.
- Slice 4 validation passed with `mise run test`, `mise run build`, `git diff --check`,
  `mise run smoke:lifecycle`, `mise run smoke:lifecycle-tty`, `mise run
  smoke:run-stdin`, `mise run smoke:run-tty`, `mise run smoke:run-attach`, and
  a manual `expect` check for `spore exec -it box -- /bin/sh`.
- Slice 5 is implemented as `spore attach [options] DIR`, a public convenience
  wrapper over commandless `spore run --from DIR`. Named lifecycle
  `spore attach NAME` remains deferred until the monitor owns retained
  attachable sessions.
- Implementation is complete and validated. The final completion audit on
  2026-06-30 re-ran `mise run check`, the focused HVF smoke set, and a
  branch-wide review pass. KVM validation passed on
  `i-08fa4a14319c9c1b5` (`sporevm-ci-apse2-linux-arm64`, c7gd.metal) with SSM
  command `5946c280-a69f-4486-aed8-53d7dbafb7ab`: `smoke:run-stdin ok`,
  `smoke:run-tty ok`, `smoke:run-attach ok backend=kvm`,
  `smoke:lifecycle-tty ok`, and the raw pty checks reported
  `interactive-tty-kvm-smoke ok`.

## Target User Model

### Non-Interactive Default

This remains unchanged:

```bash
spore run --image docker.io/library/alpine:3.20 'echo hi'
spore exec box 'echo hi'
```

Host stdin is ignored. Guest stdout and stderr are separate streams. Exit status
is the guest command exit status.

### Interactive Stdin Without TTY

`-i` forwards bytes from host stdin to guest stdin without allocating a terminal:

```bash
printf 'hello\n' | spore run -i --image docker.io/library/alpine:3.20 'cat > /tmp/msg'
spore run -i --from live.spore
```

In pipe mode, stdout and stderr remain separate. Host EOF sends guest stdin EOF.
If stdin forwarding fails, the guest command should see EOF or the run should
fail before claiming success; silent byte loss is not acceptable.

### TTY Mode

`-t` allocates a guest PTY. `-i -t` forwards host keyboard input as a raw
terminal stream:

```bash
spore run -it --image docker.io/library/alpine:3.20 -- /bin/sh
```

TTY mode has one terminal byte stream. It does not preserve stdout/stderr
separation because the guest program writes through a terminal device. Raw CLI
mode writes terminal output to host stdout. JSONL mode emits a distinct
terminal event, for example:

```json
{"event":"terminal","offset":0,"byte_count":12,"data_base64":"IyA="}
```

`-t` should require host stdout to be a TTY. `-it` should require host stdin and
stdout to be TTYs so raw-mode setup, resize, and cleanup are meaningful. A later
explicit force option can be considered if a real automation case appears.

### Named Lifecycle

Named VMs keep the current batch path:

```bash
spore exec box 'cat /etc/os-release'
```

Interactive named exec is opt-in and streamed:

```bash
spore exec -it box -- /bin/sh
```

The monitor must not implement this by increasing the bounded exec result
buffer. It needs a streaming local control path that can proxy stdin, terminal
output, resize, and exit.

### Attach

`spore run --from DIR` already has an output attach shape when the command is
omitted. Input-capable attach should only work for sessions that were started
with stdin or TTY support:

```bash
spore attach -it live-shell.spore
```

`spore attach DIR` is shorthand for commandless `spore run --from DIR`.

If the captured session used non-interactive `/dev/null` stdin, `-i` or `-t`
attach should fail with a clear error. This keeps capture/fork semantics honest:
guest process and PTY state can be captured, but host terminal ownership is
never part of the spore.

## Protocol Model

Interactive support should not add a second protocol beside the batch path. It
should introduce one framed session protocol where the current non-interactive
run is just a session with stdin disabled, stdout/stderr streams enabled, and no
terminal stream.

Do not use QUIC for this layer. QUIC solves unreliable network transport,
congestion control, encryption, packet loss, and stream scheduling over UDP.
SporeVM already has reliable local transports: virtio-vsock between host and
guest, and Unix sockets between the CLI and named monitors. Pulling QUIC into
the minimal initrd would add a large state machine and dependency surface while
duplicating guarantees the transport already has.

SSH3 is still a useful reference. It keeps the SSH connection model and maps it
onto HTTP/3 and QUIC. SporeVM should copy the connection/session semantics, not
the Internet transport stack. The terms worth preserving are `session`, `exec`,
`shell`, `pty-req`, `window-change`, `signal`, `exit-status`, `eof`, and
`close`.

The useful idea to borrow from QUIC is not QUIC itself; it is typed streams plus
flow-control boundaries. A small Spore-specific frame envelope is enough:

```text
spore-stream-v1 frame:
  magic:        4 bytes  "SPIO"
  version:      u8       1
  type:         u8       data | close | exit | resize | signal | error | event
  flags:        u16
  stream_id:    u32
  offset:       u64
  payload_len:  u32
  payload:      payload_len bytes
```

The exact layout can change during implementation, but the contract should stay
simple: fixed-size little-endian header, bounded payload, no varints, no nested
packet format, and fail-closed parsing. Payloads can remain raw bytes for data
frames and compact JSON for rare control/event frames if that keeps the guest C
agent smaller.

Reserve stream ids by role:

```text
0  control
1  stdin
2  stdout
3  stderr
4  terminal
```

Session setup remains a JSON line for compatibility with the existing agent
entrypoint, but interactive modes must require the v1 stream protocol before
starting a guest command. A first v1-capable agent can accept:

```json
{
  "type": "start-v1",
  "session_id": "default",
  "argv": ["/bin/sh"],
  "stdio": "tty",
  "term": "xterm-256color",
  "winsize": { "rows": 40, "cols": 120 }
}
```

Older agents will reject `start-v1` instead of silently starting a command that
cannot receive input. Non-interactive `start` can keep using the current text
frames until the v1 path is proven; later it can move onto the same frame
envelope without changing user-facing behavior.

The stream model maps every mode:

- batch: no stdin stream, stdout and stderr data streams, exit control frame;
- pipe interactive: stdin, stdout, stderr, and exit;
- TTY: terminal input/output on stream 4, resize control frames, exit;
- attach: claim input ownership for stdin or terminal streams, or attach output
  only without ownership.

Offsets remain monotonic per stream so reconnects and replay errors are
detectable. Unknown frame types, oversized payloads, invalid stream ids, or
offset mismatches fail the session.

### Protocol Architecture

Keep the layers explicit:

1. Transport: reliable local byte streams. One-shot runs use virtio-vsock.
   Named lifecycle uses a Unix socket to the monitor, and the monitor proxies to
   the guest over the same guest stream machinery.
2. Session setup: one newline-terminated JSON request. The first v1 request is
   `start-v1`; it declares argv, environment, working directory, stdio mode,
   and optional terminal metadata.
3. Stream framing: after a successful v1 setup parse, both sides speak the
   fixed binary `SPIO` frame envelope until exit or failure.
4. CLI projection: raw CLI output, JSONL events, named exec results, and future
   attach UX are adapters over the same stream events.

Do not hide SSH/SSH3 semantics inside CLI parsing. The internal session layer
should name the operations directly: `exec`, `shell`, `pty-req`,
`window-change`, `signal`, `exit-status`, `eof`, and `close`. The first slice
only needs `exec`, data frames, EOF/close, and exit status, but the names should
leave the later TTY work obvious.

The first implementation should add one host-side module for the frame codec
and stream state, for example `src/spore_stream.zig`, plus a small C equivalent
inside the minimal initrd agent. The codec should be independent of `spore run`
CLI parsing so `spore exec -it`, `spore attach`, JSONL output, and embedders can
reuse it.

### Host Stream Integration

`HostStream` should become the backend-neutral session connection object. It
already owns request delivery, output parsing, exit state, offsets, and monitor
attachment. Interactive support should extend that object instead of adding
stdin handling directly to `spore run` or to HVF/KVM:

- `HostStream` owns the protocol mode: legacy text frames for existing batch
  requests, and `spore-stream-v1` frames for `start-v1`.
- `HostStream` owns bounded outgoing frame queues for host-to-guest bytes. The
  queue starts with the setup request and then accepts stdin, terminal, resize,
  signal, close, and later attach-control frames.
- Queue capacity remains bounded. If the virtio-vsock pending queue is full,
  producers must stop reading more host input and retry after guest RX progress
  instead of buffering without limit.
- The CLI, monitor, and future embedders are producers and consumers of stream
  events. They should call a small session API such as enqueue input, enqueue
  close, and drain stream events; they should not construct virtio-vsock packets
  or parse `SPIO` headers themselves.
- The backend run loops continue to know only about virtio-vsock device
  progress and wakeups. KVM and HVF should see the same `HostStream` API and
  the same framed bytes.

The first `spore run -i` implementation may use a simple stdin pump attached to
the one-shot run, but the pump must sit above `HostStream`: read bounded bytes
from fd 0, enqueue stdin data frames, send a close frame on EOF, and pause when
the queue reports backpressure. It should not use the existing HVF console
stdin path.

If a `start-v1` request reaches an older guest agent, the older agent will
return a legacy bad-request error or close the stream. The v1 host path should
surface that as an unsupported guest-agent/protocol failure before claiming the
guest command started; it must not silently downgrade to a non-input command.

Flow control should start boring. Do not add protocol-level windows in Slice 1.
Use the reliable stream's blocking/backpressure behavior and avoid unbounded
buffers:

- the host stdin pump writes bounded frames and stops reading stdin when writes
  block;
- the guest agent writes bounded frames and stops reading child output when the
  client cannot keep up;
- reconnect/attach uses offsets to reject impossible replay, not to promise
  unlimited buffering.

If terminal sessions later need independent progress for stdin and output under
heavy backpressure, add explicit per-stream window updates as a later protocol
extension. Do not pay that complexity before the first stdin path proves it is
needed.

## Guest Agent Model

Pipe stdin adds a third pipe to `start_session`: the child gets the read end as
`STDIN_FILENO`, and the agent pumps host `stdin` frames into the write end.
Without `-i`, the child keeps the current non-interactive stdin behavior.

The guest agent should treat v1 as a session mode after parsing the JSON setup
line:

- `start-v1` selects the binary frame parser for the connected client before
  the child is started.
- The main poll loop watches the client fd for readable bytes as well as
  hangup/error while a v1 session is active.
- Incoming data frames for stream 1 are written to the child stdin endpoint.
  A close frame closes that endpoint and gives the child EOF.
- Guest-side input buffering is bounded. If the child stdin pipe cannot accept
  more bytes, the agent should stop reading the client until the pending data
  is drained rather than accumulating arbitrary input.
- Legacy `start` and `attach` keep the current text-frame behavior until they
  intentionally migrate to v1.

TTY mode should:

- mount devpts before trying to allocate a PTY;
- open a PTY master/slave pair inside the guest;
- fork, call `setsid`, make the PTY slave the controlling terminal, and dup the
  slave to stdin/stdout/stderr;
- set the initial window size before releasing the child from the start gate;
- pump host terminal-input frames into the PTY master;
- pump PTY master output into terminal frames;
- apply resize frames with `TIOCSWINSZ`;
- close the input side on host EOF without killing the child;
- report child exit using the same exit frame contract.

Rootfs commands need this to work both in the minimal initrd and after chroot.
The agent owns PTY creation before chroot, then passes the slave fd into the
child, so distro rootfs contents do not need to provide `/dev/ptmx` for the
first slice.

## Host CLI Model

The host CLI owns terminal policy:

- parse `-i`, `--interactive`, `-t`, and `--tty` for `spore run`;
- reject `-t` when stdout is not a TTY;
- reject `-it` when stdin is not a TTY;
- put host stdin in raw mode only for `-it`;
- restore terminal settings on normal exit, guest failure, host signal, and
  event-sink failure;
- forward SIGWINCH as resize frames;
- keep Ctrl-C in `-it` as input to the guest terminal rather than host process
  termination, unless raw-mode setup fails before the guest starts;
- preserve current SIGINT/SIGTERM capture behavior for non-TTY runs.

`spore exec -it` should reuse the same host terminal helper once the monitor can
stream.

## Safety Model and Invariants

- Non-interactive behavior stays byte-for-byte compatible unless `-i` or `-t`
  is requested.
- TTY mode is explicit because it merges stdout and stderr.
- Unsupported interactive modes fail before starting a guest command when
  possible.
- Terminal raw mode must always restore the host terminal.
- Input is single-owner. A second input-capable attach is rejected while one is
  active.
- Output replay is best-effort for bounded pipe streams only. TTY sessions do
  not promise full scrollback replay.
- Host-to-guest stdin frames are bounded and backpressured; unbounded buffering
  in the VMM is not allowed.
- The VMM remains backend-neutral. KVM and HVF see the same virtio-vsock bytes.
- Any new host parser for guest-originated frames gets unit and fuzz coverage
  consistent with `SECURITY.md`.

## Delivery Strategy

### Slice 1: Pipe Stdin for `spore run -i`

Add non-TTY stdin forwarding for one-shot `spore run`.

Scope:

- parse `-i` and `--interactive` in `src/run.zig`;
- add the `start-v1` request shape and a small binary Spore stream v1 frame
  parser/writer;
- support stdin, stdout, stderr, close, and exit frames in the v1 path;
- keep the frame codec separate from CLI parsing so named lifecycle can reuse
  it later;
- extend `HostStream` with a bounded host-to-guest frame queue and a small
  enqueue/drain API for stdin and EOF frames;
- add a one-shot stdin pump above `HostStream` that pauses on backpressure
  rather than buffering unbounded input;
- add a guest stdin pipe in `guest/minimal-initrd/agent.c`;
- make the guest agent read v1 client frames and pump stdin data to the child,
  closing the pipe on EOF;
- keep the existing text-frame path for non-interactive runs while the v1 path
  is proven;
- document the flag in `README.md`, `docs/lifecycle.md`, and
  `guest/minimal-initrd/README.md`.

Done when:

- `printf hi | spore run -i -- /bin/cat` prints `hi`;
- omitting `-i` still gives the command EOF or ignored stdin;
- `--events=jsonl` continues to emit stdout/stderr/exit events while reading
  input from host stdin;
- a `start-v1` request against an old or non-v1 guest agent fails clearly
  instead of running the command without stdin;
- the host stdin pump observes backpressure from the bounded vsock queue and
  does not grow an unbounded buffer;
- malformed headers, unknown frame types, oversized payloads, invalid stream
  ids, and out-of-order offsets fail closed in host and guest tests;
- `mise run test`, `mise run build`, `git diff --check`, and a focused
  `smoke:run`-style stdin smoke pass.

### Slice 2: One-Shot TTY for `spore run -t`

Add PTY allocation and host terminal handling for one-shot runs.

Scope:

- add `-t` and `--tty` parsing;
- add devpts setup in the minimal initrd;
- add guest PTY allocation and child controlling-terminal setup;
- add terminal output, input, EOF, and resize frames;
- add host raw-mode guard and restoration helper;
- add a JSONL terminal event or reject `--events=jsonl --tty` until that event
  schema lands in the same slice;
- update `SECURITY.md` for the new frame parser and PTY attack surface.

Done when:

- `spore run -it --image docker.io/library/alpine:3.20 -- /bin/sh` gives a
  usable shell on supported hosts;
- terminal size is visible inside the guest with a simple `stty size` or
  equivalent test helper;
- Ctrl-C reaches the guest shell instead of killing the host `spore` process;
- host terminal settings are restored after normal exit and after a killed
  `spore` client in the smoke harness;
- non-TTY stdout rejects `-t` before guest start.

### Slice 3: Interactive Attach for `spore run --from`

Extend attach requests so restored live sessions can regain input when the
captured guest session was created with stdin or a PTY.

Scope:

- persist enough guest session metadata in the agent process state to know
  whether stdin or PTY attach is valid after restore;
- allow attach requests to claim input ownership;
- reject input attach for non-interactive sessions;
- handle EOF and client disconnect without corrupting the guest session;
- keep output-only attach available without input ownership.

Done when:

- a shell started with `spore run -it --capture-on USR1 --continue-after-capture`
  can be captured and later attached with `spore attach -it DIR`;
- a non-interactive captured command rejects `-i --from DIR` with a clear
  message;
- forked children can be attached independently, with host attachment state
  starting fresh per child.

### Slice 4: Streaming Named `spore exec -i/-t`

Add a streaming monitor control mode for interactive named exec.

Scope:

- keep current `spore exec NAME 'command'` as bounded request/response;
- add a streaming control request type for interactive exec;
- proxy stdin, terminal output, resize, and exit between the local CLI and the
  existing guest run stream;
- enforce one active interactive exec per monitor;
- expose busy errors consistently with existing monitor `ControlBusy`.

Done when:

- `spore exec -it box -- /bin/sh` works on a named VM;
- regular `spore exec box 'echo hi'` still returns bounded stdout/stderr and
  JSON output as before;
- killing the local CLI releases input ownership or fails closed so later
  `spore exec` calls are not permanently wedged;
- `mise run smoke:lifecycle` still passes and a new interactive lifecycle smoke
  covers the streaming path.

### Slice 5: Public `spore attach` Convenience

Add `spore attach` only after the lower-level attach semantics are proven.

Scope:

- `spore attach DIR` attaches output to a captured product spore's default
  session;
- `spore attach -i DIR` claims input ownership if the captured session supports
  stdin;
- `spore attach -it DIR` attaches to a captured PTY session;
- commands remain explicit through `spore run --from DIR 'command'`;
- named lifecycle `spore attach NAME` is deferred because current named create
  stdio is detached and there is no retained default session to attach to.

Done when the command is only a thin CLI wrapper over already-tested attach
contracts.

## Verification

Unit and parser checks:

- CLI parsing for `-i`, `--interactive`, `-t`, `--tty`, invalid combinations,
  and `--events=jsonl --tty` policy.
- Host frame parser tests for stdin, terminal input, terminal output, resize,
  EOF, oversized frames, malformed headers, and offset mismatches.
- Guest-agent request parsing tests for stdin/tty fields and unknown fields.
- Terminal helper tests for best-effort raw-mode restoration where the host OS
  permits it.

Smoke checks:

```bash
mise run smoke:run
mise run smoke:lifecycle
scripts/smoke-run-stdin.sh
scripts/smoke-run-tty.sh
scripts/smoke-run-attach.sh
mise run smoke:lifecycle-tty
```

Manual checks for TTY slices:

```bash
spore run -it --image docker.io/library/alpine:3.20 -- /bin/sh
spore create box --image docker.io/library/alpine:3.20
spore exec -it box -- /bin/sh
```

Security and regression checks:

- update `SECURITY.md` in the TTY slice;
- keep fuzz coverage for guest-originated host frames current;
- run `mise run check`;
- run platform smoke on both HVF and KVM before calling TTY support complete.

## Resolved Decisions

- Default stdin stays closed or ignored.
- `-i` and `-t` are separate flags, with `-it` as the normal shell spelling.
- `spore create` does not get interactive terminal ownership.
- Interactive and non-interactive execution should converge on one session
  protocol, but the user-facing semantics remain distinct.
- Slice 1 should introduce `spore-stream-v1` with `spore run -i`, not add a
  temporary stdin extension to the legacy text-frame protocol.
- The unified protocol should be a small Spore stream frame envelope over
  reliable local transports, not QUIC.
- SSH3 is the closest off-the-shelf design reference, but only for the SSH
  connection protocol vocabulary and channel lifecycle. SporeVM should not
  embed HTTP/3, QUIC, TLS, or HTTP authentication in the guest control plane.
- Protocol-level flow-control windows are deferred until measurements or TTY
  behavior show that transport backpressure is not enough.
- Named interactive exec requires a streaming monitor path; it will not reuse
  the bounded result response.
- `HostStream` is the reusable session connection boundary for both one-shot
  runs and named monitor streams. CLI stdin, terminal raw mode, and future
  monitor control sockets are adapters above it.
- HVF console stdin polling is not used for exec stdin. Interactive exec input
  travels over the same guest-agent session stream on every backend.
- TTY output is one terminal stream and should be represented distinctly in
  machine events.
- Slice 2 emits JSONL `terminal` events for `--events=jsonl --tty` instead of
  rejecting that combination.
- Host attachment state is not part of a spore. Guest PTY/process state can be
  captured and forked; each restored child gets fresh host attachment ownership.

## Deferred Questions

- Should `-t` imply `-i`?

  Recommended default: no. Match Docker's separate concepts: `-t` allocates a
  terminal, `-i` keeps stdin open. Users can still use the familiar `-it`.

- Should TTY sessions keep replay buffers?

  Recommended default: no for the first version. Pipe-mode replay is useful for
  deterministic output streams; terminal scrollback replay has unclear UX and
  can grow memory pressure in long interactive sessions.

## Key Learnings From Pressure-Testing

- The risky part is not the hypervisor. It is host terminal cleanup, guest PTY
  setup, and bidirectional stream backpressure. The delivery strategy therefore
  starts with non-TTY stdin and delays named interactive exec until streaming
  monitor control exists.
- The existing host vsock stream is one-shot request plus guest output. Slice 1
  must add a bounded host-to-guest queue to `HostStream`; adding `-i` without
  that boundary would bake stdin into one CLI path and make named exec/attach
  harder later.
- The existing guest agent does not read from the client after setup. The v1
  guest mode therefore needs real client read polling and bounded stdin pipe
  draining, not just a new request field.
- The older HVF console input hook is the wrong abstraction for `spore run -i`.
  It is useful evidence that host input has been handled before, but the
  interactive exec contract must flow through the guest session protocol.
- Adding ad hoc text frames for stdin and TTY would work for one slice but would
  make attach, named exec, resize, and input ownership harder to reason about.
  The plan now introduces a small typed frame envelope before adding TTY.
- QUIC is the wrong layer for local vsock and Unix-socket transports. The plan
  borrows stream ids and bounded flow-control ideas without importing QUIC's
  network transport machinery.
- SSH3 pressure-tests the decision usefully: it points at SSH's connection
  protocol as the durable abstraction, while showing why the network/auth
  layers are the part SporeVM should leave behind.
- `spore exec` cannot become interactive by enlarging its captured output
  buffer. That would hide deadlocks and still not solve input, resize, or raw
  terminal behavior.
- TTY mode must not be folded into stdout/stderr. It changes the contract, so
  the plan adds a terminal stream and records the JSONL schema decision
  explicitly.
- Captured host attachment is a trap. The spore should contain guest process and
  PTY state, not host terminal ownership, so every restore or fork starts with a
  fresh input owner.
- The minimal initrd currently mounts `devtmpfs` but not devpts. TTY support has
  a concrete guest setup prerequisite, not just a CLI flag.
