# Image Gateway Protocol

This document defines the interoperable Spore image gateway protocol as it is
implemented. The current slice freezes immutable multi-platform indexes only;
image manifests, attachment records, object transfer, conversion admission, and
client installation remain unimplemented.

## Platform vocabulary

Protocol values use OCI names. Version 1 supports `linux/arm64` and
`linux/amd64`. Gateway parsing, selection, and image identity use those names;
runtime-backend selection is a separate SporeVM boundary and is not represented
in gateway JSON.

An OCI arm64 descriptor may omit `variant` or set it to `v8`. Both normalize to
`linux/arm64`, so source selection containing both is ambiguous and is rejected
before a gateway platform index can be produced.
An amd64 descriptor must omit `variant`. Other operating systems,
architectures, and variants are unsupported.

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

## Negative data-plane contract

This schema creates no repository-independent blob or object endpoint, generic
existence `HEAD`, cross-repository mount, repository-wide missing-object query,
or client-maintained attachment tag. Future reads remain bound to an authorized
repository and immutable image-manifest closure. Physical CAS deduplication is
an implementation detail and cannot become a caller-visible existence oracle.
