# Image Gateway Protocol

This document defines the interoperable Spore image gateway protocol as it is
implemented. The current slices freeze immutable multi-platform indexes and
platform-specific image manifests, and implement an explicit eager client that
fetches one repository-bound platform closure, verifies it, installs it through
the existing rootfs CAS transaction, and publishes an ordinary local image ref.
Authentication, conversion admission, batch transfer, attachment records, and
production gateway service behavior remain unimplemented.

## Platform vocabulary

Protocol values use OCI names. Version 1 supports `linux/arm64` and
`linux/amd64`. Gateway parsing, selection, and image identity use those names;
runtime-backend selection is a separate SporeVM boundary and is not represented
in gateway JSON.

An OCI arm64 descriptor may omit `variant` or set it to `v8`; both normalize to
`linux/arm64`. Any two eligible descriptors that normalize to the requested
platform are ambiguous and rejected before a gateway platform index can be
produced. An amd64 descriptor must omit `variant`. Descriptors for other
operating systems or architectures are ignored. A descriptor for the requested
operating system and architecture with any other variant fails the complete
selection, even when another eligible descriptor would otherwise match.
Direct registry pulls and local OCI-layout imports use the same normalization
and ambiguity rule as the gateway source selector, so a source index cannot
resolve differently depending on whether it is converted locally or through a
future gateway.

## Immutable platform index

The canonical JSON shape is:

```json
{
  "kind": "spore-image-gateway-index-v1",
  "source_index_digest": "sha256:<64 lowercase hexadecimal characters>",
  "manifests": [
    {
      "platform": {
        "os": "linux",
        "arch": "amd64"
      },
      "manifest_digest": "sha256:<64 lowercase hexadecimal characters>",
      "image_digest": "blake3:<64 lowercase hexadecimal characters>"
    }
  ]
}
```

`source_index_digest` is optional for native Spore repositories. When present,
it names the one top-level OCI index or manifest generation from which every
entry was selected. `manifests` contains one or two entries, sorted by the byte
ordering of `platform.os` and then `platform.arch`; duplicate platforms are
invalid. A client selects exactly the requested platform and never falls back
to another architecture.

The complete document is limited to 64 KiB. It is encoded with two-space JSON
indentation, the field order shown above, no null optional fields, and no
trailing newline or bytes. Parsers reject alternate whitespace or field order,
unknown or duplicate fields, unsupported kinds or platforms, non-lowercase or
wrong-length digests, unsorted entries, duplicates, invalid UTF-8, and trailing
input. Its immutable transport name is the lowercase SHA-256 digest of those
exact canonical bytes.

The reusable golden is
[`test/image-gateway/platform-index.json`](../test/image-gateway/platform-index.json).
Its canonical-byte transport name is
`sha256:63e18a7caa38e6c0b7b0d3688bfb44e602c02c9ee869c7f176f0146d362297d8`.
A one-platform native-repository golden without source provenance lives at
[`test/image-gateway/platform-index-native.json`](../test/image-gateway/platform-index-native.json)
and has transport name
`sha256:1dc55b21130fcb035cbc963298f1bb369a8b5065b3694d65b69c2cda126933dd`.
Fixture files carry one source-control newline which is excluded from the
canonical bytes. The golden fixtures are normative for separators, indentation,
field order, and LF line endings. Malformed fixtures live beside them under
`malformed/`.

## Immutable image manifest

Each platform-index descriptor names one canonical image manifest by the
SHA-256 digest of its exact bytes. Version 1 accepts only the existing
`chunked-ext4-rootfs-v0` storage contract: rootfs virtio device 2 at MMIO slot
1, 64 KiB BLAKE3 chunks, and the `rootfs/blake3` object namespace. The storage
index digest, base identity, and rootfs-index descriptor digest must be equal.

The complete manifest is limited to 64 KiB. Canonical config blobs are nonempty
and limited to 64 MiB; rootfs indexes are nonempty and retain the existing 64
MiB disk-index limit. OCI requested and resolved references are nonempty and
limited to 4 KiB, while each conversion-contract value is nonempty and limited
to 256 bytes. References use printable non-space ASCII; conversion-contract
values use lowercase ASCII letters, digits, dot, underscore, and hyphen. The
rootfs summary cannot claim more objects than logical chunks or more object
bytes than the logical disk size. Canonical JSON uses declaration order,
two-space indentation, no emitted null optionals, and no trailing bytes.

`source` is present for OCI conversion provenance and omitted for a native
Spore image. When present, its resolved reference must end in the exact selected
OCI manifest digest. Provenance changes the gateway manifest's transport digest
but does not enter the native image identity. Verification requires the
manifest source-index digest to equal the platform index's source-index digest;
both must be absent for a native repository. This prevents one platform index
from silently mixing manifests converted from different mutable-tag generations.

A client verifies the selected descriptor against the manifest transport
digest, platform, and native image digest. It then verifies config length and
SHA-256 transport digest, requires strict canonical `ImageConfig` bytes, checks
the BLAKE3 config digest and platform, and verifies the canonical rootfs index
against the complete storage descriptor. Finally it checks the unique rootfs
object count and object bytes, including a short last chunk, and recomputes the
native image digest from the index digest and exact config bytes. This closure
verification is data-only and shared by a future gateway client and direct OCI
paths; it performs no network, cache, filesystem, or runtime operation.

Normative fixtures live at
[`test/image-gateway/image-manifest-arm64.json`](../test/image-gateway/image-manifest-arm64.json),
[`test/image-gateway/image-manifest-amd64.json`](../test/image-gateway/image-manifest-amd64.json),
and
[`test/image-gateway/image-manifest-native.json`](../test/image-gateway/image-manifest-native.json).
They share a two-object rootfs index whose final logical object is one byte, so
object summaries remain useful to future eager and lazy transfer planning.
Their canonical-byte transport names are, respectively,
`sha256:229c1e468922537a038b629378ab49b0e7354d10cb5a217d783b221f9fb44eda`,
`sha256:b887a80189c8b9c46f77e645ab0631f705b80ef5daf09168597eb0d3e6fd5431`,
and
`sha256:b657390a5d37e2f098694027575d44fee3e235d64d6ffa630c995d9be54a01ca`.

## Experimental eager pull surface

The first end-to-end proof uses an explicitly configured gateway origin and a
repository name. A source string is named by the lowercase SHA-256 digest of
its exact UTF-8 bytes; the mutable source alias returns a canonical platform
index. All selected content is then fetched beneath the immutable manifest:

```text
GET /v1/repositories/<repository>/sources/sha256:<source-key>/index
GET /v1/repositories/<repository>/manifests/sha256:<manifest>/manifest
GET /v1/repositories/<repository>/manifests/sha256:<manifest>/config
GET /v1/repositories/<repository>/manifests/sha256:<manifest>/rootfs-index
GET /v1/repositories/<repository>/manifests/sha256:<manifest>/objects/blake3:<object>
```

The source alias is discovery only. The selected descriptor fixes the manifest
transport digest and native image digest, after which the client verifies the
complete config, index, and object closure locally. Repository names contain
lowercase ASCII letters, digits, dot, underscore, hyphen, and slash-separated
nonempty components; dot-dot is rejected. Responses do not redirect and retain
the schema bounds above. Objects must have the exact index-derived length and
their BLAKE3 digest is rechecked by the CAS installer before publication.
The eager proof rejects rootfs values above 16 GiB logical size, 65,536 distinct
nonzero objects, or 4 GiB of nonzero object payload before fetching any object.
These are client resource bounds for the initial one-request-per-object
transport, not native image-format limits.

Production gateways require HTTPS. `--allow-insecure-http` accepts only an
explicit `127.0.0.1` or `[::1]` origin and exists for the static fixture server. This proof
has no authentication or credential handling, so it is not a production
gateway client contract yet. `spore image export-fixture` writes a new static
repository tree from existing indexed-rootfs metadata and verified local CAS
objects; it is test tooling for `python3 -m http.server`, not a gateway service.

The eager client downloads all distinct nonzero objects into private operation
staging before taking the exclusive rootfs-cache lock. Under the lock it removes
the derived completeness stamp, repairs and re-verifies objects and the index,
recomputes completeness, then publishes image metadata and the requested local
ref last. The resulting ref is consumed unchanged by `spore run --image ...
--pull=never`; SporeVM remains direct-OCI and local-image capable without a
gateway. The manifest-bound single-object path is deliberately compatible with
a future lazy content source, but this slice never publishes partial storage or
performs network I/O from the block path.

## Negative data-plane contract

This schema creates no repository-independent blob or object endpoint, generic
existence `HEAD`, cross-repository mount, repository-wide missing-object query,
or client-maintained attachment tag. Future reads remain bound to an authorized
repository and immutable image-manifest closure. Physical CAS deduplication is
an implementation detail and cannot become a caller-visible existence oracle.
