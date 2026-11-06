# Smoke Helpers

These test-only guest programs are added to the embedded initrd, as
`/bin/NAME`, only by `zig build -Dsmoke-helpers`, which `mise run smoke`
uses. Shipped builds do not carry them.

`writeout.c` writes one line to stdout and one to stderr.
`finite.c` prints a ready line, three ticks a second apart, and a done line.
`counter.c` prints its fan-out job once `/run/sporevm/env` names it, and a
counter every second, until killed.
`nproc.c` prints the online CPU count.
`netcheck.c` verifies the static `spore run --net` guest link setup without
requiring distro networking tools in the initrd.
`nslookup.c` is a tiny smoke helper for the SporeVM-managed DNS proxy; it sends
one A-record query to the configured resolver and prints the first IPv4 answer.
`wget.c` is a narrow HTTP-only smoke helper for outbound TCP proxying; it
supports `-qO-` and streams bounded response bodies to stdout.
`httpd.c` is a one-shot HTTP responder for host-to-guest TCP forwarding smokes.
`flockcheck.c` verifies guest `flock(2)` behavior for runtime paths such as
Docker and containerd metadata databases.
`cgroupcheck.c` verifies the cgroup2 mount behavior Docker expects before daemon
startup.
`gencheck.c` verifies forked `spore run --from` commands start after generation
metadata and resume entropy are visible in `/run/sporevm/env`.
`rngcheck.c` performs a bounded non-zero read from `/dev/hwrng`.
`blkcheck.c` reads all four frozen block slots, verifies root-disk write/readback,
and attempts writes against the three immutable source slots; the host smoke
proves their backends remain byte-for-byte unchanged.
