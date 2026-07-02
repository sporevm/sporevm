# SporeVM Networking

SporeVM networking is explicit. Without `--net`, the virtio-net device remains
a closed endpoint. With `--net`, SporeVM starts a hidden `spore-netd` helper and
connects the existing virtio-net device to a SporeVM-owned userspace gateway.

```bash
spore run --net --image docker.io/library/alpine:3.20 'wget -qO- https://example.com'
```

There is no TAP, bridge, host NAT, or published-port contract in the default
path. The guest-visible device model stays the same across HVF and KVM.

## Guest Network

The first network is fixed and static:

```text
guest IPv4:   100.96.0.2/30
gateway IPv4: 100.96.0.1
DNS:          100.96.0.1
```

The minimal initrd configures `eth0`, the default route, and resolver config
from the `spore_net=1` boot flag. It does not require DHCP, `ip`, or distro
networking tools.

## Egress Policy

The hard floor always blocks host loopback, link-local metadata addresses,
private/control-plane ranges, unspecified/broadcast addresses, and the internal
gateway range. DNS answers cannot override that floor.

With plain `--net`, public IPv4 TCP egress is allowed after the hard floor.
Adding `--allow-cidr` or `--allow-host` restricts public egress to those CIDRs
or DNS A answers learned through the SporeVM DNS proxy:

```bash
spore run --net --allow-host example.com -- /bin/wget -qO- https://example.com
spore run --net --allow-cidr 93.184.216.34/32 -- /bin/wget -qO- http://93.184.216.34/
```

The libspore policy API is stricter: `NetworkPolicy{ .default = .deny }` uses
exact host plus port rules and exposes capability facts through
`networkCapabilities()`.

## Bound Services

One-shot runs can expose declared host Unix sockets to the guest:

```bash
spore run --net \
  --bind-service metadata=unix:/tmp/metadata.sock \
  --bind-service cache:8080=unix:/tmp/cache.sock \
  -- /bin/wget -qO- http://metadata.spore.internal/
```

The CLI shape is deliberately small: up to 16 named Unix stream socket targets.
`NAME=unix:/path.sock` exposes `NAME.spore.internal:80`; `NAME:PORT=unix:/path.sock`
uses a custom guest port. Service names and guest ports must be unique. Bound
services are guest-exposed inputs; service providers must treat bytes on the
socket as guest-controlled.

Captured manifests record bound-service requirements by name, guest host, and
guest port, but never durable host socket paths. Restore fails closed unless a
caller supplies fresh live bindings for each declared service through libspore.

## Capture And Resume

Captured network spores persist requested capability and policy, not live TCP
flows, DNS caches, helper state, host socket paths, or credentials. `spore
resume` and `spore run --from` attach a fresh gateway under the recorded policy
or fail closed.

When running from a captured spore, omit `--net` and network flags:

```bash
spore run --from net-enabled.spore -- /bin/wget -qO- https://example.com
```

## Events And Limits

Denied TCP egress can emit JSONL audit events through `--events=jsonl`. Events
include destination, port, and denial reason, not guest payload bytes.

Bound Unix services emit a setup `port_forward` event with the service name,
guest host, guest port, and target kind. The event does not include the host
Unix socket path.

Current limits:

- IPv4 TCP and DNS only.
- No IPv6, general UDP, DHCP, published ports, or multiple NICs.
- No live flow preservation across capture, resume, or fork.
- No per-exec policy replacement for a running named VM.
- No TCP loopback targets or per-connection bound-service availability events
  in the CLI path.

## Validation

Useful focused checks:

```bash
mise run smoke:run-net-config
mise run smoke:run-net-dns
mise run smoke:run-net-http
mise run smoke:run-net-deny
mise run smoke:run-net-capture
mise run smoke:run-net-bind-service
```
