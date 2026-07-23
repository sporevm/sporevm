# Release Notes

## v0.15.0

SporeVM v0.15.0 adds an experimental Linux/AMD64 KVM fresh-execution
profile and the first interoperable image-gateway contracts and eager pull
client. The existing macOS/ARM64 HVF and Linux/ARM64 KVM lifecycle remains the
mature product path; AMD64 is a deliberately narrow, source-built preview.

### Experimental Linux/AMD64 KVM execution

Linux/AMD64 hosts can now run fresh one-shot VMs and use fresh named
`create`/`exec`/`rm` through the managed kernel and embedded minimal exec
initrd. The profile has a frozen x86-64 board, an approved same-host CPU
profile, bounded bzImage planning, and native KVM acceptance coverage.

The profile requires one vCPU and exactly 512 MiB of memory. Image and rootfs
execution, networking, build, capture, save, restore, resume, fork, fan-out,
and standalone libspore execution remain unavailable and fail closed. AMD64
must be built from source; this release does not add an AMD64 archive.

### Verified image-gateway pulls

The new `spore image pull` command fetches one explicitly selected platform
from a repository-bound gateway source into an ordinary local image ref. It
verifies the canonical manifest, config, rootfs index, native image identity,
and every BLAKE3 object before publishing through the existing local CAS
transaction. HTTPS is required except for an explicit literal-loopback fixture
mode.

The protocol now defines canonical multi-platform indexes, platform-specific
image manifests, and typed attachment records for signatures, SBOMs,
attestations, vulnerability reports, and policy results. Gateway content may
describe `linux/arm64` or `linux/amd64`, but the experimental AMD64 runtime
cannot yet execute image or rootfs content.

This is an eager client and data-contract release, not a production gateway
service. Authentication, conversion admission, batch transfer, lazy remote
reads, attachment publication, and policy evaluation remain future work.

### Compact disk indexes

New rootfs and writable snapshots use the canonical `spore-disk-index-v2`
format. It packs contiguous BLAKE3 chunk digests and known-zero coverage into
ranges, removing the former roughly 30.62 GiB dense-disk cliff caused by one
JSON object per 64 KiB chunk. Index inputs remain capped at 64 MiB and retain
descriptor, arithmetic, exact-coverage, canonical-byte, and BLAKE3 validation.
Existing v1 indexes remain readable and keep their original content identity;
they migrate naturally when a later snapshot or commit publishes v2.

### Architecture and API compatibility

- Product-facing architecture values now use OCI names consistently:
  `arm64` and `amd64`. Direct registry pulls, local OCI-layout imports, and the
  gateway share one platform-selection authority and reject ambiguous variant
  matches.
- Architecture-discriminated host facts use `spore.host-info.v3`. The
  ARM-shaped `spore.host-info.v2` surface remains available for compatibility,
  and returns unsupported architecture on AMD64.
- The public C ABI advances from 15 to 16 for
  `spore_host_info_json_v3`. Callers should compare runtime build info with
  `SPORE_ABI_VERSION` before using the new symbol.
- Saved-state manifests remain AArch64-only and retain the existing
  `aarch64` / `sporevm-aarch64-v0` format identifiers. This release does not
  change existing AArch64 manifest bytes or device-format versions.
- Published archives remain `spore_Darwin_arm64`, `spore_Linux_arm64`, and
  their matching libspore archives.

**Full changelog:**
[v0.14.0...v0.15.0](https://github.com/sporevm/sporevm/compare/v0.14.0...v0.15.0)
