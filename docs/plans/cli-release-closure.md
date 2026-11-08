# CLI closure before v0.18.0

The naming/error pass landed in #694 and the Rails migration in examples#12.
The release now also includes the previously deferred acquisition, local
export, credential-refresh and scoped-timeout work. Kubernetes remains pinned
and is not part of this release's acceptance gate.

## Delivery slices

1. Add `image pull SOURCE [--tag local/NAME:TAG] [--platform P]`, using the
   existing registry conversion and verified native-store fetcher. Success
   means the complete closure is locally rooted and immediately usable offline,
   without booting a VM. Infer the recorded platform for native inputs.
   Extend `image export-rootfs` to complete native local/store inputs without
   inventing OCI provenance; never link a caller-writable output into the CAS.
   Keep registry metadata compatible. Test cold store, offline use, corrupt
   content, platform selection, and output collision behavior.
2. Share AWS CLI credential-chain resolution with direct signed S3 reads:
   explicit environment credentials take precedence, profile/role credentials
   refresh before expiry, concurrent reads share refresh, and failure is
   actionable without exposing secrets. Retain direct GETs, bounded fetches,
   and fail-closed endpoint handling. Cover provider JSON with fuzz seeds and
   test expiry, precedence, session tokens and refresh failure.
3. Separate startup readiness, command execution, build-step and resumed-session
   clocks. Allow per-exec deadlines and `none` for execution only. Verify timeout
   termination, including descendants, and continued named-VM usability on real
   hardware. Do not claim a whole-operation/network deadline.
4. Re-audit every usage-lab/proposal item on the final candidate, including
   per-command help, option boundaries, signal capture, initial logs,
   checkpoint locality, immutable refs, error/status parity and GC safety.
   Exercise ARM64 KVM and the managed Mac using the dev SSM role. Record exact
   commands, revisions, outcomes and limitations in the audit artifact.
5. Refresh and land #693 after CI; note the intentionally unmigrated Kubernetes
   stack. Cut the v0.18.0 tag and GitHub release only after the final candidate
   passes the audit and release packaging requirements. Verify publication.

Each slice gets local checks, self-review, a separately reviewable PR and CI
before merge. No weakened integrity checks, old bundle protocol, new emulation,
or Kubernetes runtime upgrade is included.

## Current evidence

Acquisition/export is implemented and locally reviewed. `zig build test` passes
1,658 tests with 36 skips; all 27 public CLI cases pass in both output modes.
The actual CLI import/push/cold-pull/store-removal/offline-export/pack round trip
preserves native identity. A 512 MiB sparse export occupies 320 KiB. Native
store corruption fails before the requested tag is published, explicit platform
mismatch fails, and modifying an export does not alter a later export.

CI and hardware acceptance remain required. SSM access works on the managed
Mac and ARM64 CI host; AWS credential refresh and scoped timeouts are next.
