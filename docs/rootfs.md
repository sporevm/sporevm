# Rootfs Images

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image. The first OCI-capable run workflow is deliberately two-step:

```bash
zig-out/bin/spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4

zig-out/bin/spore run --rootfs alpine.ext4 -- /bin/echo hi
```

The input can be either a digest-pinned ref or a registry tag:

```bash
spore rootfs build ghcr.io/org/image@sha256:<digest> \
  --platform linux/arm64 \
  --output rootfs.ext4 \
  --metadata rootfs.ext4.json

spore rootfs build ghcr.io/org/image:latest \
  --platform linux/arm64 \
  --output rootfs.ext4
```

Run an explicit argv from a built rootfs by attaching it read-only:

```bash
spore run --rootfs rootfs.ext4 -- /bin/echo hi
```

For the direct convenience path, `spore run --image` resolves the image ref,
builds or reuses a cached ext4 rootfs, and then delegates to the same read-only
rootfs execution path:

```bash
spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

The rootfs cache key includes the resolved digest-pinned image ref, target
platform, and rootfs builder version. Mutable tag inputs also get a small local
ref record, so a warm `spore run --image docker.io/library/alpine:3.20` can go
straight to the previously validated rootfs instead of re-resolving the tag on
every invocation. If the ref record or referenced rootfs is missing or
mismatched, SporeVM falls back to the registry path and updates the record after
the rootfs cache is valid.

Set `SPOREVM_ROOTFS_CACHE_DIR` to choose the cache directory; otherwise SporeVM
uses the platform cache directory. Cache setup messages are shown only with
`spore --debug ...`, so command stdout and stderr stay workload-focused by
default.

When `spore run --image ... --capture-on-abort SPORE` captures a VM, the spore
manifest records an immutable rootfs artifact: the ext4 content BLAKE3 digest,
size, virtio-blk binding, resolved OCI image identity, platform, and builder
version. The rootfs is also stored under a digest-addressed cache path. Product
`spore resume` reopens that cached artifact, verifies the same read-only fd by
digest and size, then attaches it as virtio-blk. If the digest cache entry is
missing or tampered with, resume refuses to boot.

Plain `spore run --rootfs PATH` remains a local run escape hatch. Combining
`--rootfs PATH` with `--capture-on-abort` is rejected until an import/preload
command can record portable rootfs identity for arbitrary local images.

Validate OCI rootfs capture, fork, and parallel product resume with the opt-in
Ruby fan-out smoke:

```bash
mise run smoke:rootfs-fanout
```

Validate the tag-to-rootfs-to-run path with the local smoke script:

```bash
scripts/smoke-run-oci-rootfs.sh -- /bin/echo hi
```

The smoke prints the metadata path and `resolved_image_ref` so tag-based runs
can be traced back to the digest-pinned image identity that was built.

Tag inputs are resolved to the selected platform manifest before rootfs
materialization. Metadata records both the supplied `image_ref` and the
`resolved_image_ref` used for the build, so builds started from mutable tags can
be repeated from the recorded digest-pinned ref.

`spore rootfs resolve` prints the digest-pinned ref without building a rootfs:

```bash
spore rootfs resolve ghcr.io/org/image:latest --platform linux/arm64
```

The builder verifies fetched blobs against their SHA256 descriptors, applies OCI
whiteouts, rejects unsafe tar paths, and shells out to `mkfs.ext4 -F -d` plus
`debugfs` for the final filesystem.

The generated ext4 image uses UUID and directory hash seeds derived from the
selected OCI manifest digest, normalizes filesystem and inode timestamps to the
Unix epoch, and omits the ext4 journal and metadata checksum features so
repeated builds of the same resolved image produce identical bytes.

`mkfs.ext4` and `debugfs` are auto-detected from `PATH`, common Linux
locations, and Homebrew's `e2fsprogs` prefix. Use `--mkfs` and `--debugfs` to
override the detected binaries.
