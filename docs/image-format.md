# Native Image Format

This document defines the canonical native image manifest, config, and rootfs
index, and the single-platform archive that carries them for
`spore image pack` and `spore image unpack`. The manifest `kind` keeps its
original wire name, `spore-image-gateway-manifest-v1`.

## Platform vocabulary

Values use OCI names. Version 1 supports `linux/arm64` and `linux/amd64`.
Runtime-backend selection is a separate SporeVM boundary and is not
represented in image JSON.

Direct registry pulls and local OCI-layout imports select a platform from an
OCI index with one rule. An arm64 descriptor may omit `variant` or set it to
`v8`; an amd64 descriptor must omit `variant`. Descriptors for other operating
systems or architectures, non-image media types, and descriptors without
platform metadata are ignored. A descriptor for the requested operating system
and architecture with any other variant fails the complete selection, and two
eligible descriptors are ambiguous and rejected. Selection never falls back to
another architecture.

## Image manifest

One canonical image manifest describes one platform-specific native image and
is named by the SHA-256 digest of its exact bytes. Version 1 accepts only the
existing `chunked-ext4-rootfs-v0` storage contract: rootfs virtio device 2 at
MMIO slot 1, 64 KiB BLAKE3 chunks, and the `rootfs/blake3` object namespace.
The storage index digest, base identity, and rootfs-index descriptor digest
must be equal.

The complete manifest is limited to 64 KiB. Canonical config blobs are nonempty
and limited to 64 MiB; rootfs indexes are nonempty and retain the existing 64
MiB disk-index limit. The rootfs summary cannot claim more objects than
logical chunks or more object bytes than the logical disk size. Canonical JSON
uses declaration order, two-space indentation, no emitted null optionals, and
no trailing bytes. Parsers reject alternate whitespace or field order, unknown
or duplicate fields, unsupported kinds, platforms, or storage values,
non-lowercase or wrong-length digests, invalid UTF-8, and trailing input.

A reader verifies the manifest against an expected SHA-256 transport digest
and platform. It then verifies config length and SHA-256 transport digest,
requires strict canonical `ImageConfig` bytes, checks the BLAKE3 config digest
and platform, and verifies the canonical rootfs index against the complete
storage descriptor. Finally it checks the unique rootfs object count and
object bytes, including a short last chunk, and recomputes the native image
digest from the index digest and exact config bytes. This verification is
data-only; it performs no network, cache, filesystem, or runtime operation.

Normative fixtures live at
[`test/image/image-manifest-arm64.json`](../test/image/image-manifest-arm64.json)
and
[`test/image/image-manifest-amd64.json`](../test/image/image-manifest-amd64.json),
with configs and a shared two-object rootfs index beside them whose final
logical object is one byte. Fixture files carry one source-control newline
which is excluded from the canonical bytes. Their canonical-byte transport
names are, respectively,
`sha256:fcc3dbd055d0d00d5100b1c53ba25c01e6ff3df509ec3442f9f3da891abb6a59`
and
`sha256:3701f224c51477fb6e7a620fd74be5cdfc039afcd6a7ba583cff79c6c6d1a74c`.

## Native image archive

The transport for a final native image is a single-platform gzip-compressed
USTAR archive with media type
`application/vnd.sporevm.image.archive.v1+tar+gzip`. It carries the canonical
image manifest, config, rootfs index, and independently addressable objects;
the archive adds no image or rootfs identity. CI artifact storage, object
storage, or another delivery system transports the opaque archive bytes.

Entries are regular files in this exact order:

```text
spore-image-manifest.json
image-config.json
rootfs-index.json
objects/<64 lowercase BLAKE3 hexadecimal characters>
```

Object entries are the distinct nonzero rootfs objects sorted by digest.
Headers use USTAR, mode `0444`, uid and gid zero, mtime zero, empty owner names,
and two terminal zero blocks. Alternate entry order, duplicates, missing or
extra entries, non-regular entries, noncanonical headers, bad checksums,
truncation, and trailing decompressed bytes fail closed. Gzip and USTAR are
rebuildable transport metadata; the lowercase SHA-256 digest of the complete
compressed file is its immutable publication name.

`spore image pack` resolves the requested local tag to its digest-pinned image
before writing anything, verifies the complete local CAS closure, and prints
the archive SHA-256, image-manifest SHA-256, and native-image BLAKE3
identities. Tags from `spore rootfs import-oci` or `import-tar` (SHA-256 local
digests) are packed under their recomputed native image identity. It refuses to replace an existing output. `spore image unpack`
requires the expected archive digest, expected native image digest, target
platform, and destination local tag. It hashes the same open file it parses,
then verifies the selected platform, canonical manifest/config/index closure,
native image identity, each object's index-derived length, and each object's
BLAKE3 digest. An outer archive digest, expected native identity, or aggregate
bound mismatch fails before cache publication. Only after the complete closure
is staged does it install through the existing CAS transaction and publish the
local ref last.

Archives are bounded to 16 GiB logical rootfs size, 65,536 distinct nonzero
objects, 4 GiB object payload, and 4 GiB compressed archive bytes. The
unpacker uses private disk staging and never creates, captures, restores, or
carries RAM, vCPU, device, session, or suspended machine state. `spore pack`,
`push`, `pull`, and `unpack` remain the separate saved-machine bundle protocol.

## Converter-worker conformance

The versioned fixture at
[`test/image/worker-conformance/bundle.json`](../test/image/worker-conformance/bundle.json)
demonstrates that converter host architecture does not enter native image
identity for representative OCI filesystem content. The fixture generator
constructs one deterministic OCI index containing `linux/amd64` and
`linux/arm64/v8` manifests over one uncompressed USTAR layer and one gzip-
compressed USTAR layer. The layers exercise directory and file modes, numeric
ownership, a hard link, a symbolic link, an OCI whiteout, a later-layer file
replacement, and a 65,537-byte file that crosses the native chunk boundary.
The OCI config also carries command, entrypoint, environment, label, signal,
user, and working-directory metadata, exercising the canonical projection that
preserves Spore's supported runtime fields and excludes non-identity metadata.
Each Linux worker imports both selected targets with the native ext4 writer,
packs each into an image archive, and must reproduce the committed canonical
config, rootfs index, image manifest, native image digest, and complete
nonzero-object digest set.

The bundle schema is `spore-image-worker-conformance-v3`. It records the
input index, layers, compressed and uncompressed layer digests, and
selected-manifest digests plus each output file's exact size and SHA-256
digest. Object bytes are not duplicated in source control; the bundle records
every BLAKE3 object name, exact length, and SHA-256 digest, while the canonical
rootfs index remains the authoritative logical mapping. The arm64 and amd64
target results are expected to differ because platform enters canonical image
config. For one selected target, however, a `linux/arm64` converter worker and
a `linux/amd64` converter worker must produce the same complete bundle bytes.

The harness independently recomputes SHA-256 digests and exact sizes, checks
the OCI diff IDs, and verifies the supported runtime-metadata projection.
BLAKE3 object names, rootfs identity, and native image identity remain outputs
of the SporeVM implementation under test; the byte comparison proves that those
outputs agree across workers but is not an independent implementation of the
identity algorithms.

Run the host-local check with:

```bash
mise run test:image-worker-conformance
```

CI runs the same two-target conversion independently on Linux arm64 and Linux
amd64.
