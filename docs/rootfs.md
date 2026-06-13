# Rootfs Images

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image. The input can be either a digest-pinned ref or a registry tag:

```bash
spore rootfs build ghcr.io/org/image@sha256:<digest> \
  --platform linux/arm64 \
  --output rootfs.ext4 \
  --metadata rootfs.ext4.json

spore rootfs build ghcr.io/org/image:latest \
  --platform linux/arm64 \
  --output rootfs.ext4
```

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
