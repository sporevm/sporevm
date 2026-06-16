# Rails/Postgres RSpec Fan-Out

This example is the warm CI shape SporeVM is aiming at:

1. Build a Docker image that contains Ruby, Rails, PostgreSQL, the app, and the
   test suite.
2. Import the buildx OCI layout into SporeVM's local rootfs cache.
3. Run that image as a SporeVM immutable rootfs.
4. Start PostgreSQL inside the VM, load the schema, eager-load Rails and RSpec,
   then capture the warm VM.
5. Fork the captured spore into child spores.
6. Resume the children in parallel and run one RSpec shard per child.

The rootfs is read-only on resume, so the guest coordinator copies the Rails app
to `/tmp`, initializes PostgreSQL under `/tmp/sporevm-postgres`, and keeps all
runtime state in guest RAM. That is the useful part: Rails boot, bundle load,
schema load, and PostgreSQL startup happen once before capture.

## Kernel Requirements

The full Postgres fan-out path works with SporeVM's managed run kernel from
cleanroom-kernels `v0.5.0`. That release includes the normal Linux facilities
Rails/PostgreSQL needs, plus the cgroups, namespaces, seccomp, overlayfs, and
container networking options useful for container-oriented follow-up
experiments:

```text
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
CONFIG_SECCOMP=y
CONFIG_MULTIUSER=y
CONFIG_POSIX_TIMERS=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_VIRTIO_BLK=y
CONFIG_NETFILTER=y
CONFIG_BRIDGE=y
CONFIG_VETH=y
CONFIG_TUN=y
# CONFIG_DEVMEM is not set
CONFIG_EXT4_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_KEYS=y
```

Use `--kernel` or `SPOREVM_KERNEL_IMAGE` only when testing an unreleased kernel.

## Build the OCI Image

The default path does not push to a registry and does not require SporeVM to
talk to the Docker daemon. Docker buildx writes an OCI layout tar, then
`spore rootfs import-oci` imports that layout into the local rootfs cache:

```bash
example/rails/bin/build-image
```

The script runs the equivalent of:

```bash
docker buildx build \
  --platform linux/arm64 \
  --output type=oci,dest=/tmp/sporevm-rails-rspec.oci \
  example/rails

zig-out/bin/spore rootfs import-oci /tmp/sporevm-rails-rspec.oci \
  --ref local/sporevm-rails-rspec:dev \
  --platform linux/arm64
```

`local/sporevm-rails-rspec:dev` is a host-local convenience ref. Import resolves
it to a digest-pinned `local/sporevm-rails-rspec@sha256:<manifest>` identity in
the rootfs cache. Captured spores still restore by the ext4 BLAKE3 artifact
digest recorded in the spore manifest; the local tag is not portable identity.

To push the image to a registry instead:

```bash
example/rails/bin/build-image \
  --push \
  --image ghcr.io/YOUR_ORG/sporevm-rails-rspec:dev
```

## Run the Fan-Out Demo

```bash
example/rails/bin/fanout-rspec --count 2
```

By default `fanout-rspec` builds and imports the local OCI layout first. If the
image has already been imported, skip that step:

```bash
example/rails/bin/fanout-rspec \
  --image local/sporevm-rails-rspec:dev \
  --no-image-build \
  --count 2
```

Use a larger `--count` once the host can sustain more concurrent resumes.

The script performs the product lifecycle explicitly:

```bash
spore run --image local/sporevm-rails-rspec:dev --capture rails-rspec.spore --capture-on USR1 -- \
  /bin/bash /usr/local/bin/sporevm-rails-coordinator

spore fork rails-rspec.spore --count 2 --out rails-rspec.children
spore fanout rails-rspec.children --parallel
```

Expected output includes the warm marker from the parent:

```text
SPOREVM_RAILS_READY pid=... capture_delay=1
```

and one successful RSpec completion marker per child:

```text
[000000] SPOREVM_RSPEC_DONE parallel_index=0 parallel_count=2 exit=0
[000001] SPOREVM_RSPEC_DONE parallel_index=1 parallel_count=2 exit=0
```

The host script leaves logs and spores in its workdir so the manifest and child
output can be inspected after the run.

## Sharding

Forked child manifests contain stable generation params including
`parallel_index`, `parallel_count`, `fork_index`, `fork_count`,
`fork_batch_id`, and `vm_id`.

Inside rootfs guests, SporeVM publishes the fork generation payload to:

```text
/run/sporevm/generation.json
/run/sporevm/env
```

`/usr/local/bin/sporevm-rspec-shard` reads those helper files and splits spec
files by:

```ruby
spec_index % parallel_count == parallel_index
```

Missing identity is treated as a demo failure. Set
`SPOREVM_RSPEC_ALLOW_UNSHARDED=1` only for ad hoc image debugging outside
SporeVM, where running the full suite once is more useful than proving fan-out
identity.

## Useful Knobs

```bash
example/rails/bin/fanout-rspec --count 8 --memory-mib 4096
example/rails/bin/fanout-rspec --backend kvm
example/rails/bin/fanout-rspec --workdir /tmp/sporevm-rails-demo
example/rails/bin/fanout-rspec --image ghcr.io/YOUR_ORG/sporevm-rails-rspec:dev --no-image-build
example/rails/bin/fanout-rspec --kernel /path/to/sporevm-run-arm64-linux-6.1.155-Image
```

Environment equivalents:

```bash
SPORE_RAILS_IMAGE=local/sporevm-rails-rspec:dev
SPORE_RAILS_OCI=/tmp/sporevm-rails-rspec.oci
SPORE_RAILS_FANOUT_COUNT=2
SPORE_RAILS_MEMORY_MIB=2048
SPORE_BIN=/path/to/spore
```
