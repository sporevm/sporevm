---
status: active
last_reviewed: 2026-06-27
spec_refs:
  - docs/plans/foundation.md
  - SECURITY.md
  - https://github.com/lox/zmoltcp
  - https://github.com/lox/zmoltcp/pull/1
  - /Users/lachlan/Develop/zmoltcp/src/stack.zig
  - /Users/lachlan/Develop/zmoltcp/src/socket/tcp.zig
  - build.zig.zon
  - src/zmoltcp_gateway.zig
  - src/virtio/net.zig
  - src/run.zig
  - src/net_gateway.zig
  - src/spore_net_policy.zig
  - src/hvf/vm.zig
  - src/kvm/vm.zig
  - guest/minimal-initrd/
related_plans:
  - docs/plans/foundation.md
  - docs/plans/lifecycle-monitor.md
---

# Minimal spore-netd Plan

## Summary

SporeVM already exposes a virtio-net device on the fixed board, but it is a
closed endpoint: guest TX descriptors are drained and counted, RX never supplies
packets, and no host network backend is attached. This plan makes `spore run
--net` a real guest-network capability by adding a SporeVM-owned userspace
gateway instead of depending on host TAP/NAT or a C user-mode networking engine.
The guest-facing ARP/IPv4/TCP implementation should come from the pinned
`lox/zmoltcp` Zig fork behind a SporeVM adapter, with SporeVM retaining
ownership of host sockets, DNS, lifecycle, policy, and observability.

The end state is not `--net tap:<ifname>`. The user-facing contract is policy:
`spore run --net` attaches the guest to a SporeVM-managed virtual network with
fail-closed egress policy. Host adapters, helper processes, sockets, and packet
transport are implementation details.

The first useful version should be deliberately narrow: IPv4, static guest
configuration, ARP for the gateway, DNS UDP/53 proxying, outbound TCP proxying,
bound guest-local services, machine-readable network events, and a hard default
egress floor. Captured spores now persist the requested network capability and
allow policy so `spore run --from` can attach a fresh gateway under the same
rules. Published ports, general UDP, IPv6, DHCP, and live-flow preservation
across suspend/resume are later work.

## Problem

The current virtio-net device is present but not connected to anything. That is
good for keeping the device model frozen, but it creates a misleading product
surface: a guest can see a network device shape without receiving usable egress.

Host-side image fetches and artifact distribution can use the host network, but
guest workload egress is different. Workloads need a clear opt-in capability,
policy that is enforced outside the guest, and behavior that remains portable
between KVM and Hypervisor.framework.

Using host TAP plus NAT would make the first demo faster on Linux, but it would
shape the product around privileged, host-specific networking. SporeVM should
instead own the virtual link boundary and keep the gateway backend-neutral.

## Goals

- Add a user-facing `spore run --net` capability for one-shot guest egress.
- Keep the public contract backend-neutral across KVM and HVF.
- Keep the VMM responsible for virtio queues and raw Ethernet frames only.
- Put DNS, TCP proxying, policy, logging, and flow lifetime in `spore-netd`.
- Use the pinned `lox/zmoltcp` dependency as the bounded guest-facing
  ARP/IPv4/TCP engine.
- Fail closed when networking is requested but unsupported, partially started,
  or policy cannot be enforced.
- Preserve the frozen device model: this activates the existing virtio-net
  device rather than adding a new guest-visible device.
- Add fuzz coverage for new guest-controlled parsers and virtqueue paths in the
  same slices that introduce them.

## Non-Goals

- No TAP, bridge, pf, iptables, or platform NAT as the default product path.
- No dependency on libslirp, libvdeslirp, gvisor-tap-vsock, or passt for the
  first owned gateway. The intended dependency is a pinned Zig source dependency
  on `lox/zmoltcp`, not a host networking daemon or C library.
- No hand-rolled SporeVM TCP stack for the first owned gateway.
- No SporeVM-specific code in `zmoltcp`; fork or upstream work should stay as
  generic user-mode gateway and TCP-forwarder primitives.
- No DHCP in the first version. Guest config is static and passed through the
  existing boot/init contract.
- No published ports in the first version.
- No general UDP beyond DNS UDP/53 in the first version.
- No IPv6 in the first version.
- No attempt to preserve live TCP connections across suspend, resume, fork, or
  host movement.
- No public multi-tenant hardening claim beyond the repository's current
  self-hosted CI/agent isolation threat model.

## Target Model

The public CLI starts small:

```console
spore run --net -- /bin/nslookup example.com
spore run --net -- /bin/sh -lc 'wget -qO- http://example.com/'
spore run --net --bind-service metadata=unix:/tmp/metadata.sock -- /bin/wget -qO- http://metadata.spore.internal/
spore run --net --events=jsonl -- /bin/wget -qO- http://169.254.169.254/
```

Networking is off by default. `--net` means "attach the guest to a
SporeVM-managed virtual network." The default policy allows outbound public
egress but blocks dangerous host/control-plane destinations. When allow rules
are present, egress is restricted to the configured hosts and CIDRs. The landed
bound-service shape is one explicit guest-local name backed by a host Unix
stream socket; it does not replace the egress policy and is not a published host
port. Loopback TCP targets are deferred.

The internal data path is:

```text
guest eth0
  -> virtio-net rings
  -> src/virtio/net.zig
  -> length-prefixed Ethernet frame stream
  -> spore-netd
  -> host DNS/TCP sockets or bound host-local services
```

The initial static link uses fixed addressing:

```text
guest MAC:    02:53:50:4f:52:45
gateway MAC:  02:53:50:4f:52:01
guest IPv4:   100.96.0.2/30
gateway IPv4: 100.96.0.1
DNS:          100.96.0.1
MTU:          1500
```

The exact addresses can change before implementation, but the first slice should
avoid address allocation, DHCP, or multiple guests per virtual network.

## Ownership Boundaries

- `src/virtio/net.zig` owns virtio-net feature negotiation, config space,
  descriptor parsing, RX/TX queue movement, interrupts, backpressure, and
  translating guest-visible packets into complete Ethernet frames.
- `lox/zmoltcp` owns the guest-facing ARP/IPv4/TCP state machine.
- `spore-netd` owns the adapter around `zmoltcp`, DNS forwarding, egress policy
  checks, host socket creation, flow lifetime, timeouts, logging, and shutdown.
- `src/run.zig` owns the user-facing `--net` option, helper startup, boot args,
  `--bind-service` declarations, event wiring, and fail-closed orchestration.
- KVM and HVF own only their usual MMIO/IRQ/wakeup plumbing. They must not grow
  backend-specific network policy.
- The guest initrd owns static `eth0` setup from boot args or the generation
  device. It must not assume `ip`, DHCP client, or other external tools are
  available.

## Safety Model

`--net` widens the attack surface. The safe default is:

- Fail closed if `spore-netd` cannot start, cannot enforce policy, or exits
  before the guest exits.
- Block host loopback, link-local metadata addresses, private/control-plane
  ranges, unspecified/broadcast addresses, and the gateway's own internal range
  by default.
- Do not expose the host's original peer addresses to the guest in v0.
- Do not let DNS answers override the hard floor.
- Do not let bound services open arbitrary host paths. Each service must be
  declared explicitly, use a valid guest-local name, and reattach fresh on
  resume or fail closed.
- Bound all frame, packet, DNS, and TCP state sizes.
- Treat malformed Ethernet/IP/DNS/TCP packets as guest-controlled input and
  either drop them or reset the guest flow without panicking.
- Update `SECURITY.md` when the new parser/device surfaces land.

## Current State

- `src/virtio/net.zig` advertises a MAC address and now has an internal frame
  backend boundary. Guest TX descriptors are parsed as virtio-net headers plus
  complete Ethernet frames, and backend RX frames can be injected into guest
  writable descriptors. The default backend remains closed, so this still does
  not provide host connectivity.
- `src/hvf/vm.zig` and `src/kvm/vm.zig` instantiate the network device with a
  backend-neutral `net.Runtime`. The default runtime remains closed; `spore run
  --net` supplies the helper-backed runtime.
- `spore run` now accepts `--net`, records the requested SporeVM-managed
  network capability in `run.Options`, starts the hidden `spore netd --stdio`
  helper, waits for readiness before VM start, and fails the run if the helper
  exits while networking is active. Normal `spore run` invocations still
  default to closed networking.
- `src/spore_netd.zig` implements a bounded little-endian length-prefixed
  Ethernet frame stream over inherited stdio fds, debug frame logging, clean EOF
  shutdown, ARP replies for the fixed gateway MAC/IP, and narrow IPv4 UDP/53 DNS
  proxying through the host resolver. Frame bounds, ARP handling, IPv4/UDP DNS
  dispatch, DNS name parsing, and malformed DNS handling have unit and fuzz
  coverage.
- `src/spore_netd_tcp.zig` now adapts the pinned `zmoltcp` forwarder into a
  bounded outbound TCP proxy. It keeps the hard egress floor outside the guest,
  denies blocked destinations before opening host sockets, relays accepted
  flows through nonblocking host `connect()` sockets, and bounds flow count,
  buffers, connect timeout, and idle lifetime.
- `src/spore_net_policy.zig` now owns the explicit egress policy model. With no
  allow rules, public IPv4 egress is allowed after the hard floor. When
  `--allow-cidr` or `--allow-host` is supplied with `--net`, public egress is
  restricted to exact CIDR matches or DNS A answers learned through the
  SporeVM DNS proxy for the configured host; the hard floor still wins.
- `src/net_gateway.zig` owns helper startup, stderr readiness, deterministic
  shutdown, SIGPIPE-safe helper writes, and the parent-side virtio-net backend
  adapter. Helper RX frames wake the hypervisor loop, which explicitly flushes
  pending virtio-net RX buffers and raises the existing net-device interrupt on
  both HVF and KVM.
- The minimal initrd agent now reads the `spore_net=1` boot flag, waits for
  `eth0`, assigns the fixed guest IPv4 address and netmask, brings the link up,
  installs the default route through the gateway, and writes resolver config
  pointing at the gateway. The setup uses syscalls and proc/sys files directly;
  it does not require `ip`, DHCP, or other guest tools. The `/bin/netcheck`
  helper and `scripts/smoke-run-net-config.sh` inspect the resulting interface,
  route, resolver, and gateway ARP entry.
- The minimal initrd now also includes `/bin/nslookup` and `/bin/wget`, tiny
  static smoke helpers used by the DNS and HTTP network smokes to prove guest
  DNS queries and outbound TCP flows reach the host-side proxy.
- `SECURITY.md` already treats virtqueue descriptors and device request headers
  as guest-controlled attack surface requiring fuzz targets.
- `build.zig.zon` now pins `lox/zmoltcp` at `v0.2.12`, which includes the
  generic IPv4 TCP forwarder API from PR #1 and the follow-up parser validation
  fixes. The dependency is wired into the `sporevm` module, and
  `src/zmoltcp_gateway.zig` contains a compile-level contract test proving
  SporeVM can build against the caller-owned forwarder surface.
- One-shot and named lifecycle integration have landed for captured network
  spores: capture records requested network capability and policy, `spore run
  --from` and named `spore resume --name` reattach a fresh helper-backed gateway
  under the recorded policy, and live TCP flow state remains non-portable.
- `spore run --net --bind-service NAME=unix:/path.sock` now supports one
  non-named run service: `NAME.spore.internal` resolves to the gateway IP and
  guest TCP port 80 proxies bytes to the declared host Unix stream socket. More
  than one bound service still fails before VM startup.
- Denied TCP egress now emits typed `--events=jsonl` network audit events via
  the existing `spore-netd` stderr and parent gateway path. Bound service
  availability events are not implemented yet.

## Delivery Strategy

### Slice 1: Explicit Closed Networking Contract

Status: landed in the Slice 1 branch; the temporary development gate was
removed when the Slice 3 helper startup path landed.

Add the `--net` CLI option and plumb it through `run.Options`, but keep it
failing closed with a clear "not implemented" error unless an internal
development flag is set.

Definition of done:

- `spore run --net -- ...` parses.
- The help text documents that networking is experimental and disabled until the
  gateway lands.
- No guest behavior changes when `--net` is absent.
- Unit tests cover parsing and the fail-closed path.

### Slice 2: Frame Stream Boundary

Status: landed in the Slice 2 branch.

Turn the existing closed virtio-net device into a real frame producer/consumer
behind an internal backend interface. The first backend can be an in-process
test harness, not `spore-netd`.

Definition of done:

- TX queue extracts complete Ethernet frames from guest descriptors.
- RX queue can inject complete Ethernet frames into guest writable descriptors.
- Backpressure and empty-RX behavior are explicit.
- Unit tests and fuzz targets cover malformed descriptor chains, short virtio
  net headers, oversized frames, queue exhaustion, and reset/shutdown behavior.

### Slice 3: `spore-netd` Skeleton

Status: landed in the Slice 3 branch.

Add a small helper binary or internal subcommand that speaks the frame protocol
over a Unix socket or inherited fd. At this slice it only logs frames, answers
ARP for the gateway, and shuts down cleanly with the VM.

Definition of done:

- `spore run --net` starts and stops `spore-netd` deterministically.
- The guest can resolve the gateway MAC through ARP once guest setup exists.
- Helper failure before ready prevents VM start.
- Helper failure during a run tears down the run with a clear error.

### Slice 4: Static Guest Network Setup

Status: landed in the Slice 4 branch.

Teach the minimal initrd to configure `eth0` from boot args or generation-device
fields.

Definition of done:

- The guest has `eth0` up with the static MAC/IP, default route via the gateway,
  and `/etc/resolv.conf` pointing at the gateway.
- The setup path does not require external guest tools.
- A smoke command can inspect the address, route, and DNS config inside the
  guest.

### Slice 5: DNS Proxy

Status: landed in the Slice 5 branch.

Implement ARP, IPv4 parsing, UDP/53 dispatch, basic DNS query forwarding through
the host, and response injection back to the guest.

Definition of done:

- `spore run --net -- /bin/nslookup example.com` succeeds.
- Malformed DNS packets are dropped or SERVFAILed without crashing.
- DNS answers cannot add exceptions to the hard egress floor yet.
- Unit tests cover DNS parser bounds, name compression limits if supported, and
  response routing.

### Slice 6: `zmoltcp` TCP Forwarder Dependency

Status: landed. `lox/zmoltcp` PR #1 is merged, SporeVM pins `v0.2.12`, and
the SporeVM test suite compiles against the forwarder contract.

Land or import a generic `zmoltcp` TCP-forwarder primitive that lets a
user-mode gateway accept non-local IPv4 TCP SYNs carried in Ethernet frames
addressed to the gateway MAC. This belongs in `lox/zmoltcp`, and should stay
generic enough for gateways, NATs, and proxies rather than naming SporeVM.

Definition of done:

- `zmoltcp` can offer otherwise-unhandled non-local IPv4 TCP SYNs to caller
  policy with full source and destination endpoints.
- The caller can deny before state is created, or accept with caller-owned
  socket/buffer storage from a bounded pool.
- Accepted flows route subsequent packets by tuple without requiring a
  `listen(port)` socket for every possible public destination port.
- Default `zmoltcp` behavior is preserved: non-local TCP is dropped unless the
  forwarder is configured.
- `zig build test` and `zig build demo` pass in `lox/zmoltcp`, with focused
  tests or a demo for non-local gateway forwarding.
- SporeVM pins the fork or release tag only after the forwarder API is present.

### Slice 7: Outbound TCP Proxy

Status: implemented in the Slice 7 branch.

Integrate the `zmoltcp` forwarder into `spore-netd` so guest TCP flows terminate
at the gateway and relay payloads to host `connect()` sockets.

Definition of done:

- `spore run --net -- wget -qO- http://example.com/` succeeds against a stable
  HTTP target.
- A connection to `169.254.169.254:80`, `127.0.0.1:80`, and representative
  private ranges is denied before a host socket is opened.
- FIN/RST, timeout, and host-connect failure behavior is deterministic.
- Flow count, buffer sizes, and per-flow lifetime are bounded.

### Slice 8: Policy and Observability Hardening

Status: implemented in the Slice 8 branch.

Make the default egress floor explicit and add user-selectable allow rules after
the baseline path is working.

Definition of done:

- `--allow-cidr` and `--allow-host` are either implemented or explicitly
  rejected when paired with `--net`.
- Denied egress is visible in debug logs without leaking sensitive guest data.
- Policy tests cover exact CIDR matches, DNS-rebinding-style answers, and hard
  floor precedence.

### Slice 9: Lifecycle Integration

Status: implemented in the Slice 9 branch.

Define how networking behaves for capture, resume, fork, and named lifecycle.

Definition of done:

- Captured spores record requested network capability and policy, not live
  gateway flow state.
- Resume either reattaches a fresh network gateway under the same policy or
  fails closed if the policy cannot be satisfied.
- Live TCP flows are explicitly dropped across suspend/resume/fork.
- Named lifecycle support reuses the same policy persistence and fresh-gateway
  resume contract as one-shot `spore run --net`.

### Slice 10: Bound Services and Network Events

Status: implemented for non-named `spore run`; broader bound-service
capabilities are deferred below.

Expose explicitly declared host-local services to the guest while keeping
SporeVM-owned networking and egress policy in `spore-netd`. The implemented
service target is a host Unix socket; TCP loopback targets can follow if needed.
Network audit events should flow through the existing `--events=jsonl` run event
stream instead of a separate telemetry subsystem.

Target CLI:

```console
spore run --net --bind-service metadata=unix:/tmp/metadata.sock -- /bin/wget -qO- http://metadata.spore.internal/
spore run --net --events=jsonl -- /bin/wget -qO- http://169.254.169.254/
```

Definition of done:

- `--bind-service NAME=unix:/path.sock` parses only with `--net`, rejects invalid
  names and targets, starts the VM fail-closed when a declared service cannot be
  represented, and keeps the bound service guest-local.
- The first landed shape is deliberately capped at exactly one Unix stream
  target, the default guest HTTP port 80, and the gateway IP returned for
  `NAME.spore.internal`. TCP host targets, custom guest ports, multiple service
  IPs, and application-layer `Host` parsing are deferred.
- `spore-netd` accepts guest TCP/80 connections to the gateway for the configured
  bound service and proxies bytes to the configured host Unix socket without
  opening general egress. Ordinary DNS forwarding, outbound TCP proxying, and
  hard-floor denied-egress events stay on their existing paths.
- `--events=jsonl` emits typed denied-egress network events with destination,
  port, and denial reason but no guest payload bytes. Bound service availability
  events are deferred until there is a concrete consumer.
- Captured/named spores do not persist or re-bind service declarations in this
  slice; `spore run --capture --bind-service ...` fails before startup until
  manifest/schema work can record the re-bind contract. Live service connections
  remain non-portable and are dropped across suspend/resume/fork.
- Unit tests cover CLI parsing, service-name validation, target validation,
  deny-event formatting, and policy precedence between bound services and normal
  egress.

## Verification

- Unit tests: CLI parsing, network config serialization, virtio-net RX/TX queue
  behavior, frame protocol encode/decode, ARP, IPv4 checksum, DNS parsing,
  `zmoltcp` adapter behavior, TCP forwarder policy decisions, egress policy,
  bound-service parsing, and network event formatting.
- Fuzzing: virtqueue descriptors, Ethernet frame parsing, IPv4 packet parsing,
  DNS packet parsing, TCP segment parsing, frame-stream decode.
- Product smokes: guest address/route inspection, DNS lookup, outbound HTTP,
  hard-floor denial, helper crash before ready, helper crash during run.
  `mise run smoke:run-net-http` covers the first outbound HTTP path with the
  minimal initrd `/bin/wget` helper.
  `mise run smoke:run-net-deny` covers hard-floor denial, debug visibility, and
  JSONL denied-egress events.
  `mise run smoke:run-net-capture` covers manifest policy persistence and
  fresh gateway reattachment through `spore run --from`.
  `mise run smoke:run-net-bind-service` covers the Unix-socket bound-service
  proxy path.
- Backend smokes: the same one-shot network smoke on HVF and KVM.
- Regression checks: no behavior change for `spore run` without `--net`,
  capture without network, rootfs-backed run, and lifecycle commands.
- Security review: update `SECURITY.md` and re-check the monitor/helper jail
  implications before treating the feature as release-ready.

## Key Learnings From Pressure-Testing

- A TAP/NAT first slice would be tempting but would create a Linux-shaped public
  mental model. The plan keeps TAP out of the user contract and starts with the
  portable frame boundary.
- Writing a SporeVM TCP/IP stack is too broad. The plan now uses the `lox/zmoltcp`
  Zig fork as the guest-facing stack and keeps SporeVM focused on the gateway
  adapter, host sockets, DNS, policy, and lifecycle.
- The `zmoltcp` spike showed the exact missing primitive before PR #1 landed:
  local gateway TCP relay worked, but public-destination egress needed a
  non-local IPv4 TCP forwarder hook because ingress filtered packets to locally
  configured IPs before TCP sockets saw them.
- Pulling in libslirp/libvdeslirp would speed a prototype but make the build and
  license story more complex. This plan keeps C networking engines out of the
  core path while accepting a Zig source dependency that we can fix upstream.
- Preserving live flows across suspend/resume would turn networking into a
  research project. The plan records capability and policy, then reconnects
  fresh.
- Guest configuration can balloon if it assumes normal distro tools. The plan
  keeps setup in the minimal initrd and avoids DHCP until static setup proves too
  limiting.
- Replacing `spore-netd` with a user-provided network helper is too much power
  for the Cleanroom service-exposure case. Bound services keep SporeVM on the
  egress path while still letting tools provide guest-reachable metadata,
  artifact, or harness endpoints.

## Resolved Decisions

- Build a minimal SporeVM-owned `spore-netd` instead of making libvdeslirp the
  core backend.
- Use the pinned `lox/zmoltcp` dependency as the guest-facing ARP/IPv4/TCP
  engine now that the required generic TCP-forwarder API has landed.
- Contribute the TCP-forwarder primitive in `zmoltcp` as generic gateway support:
  no SporeVM host sockets, DNS, lifecycle, policy, or observability in that
  library.
- Keep `--net` as the durable public surface; adapter names and helper details
  stay internal until there is a proven need to expose them.
- Keep policy as basic CLI flags and structured runtime data, not eBPF, CEL, or
  another programmable filter language in SporeVM core.
- Add `--bind-service` as a guest-local service primitive, not as published
  ports or a replacement network helper.
- Start with one-shot `spore run --net`, not `spore exec` hot attach.
- Start with IPv4, static addressing, ARP, DNS, and outbound TCP only.
- Treat live network flow state as non-portable runtime state.
- Fail closed on unsupported backends or partial gateway startup.

## Deferred Work

- Published TCP ports.
- General UDP beyond DNS.
- IPv6, NDP, router advertisements, and IPv6 DNS.
- DHCP or dynamic address allocation.
- Multiple NICs or guest networks.
- Policy-profile files or reusable network policy manifests.
- Programmable policy languages such as CEL or eBPF.
- Optional diagnostic adapters such as `tap:<ifname>` or external helper engines.
- Bound-service TCP loopback targets, custom guest ports, multiple services or
  service IPs, and application-layer `Host` routing.
- Bound-service availability events.
- Manifest/schema support to persist declared bound services and re-bind them
  for capture, `spore run --from`, and named resume.

## Open Questions

No open question blocks the current implemented slice. Remaining bound-service
work is listed under Deferred Work and should stay out of the first PR unless a
real caller needs it.
