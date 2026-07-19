---
status: active
last_reviewed: 2026-07-19
spec_refs:
  - docs/spore-format.md
  - docs/state-portability.md
  - docs/memory.md
  - docs/lifecycle.md
  - docs/rootfs.md
  - docs/libspore.md
  - SECURITY.md
  - src/board.zig
  - src/boot.zig
  - src/guestmem.zig
  - src/platform.zig
  - src/spore.zig
  - src/kvm/kvm.zig
  - src/kvm/vm.zig
  - src/kvm/snapshot.zig
  - src/run.zig
  - src/lifecycle.zig
related_plans:
  - docs/plans/automatic-memory.md
  - docs/plans/multi-vcpu-nondestructive-save.md
  - docs/plans/spore-build.md
---

# x86-64 Linux/KVM Support

## Summary

Add x86-64 as a second SporeVM guest architecture on x86-64 Linux hosts using
KVM. The shipped product should retain the current `spore` command model,
virtio-mmio device set, rootfs and disk formats, generation semantics,
capture/fork lifecycle, and fail-closed restore behavior. An x86 host should
run `linux/amd64` OCI images and produce x86 spores; an ARM host should keep
running `linux/arm64` images and producing aarch64 spores.

This is an architecture port, not a new hypervisor backend. `--backend kvm`
remains the Linux hardware-virtualization choice. Host architecture selects the
KVM machine implementation and the native OCI platform. Spores never translate
between instruction sets: an aarch64 spore must be rejected on x86-64, and an
x86-64 spore must be rejected on aarch64.

The first useful proof is a single-vCPU x86 kernel reaching the existing guest
agent through virtio-console and virtio-vsock. Product completion is broader:
the x86 implementation must define a stable board and CPU profile, represent
sparse physical RAM safely, capture normalized x86 machine state, support
same-host-class restore and fork, run the native smoke graph, and ship in the
release pipeline. The existing ARM64 KVM and HVF contracts remain unchanged
throughout the work.

## Current Progress

- The implementation branch is rebased onto SporeVM `origin/main` at
  `197ce717b3e5a0b62421666d5173d23852fe2132`.
- The design has passed an external Fable architecture review. Its grounded
  findings are incorporated into the slice ordering, PIO/exit contract,
  single-VMA memory invariant, state inventory, and release-name gate.
- A dedicated bare-metal Intel x86-64 development host is live, healthy,
  SSM-accessible, idle, and able to open `/dev/kvm`. Its private identity and
  lifecycle remain owned by `sporevm-ops` rather than this public plan.
- Stage 0a.1 now has a candidate implementation: the pure board/bzImage/E820
  planner, bounded PIO envelope decoder, and console-only single-vCPU harness
  pass 13/13 focused tests with two fuzz targets, the full `mise run test` suite
  with exit 0, and an `x86_64-linux-musl` cross-build on Apple Silicon.
- The final native harness proof used harness SHA256
  `5dca52c223938b8c0e15172fd434b4c84609b4ec5472fb53e99b829abc69e58e`,
  Ubuntu 6.17 bzImage
  `57b671001dbe2c0ac95a862c36c4b2362df04d288d936d6794259789db84232f`,
  config `b66306f7d36063cf6f3abeaf3e039c063bf073dcf77dfc15e7d00780f2dd0660`,
  and ticker initrd
  `2d6dbf97476cbe7d41a6d6c16225f3e12612f827c3c64fd76c834b592c760413`.
  The retained `native-final.log` has SHA256
  `269a8254a8537ba6e1a962d1696b4a3dbc58d6a43668d2dc733c1cb74a327d9b`.
  During a bounded 30-second run with 512MiB low RAM, timeout produced
  `run_rc=124`; the dedicated host emitted one init marker and 29
  `SPOREVM_X86_STAGE_0A1_TICK` markers through the existing virtio-console sink,
  and no harness process remained afterward.
- Stage 0a.1's final auto-review passed all three lenses with no material
  findings, and the final Anthropic Fable deep-analysis continuation approved
  with no material finding remaining.
- Stage 0a.2's managed-kernel prerequisite is complete at sibling-kernel commit
  `4f165a82feded571da55ae276bfe0133adefb64e`. Its final auto-review passed the
  ship-risk, maintainability, and Ponytail lenses; the final Anthropic Fable
  review approved with no material finding remaining. A clean native x86-64
  build emitted bzImage SHA256
  `07a9b6d8a9efd2b7c5e886d1c010e67245fa132c8b48cf567f200099b55abee8`,
  complete config SHA256
  `d67ef9eb0cfee797d1edb09027214b312361139db2621d483edfe0debd13e95e`,
  checksum SHA256
  `c7ad2f454aa7a56cdf19f7199748c3aaea8472f0994499c03081eb6b4239f243`,
  and provenance-manifest SHA256
  `d26c201232657e3e95801395b6b1818cead3d574b6cbe2fb2a77e117c8e7a713`.
  The emitted config passes the release-time required/forbidden symbol gate,
  including SMP, MP/APIC, built-in virtio-mmio devices, strict `/dev/mem`, and
  the absence of ACPI, PCI, legacy serial, and i8042 input. All Stage 0a.2
  evidence remains bound to these exact bytes.
- Stage 0a.2 now has a candidate implementation: a bounded Intel MP 1.4 table,
  normalized per-vCPU CPUID topology, fixed two-vCPU KVM bring-up, the full
  eight-slot virtio-mmio inventory, the generation device, and a deterministic
  static board-probe initrd. The final reviewed native proof used harness SHA256
  `2676ab2c144b71409fd6777a0be369847e3ac16d5ff5d6bdba8a9ca11f0cc50e`,
  probe-initrd SHA256
  `ea15b43e068d17009913348e0fa0ba4f3d314832c1e83ff4f22dbb666b342707`,
  and the prerequisite managed bzImage above. During a bounded 35-second run
  with 512MiB RAM and two vCPUs, timeout produced `run_rc=124` because the
  successful probe idles. The retained `native-probe.log` has SHA256
  `bd5898995a6f960f6ddd0f97d7b39f21a53c6a95f6b997d27edfe3b43c9f42f8`;
  its exact-input sidecar has SHA256
  `8189b332f2b5b93252c9afca463cc8b27788bad951aa4946696f57c99b0db7b3`.
  It reports CPUs `0-1`, the exact device-ID multiset
  `1 2 2 2 2 3 4 19`, `hvc0` output, and generation magic `0x4e475053`, with
  no failure marker or lingering harness process. The only observed PIO was
  four one-byte writes, two each to ports `0x70` and `0x71`. The final focused
  x86 suite passed 452 tests with five expected skips and 30 fuzz targets; the
  full `mise run test`, native build, x86-64 cross-build, deterministic-initrd
  test, and diff hygiene all pass. The final auto-review passed its ship-risk,
  maintainability, and Ponytail lenses with no material finding remaining. The
  final Anthropic Fable review approved the stage with no material finding;
  its three non-blocking board-freeze observations are assigned to Stage 0a.3.
- Stage 0a.3 now has a candidate implementation and exact native proof. The
  final harness SHA256 is
  `1bc2485b4b6ca6c3266ba33461f39e85d86bdff302b1f1651b1fe5dbd24c22d8`,
  the deterministic lifecycle-probe initrd SHA256 is
  `ee05bff31ee93e51ea570f68e18e321a1c4eab0ac606b64065edd7ac30c40eb5`,
  and every run used the Stage 0a.2 managed bzImage above. The retained final
  evidence checksum file has SHA256
  `5bd007e3ecb8f368500a39ec1ac4ab60a83c7887082d93316fe43e63c4be8326`
  and verifies the artifacts, host/capability and kernel-provenance sidecars,
  exact command lines, logs, and return codes. Idle reached `status=ready` and
  timed out with the expected rc 124; reboot returned rc 0 as `guest_reset`
  from raw `KVM_EXIT_IO` reason 2, vCPU 0, one-byte port `0x64`, value `0xfe`;
  native poweroff reached `System halted` and timed out with rc 124 without a
  terminal classification; and the board poweroff command returned rc 0 as
  `guest_off` from raw `KVM_EXIT_MMIO` reason 6 at GPA `0xd0001020`, offset
  `0x020`, length 4, value `0x46464f50`. The four log SHA256 values are
  `f379459f94e7b6bee7ceee609a37c7d0c4ac1e7ad0b93035e22f0ce745014ed1`,
  `5cfbd15d0fe1dfa2f2e98be71306e6465498645207d738ec6585593ad7e1c893`,
  `e2b11baa036a035bc2692a80fafb3ac525a2836ff041037637ab878804deeae8`,
  and `233396c0c7735e9c5ea041ee93c866dbced767d1c416338e0bfc975ff537e858`
  respectively. Native evidence records KVM API 12, every required capability
  as nonzero, 96 recommended vCPUs, 46 supported CPUID entries, GenuineIntel,
  leaf 1 and leaf `0x0b` present, leaf `0x1f` absent, x2APIC supported with the
  guest forced to `nox2apic`, and successful irqchip/PIT, TSS/identity-map,
  memory-slot, per-vCPU CPUID, BSP, and AP setup. No final run emitted a failure
  marker or raw `KVM_EXIT_SHUTDOWN`, and no harness process remained. The final
  focused x86 suite passed 467 tests with five expected skips and 32 fuzz
  targets; full `mise run test`, native build, x86-64 KVM-harness cross-build,
  deterministic-initrd test, checksum verification, and diff hygiene pass. The
  independent evidence audit approved with no findings, the final auto-review
  ship-risk, maintainability, and Ponytail lenses approved with no findings,
  and the final Anthropic Fable continuation approved Stage 0a.3 with no
  material finding.
- Stage 1.1 now has a candidate implementation and exact native proof. One
  `src/kvm/common.zig` module owns the architecture-neutral KVM literals,
  layouts, structs, and raw helpers consumed by both bindings; ARM and x86 keep
  their existing open flags, capability policy, IRQ encoding, run completion,
  exit decoding, and error semantics. The final pre-native patch SHA256 is
  `303022769f2b5c201e34f866dbcd11e9982067006f67082ed4aadef8e7700b13`.
  Common-module tests passed 3/3, the focused x86 suite passed 470 tests with
  five expected skips and 32 fuzz targets, and the full suite passed 2,367
  tests with 21 expected skips. `mise run build`, formatting, diff hygiene,
  the ARM product and harness cross-builds, the x86 harness and product
  cross-builds, and the deterministic x86 initrd test pass. The native ARM64
  proof used ReleaseSafe `spore` SHA256
  `bb30f2e1ca9de09eba64db8f3507cc8b623eae788c435813bd7743c3cd117f0b`:
  the isolated fresh smoke returned `smoke:run ok`, and a separate two-vCPU
  run reported CPUs `0-1`, both with rc 0 and empty stderr. Its 93-file
  evidence manifest SHA256 is
  `dc575df102e5390e6a564fc4debef33644bb6a2c496fb45cba2b1a8144175e6c`;
  the task-owned validator resources were deleted and the installed agent
  remained healthy and idle. Because the default-debug x86 harness changed,
  the complete lifecycle matrix was rerun with harness SHA256
  `6191441ec869e83c3e8269527434f92efbc5070f41c2954e4009941720a607fe`,
  the Stage 0a.2 managed bzImage, and the Stage 0a.3 lifecycle initrd. Idle
  reached ready and timed out with rc 124, reboot returned rc 0 as
  `guest_reset`, native poweroff reached `System halted` and timed out with rc
  124 without a terminal classification, and doorbell poweroff returned rc 0
  as `guest_off`. No run emitted a failure marker or raw
  `KVM_EXIT_SHUTDOWN`, and no harness process remained. The retrieved remote
  evidence archive SHA256 is
  `104b0c78574b5687d5b59d51b86745f84275fb34f487763bf1f6dea8ef8eb419`;
  its manifest SHA256 is
  `543e3102ebdd8726904ab050a436cbe37ce108b1974c4bae5fb07237edef4a3b`,
  and the 102-file local umbrella manifest SHA256 is
  `0184d6dc7119a797b3f24a9567706f0dfa444ec6bdfaf7687b12050d1583d916`.
  The final auto-review ship-risk, maintainability, and Ponytail lenses and the
  final Anthropic Fable continuation approved the pre-native code and plan with
  no material findings; the native gates above close the remaining stage
  conditions.
- Stage 1.2 now has a candidate implementation and exact native proof. One
  canonical architecture module owns the manifest, OCI/CLI, Zig-target, and
  KVM host-class spellings; compile-time native KVM binding selection supports
  Linux aarch64 and x86-64 without changing ARM behavior. The internal backend
  availability probe checks `/dev/kvm`, KVM API 12, and the Stage 0a bring-up
  capabilities from their existing single source, then fails closed at the
  explicit `KvmRunnerNotLanded` boundary. Public `Backend.supportedOnHost()`
  and `resolveForHost()` remain false/unsupported on x86 until that runner
  lands, while private binding selection preserves the precise internal probe.
  Product launch, attach, named create/restore, monitor, and `spore build`
  paths apply the runner gate before artifact, input, disk, cache, network,
  runtime, publication, or VM work. The final post-fix patch used for native
  validation has SHA256
  `9e82a11aa41ffb0f147e809b3c7375032d00ec738bd5ab5cc703762cf5041751`.
  Architecture tests passed 3/3, backend tests passed 22/22, and the full
  `mise run test` suite, `mise run build`, formatting, diff hygiene, ARM and
  x86 backend compile-only tests, and both ReleaseSafe product cross-builds
  pass. The native ARM64 proof used `spore` SHA256
  `aad076aa242b80d8076221a41fba2c872b4e06b8aecf7b3fcc814ca5ad181ffb`:
  isolated fresh smoke returned `smoke:run ok`, and a separate two-vCPU run
  reported CPUs `0-1`, both with rc 0 and empty stderr. Its evidence-manifest
  SHA256 is
  `34ec81d3f4cfc19fb69d1768b00ce45039dbf1a1e2fe5c8278853e8f94e214e6`;
  the task-owned validator resources were deleted and the installed agent
  remained healthy and idle. The native x86 proof used ReleaseSafe `spore`
  SHA256
  `51a44ddf5788ee87753701787781c0b429e4609ad06a4e1a572e24e00a4a9871`
  and default-debug harness SHA256
  `acdfa526631e935a43988f76af2c24e58093d1388e36f4e174e11c9ce44909cf`.
  All six launch/lifecycle entry points returned the exact runner-boundary
  error with unchanged state and no lingering process. Default-cache,
  `--no-cache`, and missing-context builds returned the exact build boundary
  error without reading or mutating inputs, caches, or output; a retained
  prior product also seeded a real task-owned warm cache that the new product
  rejected without mutation. A native static backend test passed 22/22,
  including public x86 readiness remaining closed while internal binding
  selection reached `KvmRunnerNotLanded`. A compile-time-filtered native
  internal test passed the lifecycle public-readiness expectation exactly once;
  its two implicit module blocks also passed for a 3/3 total. Isolated chroot
  controls returned `MissingKvmDevice` without `/dev/kvm` and `KvmOpenFailed`
  for a task-owned mode-000 device, leaving the host device unchanged. The
  harness remained
  byte-identical to the already validated Stage 1.2 lifecycle harness, so its
  complete idle, reboot, native-poweroff, and doorbell matrix did not require
  another execution. The retrieved post-fix remote archive SHA256 is
  `7a778216243bd2342f27723aa9dad49f480e96b804ad14acde02272010f72615`;
  its 166 entries verify, and the local critical-manifest SHA256 is
  `d5d81f875404c7e879333708b8c0c89cb7fde93ada96a7ca34cb30f3813d6f32`.
  The private transfer object and bucket were deleted and proven absent; the
  task-owned remote workspace and evidence archive remain retained. A final
  adversarial auto-review found the public-readiness and build-gate omissions,
  then a later review found one stale lifecycle-test expectation. The fixes
  and final native proof above close all three findings.
- Stage 1.3 now freezes the candidate-profile audit contract without claiming
  a usable profile. One atomic status remains `pending_stage0b`; ordered
  decision inventories cover CPUID topology/identity/XSAVE/PV selectors,
  hard VMX/SVM exclusions, the architectural 576-byte legacy-plus-header and
  Linux KVM 4096-byte legacy XSAVE boundaries, every plan-named MSR, the
  profile-specific KVM capabilities, and the unresolved clock questions.
  Concrete masks, layouts, MSR dispositions, clock values, host facts, and
  compatibility remain unavailable until Slice 0b. The exact reviewed patch
  before this evidence ledger has SHA256
  `028bfe789c14078399ae15bc47def0db111196e08e7a861ded5787597a7d2e56`.
  The focused x86 suite passed 479 tests with five expected skips and 32 fuzz
  targets; the full `mise run test`, `mise run build`, formatting, and diff
  hygiene pass. A ReleaseSafe static x86-64 test binary with SHA256
  `6c5f091c83f55ce704cbeae251e0262ef18b9ac4a270936f8bfb866b1fa38523`
  ran natively on the dedicated host's Linux 6.17.0-1019-aws kernel and passed
  all six profile-contract tests with no residual process. The retained remote
  test artifact is mode 500 and owned by the task user; the transient S3
  transfer object and bucket were deleted and the bucket returns 404. Final
  adversarial and
  minimality reviews approved the exact pre-native patch, and the Anthropic
  Fable continuation approved it with no material finding.
- Stage 0b.1 now has a candidate implementation and exact native evidence. The
  five-file probe source-set manifest has SHA256
  `c2d2a695e9b5065fb4ac29ed6b82011b96cbf9c1c3c58a89b708409bec8cb19a`;
  its static x86-64 artifact has SHA256
  `df8bc5a0186f3c00441bf6d707d944bed31aab78fadcbb0330f2508591121881`.
  On the dedicated Intel bare-metal host running Linux 6.17.0-1019-aws, the
  probe observed KVM API 12, all 15 required capabilities plus both contextual
  capability checks, canonical raw/requested/effective CPUID sets with
  46/47/47 entries, all 22 feature MSRs, and all 96 ordinary advertised MSRs.
  Both MSR reads completed exactly; the no-irqchip probe deliberately did not
  infer that the advertised ordinary inventory was a context-free writable
  restore set. The 4096-byte XSAVE state and one XCR round-tripped exactly,
  VM/vCPU TSC frequency remained 3000000 kHz, and the VM clock remained
  nondecreasing. The terminal evidence ledger has SHA256
  `d4909f661e5bc23eab689bb45f50618e9f559c7a1ca471ee2e71c2e2b5eca605`;
  complete stdout and strace have SHA256
  `b5129a615976c5dbfe3ae1fae57c9c9bc9979fb18c64017f5c6d4e73d47f01b4`
  and
  `8e2ca51ba4d9ca8e1226e324a4930da54462fa94b626a86895a04147c2ce9d01`.
  Independent validation found zero stderr bytes and no `KVM_RUN` across 58
  traced ioctls, while the result remained fail-closed as
  `profile_approved=false`. The first native attempt also proved why the
  narrower contract matters: an advertised `MSR_KVM_ASYNC_PF_INT` zero write
  is rejected without an in-kernel irqchip. Stage 0b.2 therefore owns the
  explicit restore-list classification and write-order proof under the real
  irqchip-owning machine. The transient private transfer object and bucket
  were deleted and proven absent; the task-owned native evidence remains
  retained on the dedicated host. The focused x86 suite passed 487 tests with
  five expected skips and 32 fuzz targets; the full `mise run test`, product
  build, x86-64 compile-only suite, static probe cross-build, formatting, and
  diff hygiene all pass. The final auto-review ship-risk and maintainability
  lenses approved after one low-severity shared MSR-batch cleanup; the
  Ponytail lens found no additional simplification that preserved the bounded
  evidence contract. The final Anthropic Fable deep-analysis approved Stage
  0b.1 with no material finding; its residual risks are the Stage 0b.2 work
  named below rather than omissions from this reset-state inventory.
- Stage 0b.2 now has a candidate implementation and exact native evidence. The
  deterministic guest dirties host-owned x87, XMM, and YMM patterns behind an
  exact x87/SSE/AVX-only CPUID and XCR0 contract, samples TSC and all three
  plan-named clocks, and crosses CAPT/RSTR generation-device barriers through
  a shared, fuzzed mailbox ABI. The task-local state codec encodes normalized
  architectural fields with bounded inventories and a SHA-256 footer; restore
  requires a regular, single-link, owner-only file and matches its XSAVE length
  to the destination KVM capability before any CPU-state ioctl. The final
  ReleaseSafe static harness SHA256 is
  `a73c7a6e2832548dfd7ce9aa3309c70aea73da5d6aecbcaca46fb1579f0a5a1e`,
  the deterministic initrd SHA256 is
  `e74c394ec802ff9567f04021f3e9f7f8b72d19042f08e140584e3aae7ba87442`,
  and the proof used the Stage 0a.2 managed bzImage above. Capture PID 124955
  exited before restore PID 124964 started. The resulting 67,119,212-byte
  mode-0600, single-link state file is owned by the task user and has SHA256
  `347f5bfcffc3ec626c40c687b929cc6158cf43ee171dc0e70516e7a21abf2c6a`,
  matching the digest emitted by capture. Captured xstate was exactly `0x7`
  with uncompacted layout and a 4,096-byte KVM XSAVE buffer; all 21 classified
  MSRs restored and read back. Guest TSC advanced from 869132316 to 4573046988;
  monotonic time advanced from 11307879ns to 1245966648ns, boot time from
  11307945ns to 1245966728ns, and realtime from 1784446571161109000ns to
  1784446572395767855ns. Capture and restore strace SHA256 values are
  `9657ac81f84343fe4cbb4391125553ff1c0eb528e457ddd816d128bb23bc9c5d`
  and `5e18c40a5693d5665f0ee86a22eca5fd6f7d7bed21b891d66abb3bafd39ff79e`.
  Only BSP vCPU fd 5 entered `KVM_RUN`; restore applied CPU and clock state on
  trace lines 149-160, read back both MP states and every restored CPU/clock
  class on lines 161-172, then made its first and only `KVM_RUN` on line 173.
  No source process existed before restore and no process remained afterward.
  The focused profile suite passes 24/24 with two registered fuzz targets;
  `mise run test`, the exact flaky-listener binary and seed, `mise run build`,
  the ReleaseSafe static cross-build, deterministic-initrd test, formatting,
  and diff hygiene pass. Final ship-risk and maintainability reviews approve
  with no finding remaining. Anthropic Fable independently returned `SHIP`
  with no milestone blocker; its grounded CPUID/MP/SREGS cleanups are included,
  while the native oracle correctly rejected its optional whole-RAM equality
  suggestion because restoring `MSR_KVM_WALL_CLOCK_NEW` rewrites the pvclock
  page before first run. The transient transfer objects and bucket were deleted
  and the bucket is proven absent; the task-owned native evidence remains
  retained on the dedicated host.
- Stage 0b.3 approves `sporevm-x86_64-v0` for same-host capture and restore.
  The profile fixes GenuineIntel CPUID with xAPIC topology, x87/SSE/AVX state
  (`XCR0=0x7`, 832 architectural XSAVE bytes), a 3,000,000 kHz guest TSC, the
  two proved KVM clock flags policies, 15 ordered MSRs, and a typed capability,
  CPUID, MSR, XSAVE, TSC, and offset compatibility predicate. Its v3 task-local
  codec records two complete, independent per-vCPU CPU/TSC/LAPIC/event/debug/MP
  inventories plus VM-wide clock, PIC, IOAPIC, and PIT2 state without persisting
  KVM structs or transfer-buffer padding. The configured CPUID remains distinct
  from KVM's CR4/XCR0-derived effective readback, XSAVE records contain exactly
  832 architectural bytes with checked metadata and reserved bytes, and active
  SMM/SMI and triple-fault state fail closed. The dedicated host reports
  `KVM_CAP_INTR_SHADOW=0`, but `KVM_GET_VCPU_EVENTS` supplies the canonical
  validity flag and interrupt-shadow value, and the exact SET/GET round trip
  succeeds through that API, so the absent legacy capability is not claimed.
  The final ReleaseSafe harness SHA256 is
  `a50a132bac47f2a55dab0c4e0bce9e1ed63834764f18e0318b557b52795f32d1`;
  the initrd and managed bzImage retain their Stage 0b.2 hashes. Capture PID
  126470 exited before restore PID 126479 started, and no source or residual
  harness process existed at either boundary. The 67,117,792-byte private
  single-link state file has SHA256
  `627385f3a3b8d6eb1849d6fdd60e189721da034094e6db7c47b90ce8479adba1`.
  Guest TSC advanced from 1490755458 to 5184221008, monotonic time from
  223116978ns to 1454292198ns, boot time from 223117041ns to 1454292287ns,
  and realtime from 1784452534772147745ns to 1784452536003322978ns. Capture
  and restore strace SHA256 values are
  `fe7199cc1a9f0f41c1b1814add01ae0068939fe888efb9d44fb0a29af7d0a2d6`
  and `94d3fcad185734b2dc261e37d11dd152307e30c6c490ac9baf8b42478711577f`.
  Restore sets both configured CPUID tables on lines 156 and 158, applies all
  VM devices on lines 162-165, applies every BSP CPU/device class on lines
  166-179 and every AP class on lines 180-193, then sets the clock on lines
  194-195. It reads back the full BSP inventory on lines 199-211, the full AP
  inventory on lines 212-224, and all VM devices on lines 225-228 before its
  first and only `KVM_RUN` on line 229. The narrow candidate caused Linux to
  issue one exact
  `0x80 <- 0x00` legacy I/O-delay write while programming the in-kernel PIC;
  that measured no-op tuple is now part of the finite PIO policy, while every
  neighboring value and shape still fails closed. Anthropic Fable's first
  review found the decode cleanup, XSAVE normalization, and duplicated LAPIC
  validation defects fixed here; two post-fix Fable attempts were refused by
  Anthropic's classifier before analysis, while the final local ship and
  maintainability reviews approve with no material finding.
- Stage 1.4 completes the `spore.host-info.v2` contract. It preserves the
  ARM-shaped v1 Zig/JSON contract and C symbol, adds the ABI-version-16
  `spore_host_info_json_v2` entry point, and reports tagged ARM or x86
  board/profile/KVM-capability facts without executing host-specific
  instructions in the fixture renderer. Exact compact JSON goldens cover both
  architecture variants, a checked-in pretty-JSON golden pins the C v1
  serializer bytes, and the live C v1 test pins its final newline and NUL.
  Missing or invalid probe values now report `kvm_probe_failed`, while observed
  insufficient values report `profile_capability_missing`. On the dedicated
  x86 host (c5d.metal, Linux 6.17.0-1019-aws), exact ReleaseSafe CLI SHA256
  `1336168f105086bc6843b173e73c076cf2ed4a864f7719a38f0806e764dd8427`
  reports all 21 profile capabilities satisfied and the intentional
  `runner_not_landed` backend state; exact static C smoke SHA256
  `8ec4c676d7de28b943dbc0b458bc84d24da907ce809a217d46bfcb3f734acc17`
  executes successfully, with no residual `spore` process.
- Stage 1.5 completes architecture-specific embedded guest artifacts and the
  x86 cross-build lane. `build.zig` derives the guest architecture and
  generation GPA from the canonical board, the generator rejects mismatched
  pairs and dynamically linked or wrong-machine executables, and its direct
  newc writer fixes ordering, modes, ownership, mtimes, and padding. The wired
  test byte-compares ARM and x86 archives across different umasks,
  `SOURCE_DATE_EPOCH` values, and compiler selection paths, then parses every
  archive member and executable. The full native suite, deterministic-initrd
  test, native build, ReleaseSafe ARM and x86 musl builds, formatting, and diff
  checks pass. Anthropic Fable and the local reviews return `SHIP`; the
  adversarial review's probe-diagnostic and C-golden findings are fixed. The
  transient transfer bucket was deleted and proved absent; private task
  evidence retains the exact host outputs. Completing Stage 1.5 completes
  Slice 1.

## Motivation

SporeVM currently compiles its KVM product backend only for aarch64 Linux. The
shared device, storage, bundle, network, guest-agent, and product lifecycle
layers are mostly architecture-neutral, but the boundaries below them are
explicitly ARM-shaped:

- `src/board.zig` defines one DTB, GICv3, PSCI, timer, and contiguous RAM map;
- `src/boot.zig` implements the aarch64 `Image` boot protocol;
- `src/kvm/kvm.zig` exposes the ARM KVM one-reg, VGIC, PSCI, and counter APIs;
- `src/kvm/snapshot.zig` maps normalized aarch64 registers and GIC state;
- `src/spore.zig` gives manifest v2/v3 one fixed aarch64 machine-state shape;
- `src/guestmem.zig` assumes one contiguous guest-physical RAM interval;
- managed kernel, initrd, OCI, build, CI, and release paths name ARM64 directly.

Adding x86-64 by weakening those checks would create manifests whose fields do
not mean the same thing on both architectures. The implementation instead
adds an explicit architecture boundary and keeps every saved machine state
unambiguous.

## Goals

- Run `spore run`, `spore create`, named lifecycle, and `libspore` on x86-64
  Linux hosts with `/dev/kvm`.
- Select and validate `linux/amd64` OCI images on x86-64 while retaining
  `linux/arm64` on aarch64.
- Keep the frozen device inventory: virtio-mmio console, blk, net, vsock, rng,
  optional transient virtio-mem, and the SporeVM generation device.
- Preserve the rootfs, chunk-index disk, bundle, network-policy, generation,
  and session contracts across architectures where they are already
  architecture-neutral.
- Define a fixed, versioned x86 board profile and an explicit x86 CPU profile.
- Support fixed-memory single- and multi-vCPU capture, same-host-class resume,
  offline fork/fan-out, named save/restore, and non-destructive save.
- Keep `--memory auto` as the same 16GiB guest-visible product contract once
  x86 support is released, with transient virtio-mem state still excluded from
  saved manifests.
- Keep existing aarch64 manifest bytes readable and writable without silently
  migrating them.
- Fail closed when the host lacks a required KVM capability, CPU-profile
  feature, clock control, interrupt-controller feature, or managed artifact.
- Add native x86 CI, packaged smokes, release archives, and architecture-scoped
  benchmark history before declaring support shipped.

## Non-Goals

- No x86 guest execution through Hypervisor.framework on Apple Silicon.
- No software emulation, TCG, Rosetta, or cross-ISA spore conversion.
- No Intel-macOS HVF backend.
- No Windows host backend or Windows guest support.
- No PCI, PCIe, ACPI device model, UEFI, BIOS, or legacy serial-console product
  surface. The x86 guest continues to use virtio-mmio and `hvc0`.
- No nested virtualization exposed to guests. VMX and SVM stay outside the x86
  CPU profile and no nested KVM state is serialized.
- No broad KVM framework rewrite before the x86 boot proof.
- No promise of restore across arbitrary x86 vendors, microarchitectures, or
  TSC domains. The first contract is an explicit compatible host class.
- No cross-platform Docker build emulation. `spore build` executes native
  `linux/amd64` stages on x86 and native `linux/arm64` stages on ARM.
- No persisted virtio-mem state; saved x86 spores use fixed RAM just as saved
  aarch64 spores do today.

## Product Contract

### Architecture names

One module must own the spelling conversions so platform strings do not drift:

| Surface | ARM | x86 |
| --- | --- | --- |
| Spore manifest | `aarch64` | `x86_64` |
| OCI and CLI platform | `linux/arm64` | `linux/amd64` |
| Zig target | `aarch64-linux-musl` | `x86_64-linux-musl` |
| Host class prefix | `linux-aarch64-kvm` | `linux-x86_64-kvm` |
| Release archive | `spore_Linux_arm64` | `spore_Linux_x86_64` |

Aliases may be accepted at host-detection boundaries, but manifests and cache
keys use only the canonical spelling. Architecture remains part of OCI config,
rootfs source metadata, build cache identity, managed artifact identity,
benchmark history, and release selection.

### Native execution

On a supported x86 host:

- `--backend auto` resolves to KVM;
- `--backend kvm` is supported;
- omitted OCI platform resolves to `linux/amd64`;
- `spore run --image`, `spore rootfs`, and `spore build` validate amd64 image
  metadata;
- an explicit `linux/arm64` run/build request fails before boot;
- x86 spores inspect, pack, push, and pull on either host architecture, but
  resume/fork execution requires a compatible x86 host;
- `spore host-info` reports the x86 board and CPU profiles and the exact reason
  KVM is unavailable when a required capability is missing.

Offline bundle transfer remains architecture-agnostic. Execution never relies
on the filename or caller to choose the right architecture; it reads the
validated manifest and rejects a mismatch.

### Compatibility level

The initial support level is **same host class**, matching SporeVM's practical
fork/fan-out contract. An x86 CPU profile names a normalized CPUID/MSR/clock
contract. A destination may restore a spore only when it can instantiate that
exact profile. Cross-vendor and broad live-migration compatibility are later
profile work, not best-effort behavior.

## Architectural Decisions

### Keep KVM as the backend name

Do not add a public `kvm-x86` backend. Backend and guest architecture are
independent facts. `run.Backend.kvm` selects Linux KVM; compile-time dispatch
selects the aarch64 or x86-64 implementation. Event schemas and lifecycle
metadata keep reporting `kvm`, while host-info and manifest platform fields
carry architecture and profile details.

### Add architecture-owned board and boot modules

The current `board.zig` and `boot.zig` remain the aarch64 contract until a
mechanical rename can be done without mixing it with bring-up. Add x86-owned
modules for:

- the fixed guest-physical address map;
- bzImage parsing and Linux boot-parameter construction;
- command-line and initrd placement;
- E820 memory entries;
- bootstrap page tables, GDT, and initial vCPU register state where required;
- MP-table or equivalent CPU discovery for multi-vCPU boot;
- virtio-mmio and generation-device MMIO/interrupt assignments.

The bring-up stages record the provisional board in this plan and retained
native evidence. Slice 2a commits the product board to `docs/spore-format.md`
before the product runner consumes it or snapshots use it. The board must
reserve the architectural APIC/IOAPIC and
legacy regions, KVM's three-page TSS and one-page identity-map regions below
4GiB, a bounded 32-bit MMIO window, low boot memory, and high RAM above the
32-bit hole. Exact addresses are chosen by the boot spike and then frozen under
`sporevm-x86_64-board-v0`. The boot loader reads the bzImage protocol fields,
including `initrd_addr_max`, and reserves the zero page, command line, GDT,
MP table, kernel, and initrd before generating E820 from the same region table
used by guest-memory translation.

The spike must prove that the managed kernel enumerates every current
virtio-mmio device from bounded kernel-command-line descriptors. If that does
not work for multi-vCPU and all required devices, stop and revise the board
contract before adding PCI or ACPI by accident.

The board also owns the x86 exit contract. The boot spike records every
`KVM_EXIT_IO` produced by the managed kernel with the full frozen device count
and at least two vCPUs, then freezes a minimal table of ports that are ignored
for boot compatibility or decoded for reset. Port 0x80, CMOS, i8042, or any
other legacy access is allowed only when the trace proves it is required.
Every port outside the frozen table fails closed. The spike first tests
existing KVM system events and observed reset mechanisms, recording the raw
KVM exit behind each `guest_reset` or `guest_off` classification. An ACPI-less
x86 kernel may have no distinct architectural poweroff mechanism. If native
evidence confirms that, the pre-authorized fallback is an x86 board-v0
poweroff doorbell in the existing SporeVM generation-device MMIO page, with an
explicit device-model-version decision, format/design documentation,
`SECURITY.md` update, and same-stage fuzz/tests. Conflating reset and poweroff
is not an acceptable final contract.

Any other new port or device requires the same frozen-device-model process:
update the durable format, security inventory, relevant design doc, version,
parser/fuzz coverage, and native compatibility evidence before freezing the
board. Monitor stop remains a host lifecycle action and must not depend on a
guest poweroff path. The current persistent agent reports command exits over
its transport rather than powering off the VM, so dedicated initrd smokes must
exercise reboot and poweroff directly.

### Introduce segmented guest memory when high RAM requires it

x86 cannot safely model useful RAM as one physical interval without colliding
with APIC, IOAPIC, and MMIO holes. Replace the device-facing contiguous
`GuestRam` assumption with a bounds-checked `GuestMemory` over a small, sorted
set of non-overlapping regions. Each region maps:

```text
guest physical address range -> linear backing offset -> host bytes
```

The linear backing remains one contiguous host VMA and is still the chunking,
lazy-fault, dirty-sealing, and local-backing authority. KVM memory slots carve
low and high GPA regions from that VMA; they do not create independent backing
objects. A new manifest memory-region table defines the mapping. Validation
requires:

- page-aligned GPA, backing offset, and size;
- nonzero, bounded region count and sizes;
- strictly sorted, non-overlapping GPA ranges;
- strictly sorted, gap-free backing ranges beginning at offset zero;
- exact coverage of `memory.logical_size` and the declared fixed RAM size;
- no overlap with permanent non-RAM board ranges: MMIO, interrupt-controller,
  legacy, TSS, and identity-map holes;
- checked arithmetic for every end address and translation.

Transient boot allocations are RAM contents, not holes in the manifest. The
boot planner separately proves that the zero page, command line, GDT, MP table,
kernel, and initrd are disjoint, satisfy their protocol placement constraints,
and remain fully contained in declared RAM so capture preserves their bytes.

Virtqueue and device parsers continue to request guest-physical slices through
one security boundary. Initially, a descriptor crossing a physical region or
hole is rejected consistently even when the corresponding backing offsets are
adjacent; it must never be translated by unchecked pointer arithmetic. Dirty
observations from each KVM slot translate GPA ranges back to backing offsets
before selecting 2MiB memory chunks. One userfaultfd registration covers the
linear VMA, while slot-specific dirty bitmaps are folded into the shared
backing-offset tracker.

The aarch64 adapter initially exposes its current single region through the
same interface. Existing aarch64 manifest v2/v3 files keep their implicit
single-region meaning. This refactor is deliberately deferred until Slice 6:
bring-up and fixed-memory capture use the current checked `GuestRam` with one
low RAM region of at most 2GiB and one KVM slot. The v4 parser validates the
complete bounded region schema from its first writer; the x86 execution
capability check temporarily requires exactly one low region until high RAM
support lands. Identical v4 bytes never change schema validity when Slice 6
removes that runtime restriction.

### Split common and architecture-specific KVM UAPI narrowly

Extract only the KVM pieces both architecture paths consume: `/dev/kvm`
open/version checks, VM/vCPU creation, run mapping, memory slots, generic MMIO
exit layouts, and interrupt-line calls. Move dirty-log UAPI when x86 capture
creates its second consumer. Keep architecture UAPI and policy separate:

- ARM one-reg, VGICv3, PSCI, and counter control stay ARM-owned;
- x86 CPUID, regs/sregs, XSAVE/XCRS, MSRs, LAPIC/irqchip/PIT, vCPU events,
  debug registers, MP state, and clock/TSC controls stay x86-owned.

Do not rewrite the mature ARM run loop into a speculative trait hierarchy.
The non-product x86 boot spike may grow into a small architecture-specific
fresh-run loop through Slice 3a because the current loop interleaves ARM boot,
VGIC, PSCI, and snapshot policy. Reuse proven device, agent, network, and disk
helpers rather than first rewriting the ARM loop. Before x86 capture lands,
extract the concrete quiescence, transport capture, disk publication, lazy RAM,
dirty sealing, wake, and monitor mechanics that both paths actually share; do
not introduce a generic runtime trait or duplicate capture orchestration. The
x86-owned boundary covers boot, CPU, irqchip, PIO, machine state, and terminal
exit classification for `KVM_EXIT_SHUTDOWN`, `KVM_EXIT_SYSTEM_EVENT`, and
PIO-decoded reset or poweroff.

### Version host-info around architecture-specific facts

The current `spore.host-info.v1` schema is ARM-shaped: it reports aarch64 and
GIC addresses, and the Zig `PlatformFacts` surface exposes those fields. Add a
`spore.host-info.v2` architecture discriminator and architecture-specific
facts rather than filling GIC values with misleading zeroes on x86. JSON
consumers receive either ARM interrupt-controller/counter facts or x86
board/CPU/KVM capability facts with an explicit not-applicable shape.

Preserve the existing C `spore_host_info_json` v1 contract on ARM and add an
explicit versioned v2 API for both architectures; the v1 entry point fails with
a documented unsupported-architecture error on x86 rather than returning a
different schema. The Zig API changes deliberately to a discriminated v2 type.
V2 uses its final platform/profile shape from the start; until native approval,
the existing backend availability fields report `available: false` with a
precise profile-not-approved reason. Add independent v1 compatibility and v2
rendering tests. An offline inspect on either host must render both
architectures without executing host-specific instructions.

### Keep x86 machine state normalized

Manifest data must never contain raw `kvm_*` structs, ioctl buffers, or opaque
host blobs. Define field-by-field architectural representations for:

- general registers and RIP/RFLAGS;
- segment, control, descriptor-table, and interrupt state;
- x87/SSE/AVX state under a versioned XSAVE feature mask;
- XCRs;
- an explicit bounded MSR list keyed by architectural MSR number/name;
- LAPIC state;
- PIC, IOAPIC, and PIT state when the in-kernel irqchip owns them;
- vCPU events, MP state, and debug registers;
- VM clock and TSC frequency/offset state;
- the CPU profile and vCPU topology.

The state audit must explicitly classify KVM paravirtual MSRs
`MSR_KVM_SYSTEM_TIME_NEW`, `MSR_KVM_WALL_CLOCK_NEW`,
`MSR_KVM_STEAL_TIME`, `MSR_KVM_ASYNC_PF_EN`, and
`MSR_KVM_PV_EOI_EN`; TSC and `MSR_IA32_TSC_ADJUST` semantics; LAPIC/x2APIC
mode and capability; and the effect of `KVM_KVMCLOCK_CTRL` around a paused
vCPU. Each item is either normalized and restored, excluded from the CPU
profile, or proven to have an architectural reset/default value. The profile
does not expose SMM. Capture fails if a vCPU is in SMM or has pending SMI state.

The audit also names `MSR_KVM_ASYNC_PF_INT`, `MSR_KVM_ASYNC_PF_ACK`,
`MSR_KVM_POLL_CONTROL`, legacy pvclock MSRs `0x11` and `0x12`,
`MSR_IA32_TSC_DEADLINE`, and `KVM_CAP_XSAVE2`/`KVM_GET_XSAVE2` for XSAVE
areas larger than 4KiB, rather than assuming they are covered by LAPIC or the
first-pass paravirtual list.

The exact inventory is established by a save/restore state audit against the
managed kernel. Unsupported or unreadable required state fails capture. Unknown
required state in a future manifest fails restore. Optional state is allowed
only when its absence has a documented architectural default.

Restore ordering is represented as named constraints rather than an
unimplementable premature total order. Validate that the host can instantiate
the named profile first. Create the VM, configure the TSS and identity-map
addresses, and create the in-kernel irqchip before any vCPU. Then create every
vCPU and install its CPUID and remaining normalized state before any
`KVM_RUN`. Stage 0b.2 determines and tests the exact TSC/VM-clock ordering
instead of freezing one from reset-state observations. Restore device
transports and RAM, then inject any pending generation interrupt last. Slice
4b freezes the full order from native evidence and includes a test that fails
if any vCPU can run before all VM-wide and per-vCPU phases complete.

### Define a stable x86 CPU and clock profile

Add an `x86_cpu_profile` module that owns:

- the CPUID leaves and bits exposed to the guest;
- topology normalization;
- the XSAVE feature mask and serialized size;
- the required MSR index list;
- required KVM capabilities;
- the guest TSC frequency and clock policy;
- the profile name recorded in manifests and host-info.

Build the guest CPUID table from KVM's supported set intersected with an
explicit allowlist, rather than serializing the host table. Hide VMX/SVM and
other features whose state SporeVM does not save. A host supports the profile
only when KVM can instantiate every required leaf, MSR, XSAVE component, and
clock setting.

The first profile supports one CPU vendor only. Vendor identity is part of the
host-class evidence, not an inferred compatibility promise. The bring-up audit
must include x2APIC, TSS/identity-map requirements, XSAVE size and layout,
LAPIC round-trip behavior, and every MSR read/write count; a short KVM ioctl
return is a hard failure rather than a partially restored profile.

Prefer a fixed guest TSC frequency backed by KVM TSC control. If the dev host
cannot provide the required stable clock contract, stop at fresh-run support
and design the alternative before enabling capture. Capture/resume must record
and re-anchor the KVM clock and architectural timer state without allowing
guest time to move backwards. Wall-clock policy remains the existing
generation-device concern.

### Use a new manifest version without rewriting ARM spores

Add manifest format v4 for x86 architecture-discriminated machine state.
Existing v2 single-vCPU and v3 multi-vCPU aarch64 manifests remain
byte-compatible and continue to use their current parsers and writers. The
first v4 writer is x86-only; do not move ARM onto v4 as part of this port.

V4 is a concrete x86 schema whose platform fields are its discriminator:

```text
platform.arch: x86_64
platform.board_profile: sporevm-x86_64-board-v0
platform.cpu_profile: sporevm-x86_64-v0
platform.vcpu_count: N
platform.device_model_version: N
memory.regions: [...]
machine.vcpus: [...]
machine.interrupt_controller: {...}
machine.clock: {...}
```

The precise JSON layout belongs in `docs/spore-format.md` before the writer
lands. Parsing first reads only a bounded version discriminator, then invokes
the exact strict parser for that version. Do not make one giant struct whose
architecture-specific members are nullable.

Before adding v4, replace the existing private nullable v2/v3
`bundle.LoadedManifest` modes with a tagged ownership union that makes exactly
one loaded version representable. Add concrete v4 as the third tag for offline
bundle operations. Keep explicit version branches at architecture-specific
machine validation, fork IRQ state, and restore dispatch. Extract a broader
shared loaded view only after at least two callers require identical common
fields; do not add a generic machine union, a fourth manifest abstraction, or
migrate old files as part of the first v4 writer.

The v4 parser, memory-region validation, x86 state validation, and version
dispatch extend the existing manifest fuzz targets in the same slice. Bounds
must cover vCPU count, MSR count, XSAVE bytes, interrupt-controller entries,
memory-region count, and aggregate decoded allocation.

### Preserve the device model

Use the existing virtio-mmio transport and devices. x86 supplies a different
board address and GSI mapping, but transport feature negotiation, queue state,
device ordering, rootfs device bindings, and snapshots remain shared.

The guest agent must learn the x86 generation-device MMIO address from one
generated or validated board source rather than a second handwritten constant.
The kernel receives matching virtio-mmio descriptors. The x86 managed-kernel
gate must prove `/dev/mem` can map that page under its `CONFIG_DEVMEM`,
`CONFIG_STRICT_DEVMEM`, `CONFIG_IO_STRICT_DEVMEM`, and PAT/cache policy.
Expected PIO is restricted to the frozen board table described above;
unexpected PIO or MMIO exits fail closed. Any new userspace exit decoder is
bounded and fuzzed because the guest controls it.

Offline fork sets generation state exactly once. The x86 restore path must
prove whether post-restore GSI injection from pending generation-device state
is sufficient. If the controller snapshot also requires a pending-line
mutation, that mutation belongs in the normalized x86 machine-state module and
gets a focused fork/restore test. Do not duplicate the ARM GIC manipulation by
analogy without this proof.

### Parameterize managed guest artifacts

The `sporevm/kernels` release must provide a checksum- and config-verified x86
bzImage. Kernel verification becomes architecture-specific and checks the x86
boot, KVM clock, SMP, virtio-mmio command-line discovery, console, blk, net,
vsock, rng, cgroup, seccomp, ext4, BPF, and virtio-mem requirements. The x86
config gate explicitly checks `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES`,
`CONFIG_X86_MPPARSE`, `CONFIG_KVM_GUEST`, the `/dev/mem` policy above, and the
kernel reboot path selected by the board spike.

Parameterize `make-minimal-exec-initrd.sh`, smoke initrds, Toybox, helper
binaries, and the build-generated embedded initrd by guest architecture. The
current C guest agent already has some x86 syscall/audit definitions; native
smokes must cover every helper rather than assuming compilation proves parity.
Kernel and initrd digests remain architecture-bound build/cache inputs.

### Preserve native-only OCI and build execution

Extend OCI platform parsing to `linux/amd64`, keep cache/ref identities
architecture-scoped, and validate config architecture at every import and run
boundary. Rootfs materialization may process either architecture because ext4
and OCI layers are data, but execution rejects a non-native guest platform.

`spore build` replaces hard-coded `linux/arm64` checks with the selected native
guest platform. Automatic `TARGETARCH` becomes `amd64` on x86. RUN stages,
stage inputs, managed artifacts, executor identity, and published OCI config
all carry that platform. No binfmt fallback is attempted.

### Make release artifacts unambiguous without breaking mise selection

Add `spore_Linux_x86_64.tar.gz` and checksum coverage. The current
architecture-less Linux libspore archive is ambiguous once two Linux
architectures ship. Do not choose new libspore names by inspection. The
current release builder explicitly rejects `libspore_*_arm64.tar.gz` because
older mise matching can select it as the CLI archive. Before publishing x86
libraries, build a fixture release and run the actual supported mise/ubi
selection paths against every candidate asset set. Then freeze names which
select the CLI and library for both architectures without ambiguity. If no
compatible shared namespace exists, use names which avoid the old CLI match
tokens or a separate libspore release stream; retain `libspore_Linux.tar.gz`
as the ARM64 compatibility asset until its supported clients can be retired.

The publish step must fail if any expected archive or checksum is absent. Add
the x86 build step to `release-publish`'s `depends_on` list and extend
`scripts/ci/buildkite-release.sh`, which currently downloads an ARM-only asset
set. The x86 package gets the same standalone C/Go libspore and packaged
product smokes as ARM64.

## Required Development Host Contract

The implementation loop needs an x86-64 Linux host with:

- `/dev/kvm` available to the development user;
- KVM API version 12 and the capabilities selected by the x86 profile;
- hardware virtualization without software emulation;
- enough RAM for the 16GiB sparse auto-memory smoke;
- a local filesystem suitable for runtime overlays, chunk stores, and packaged
  smokes;
- a Buildkite queue reserved for repository-owned validation once bring-up is
  stable.

Nested KVM is acceptable for early boot and functional iteration. Final clock,
dirty-tracking, snapshot, multi-vCPU, performance, and release evidence must run
on dedicated hardware. `spore host-info --json` should become the durable
capability report instead of relying on an ops-side machine label.

The ops repository owns provisioning and queue registration. This repository
owns a read-only capability probe and the exact required/optional capability
list. Missing infrastructure blocks native evidence, not architecture-neutral
unit work.

## Implementation Slices

Each slice should be independently reviewable and keep ARM64 green. A slice
does not claim x86 product support merely because its harness boots.

When a slice contains numbered stages, each stage is a separate local commit
and must pass its relevant local/native validation, auto-review, and Fable
review before the next stage begins.

The critical path begins `0a -> 1`. After Slice 1, the bare-metal profile audit
in Slice 0b runs in parallel with `2a -> 3a -> (3b || 3c)`. Stage 4a needs the
frozen board and approved profile; Stage 4b additionally needs Slice 3a; Stage
4c adds Slice 3b as a dependency. The remaining path is `4 -> 5 -> 6 -> 7`, and
Slice 3c must also be complete before Slice 7.

### Slice 0a: Freeze the board contract with a nested-capable boot spike

#### Stage 0a.1: Boot one vCPU through virtio-console

- Add a pure, bounded x86 bzImage/boot-parameter/E820 planner and provisional
  low-RAM board module with unit tests.
- Add only the x86 KVM UAPI required for VM creation, one memory slot,
  irqchip/PIT setup, CPUID, initial regs/sregs, one vCPU, MMIO, PIO trace, and
  terminal exits.
- Introduce the guest-controlled `KVM_EXIT_IO` envelope decoder as a bounded
  parser: validate direction, width, port, count, data offset, aggregate byte
  length, and the complete range within the mapped `kvm_run` pages. Add
  malformed-input tests, a fuzz target, and the initial `SECURITY.md` boundary
  in this same stage.
- Reuse the existing host-only `kvm-boot` front end, `GuestRam`, virtio-mmio,
  and console device. Keep product run, manifests, snapshots, OCI, networking,
  and managed artifacts out of this stage.
- On the dedicated x86 host, boot an explicit bzImage and static ticker initrd
  with no more than 2GiB RAM and require the console marker over `hvc0`.

**Exit:** pure planner tests pass on the local host, the harness cross-compiles
for x86-64 Linux, and the native host observes the ticker marker through the
existing virtio-console implementation.

#### Stage 0a.2: Prove SMP and the frozen device inventory

- Treat the candidate managed x86 kernel as an explicit cross-repository
  prerequisite: its reviewed config, prerelease bzImage, config, checksum, and
  provenance must exist before this stage begins.
- Add the MP table and start at least two vCPUs through the same harness.
- Bind all evidence from this stage onward to the digest and complete verified
  config of the candidate managed x86 kernel. Slice 3a must publish exactly
  this artifact or rerun and reapprove Stages 0a.2 and 0a.3.
- Instantiate the full console, block, net, vsock, and RNG virtio-mmio set plus
  the generation device at provisional x86 addresses and GSIs. Reserve and
  prove the complete eight-slot transport/GSI topology, including extra block
  devices used for context, build, and cache inputs. The provisional transient
  inventory fixes virtio-mem at slot 4 in place of the optional cache block,
  so it preserves the same eight transports, addresses, and GSIs.
- Add a static board-probe initrd that reports online CPUs, enumerated virtio
  device IDs, `hvc0` operation, and generation-device magic through `/dev/mem`.

**Exit:** the native probe reports two online CPUs, the required virtio
device-ID multiset, a working console, and generation magic without PCI, ACPI,
BIOS, or UEFI; static tests prove that the maximum eight-slot command line,
address, and GSI layout is bounded and collision-free.

#### Stage 0a.3: Freeze PIO, exit, and capability evidence

- Exercise ordinary boot, idle, reboot, and poweroff in PIO trace mode.
- Replace trace-wide permissiveness with the smallest proven allow/ignore/
  decode table and fail every other port.
- If the kernel exposes no distinct poweroff mechanism, implement and version
  the pre-authorized generation-device poweroff doorbell before freezing the
  board; do not report reset, triple fault, or a halted guest as poweroff.
- Record fresh-run KVM API/capability, CPUID control, irqchip/PIT,
  TSS/identity-map, x2APIC mode, CPU-vendor, and candidate-kernel evidence.
  Capture-only XSAVE/XCRS, MSR, LAPIC state, dirty-log, and clock probes belong
  to Slice 0b.
- Freeze the accepted provisional board, GSI, MP, PIO, generation, and exit
  contracts in this plan and update `SECURITY.md` with the finite PIO policy.
  Slice 2a writes the durable product board to `docs/spore-format.md` when the
  reusable modules enter the product path.
- Before freezing the board, lower a virtio GSI after any transport write that
  clears `interrupt_status`, including device reset rather than InterruptACK
  alone. Accept only 1-, 2-, and 4-byte accesses in every virtio window; the
  generation window may additionally accept aligned 8-byte accesses.
- Record why the MP floating pointer's provisional GPA-zero placement is found
  by the pinned kernel's bottom-1KiB scan and remains protected as reserved low
  memory; move it to a conventional firmware search range if the final managed
  kernel or board contract cannot make that dependency explicit and stable.

The Stage 0a.3 candidate freeze is `sporevm-x86_64-board-v0` at
`device_model_version = 1`. It retains the Stage 0a.2 eight-slot virtio-mmio
inventory at `0xd0000000..0xd0000fff`, GSIs 5 through 12, and the generation
page at `0xd0001000`, GSI 13. The shared SPGN register protocol stays at version
1 byte-for-byte on both architectures. The x86 board alone decodes offset
`0x020` as a stateless, edge-triggered poweroff doorbell: the exact aligned
32-bit command `0x46464f50` (`POFF`) yields `guest_off`; any write touching the
register with another width, placement, or value fails closed, and reads return
zero without a side effect. The aarch64 board has no corresponding control.

The finite PIO table is value-sensitive and contains only these native-observed
tuples:

| Direction | Port | Width/count | Value/result | Action |
|---|---:|---:|---|---|
| write | `0x70` | 1 byte / 1 | `0x0f` | continue |
| write | `0x71` | 1 byte / 1 | `0x0a` or `0x00` | continue |
| read | `0x64` | 1 byte / 1 | return `0x00` | continue |
| write | `0x64` | 1 byte / 1 | `0xfe` | `guest_reset` |
| write | `0x80` | 1 byte / 1 | `0x00` | continue (legacy I/O delay) |

Every other direction, port, width, count, or value fails closed. The port
`0x80` tuple was added only after the Stage 0b.3 candidate profile produced it
while initializing the in-kernel PIC; it carries no device state. The reboot
probe uses the native kernel path with `reboot=kbd nox2apic`; the first exact
`0x64 <- 0xfe` is terminal, so the later CMOS `0x8f` write observed only after
the trace harness ignored ten reset requests is excluded. Native ACPI-less
poweroff reaches `System halted` without a distinct terminal exit, so it is a
negative control rather than `guest_off`; the board doorbell supplies the
distinct outcome. `KVM_EXIT_SYSTEM_EVENT` reset/shutdown retains its typed raw
event classification, while raw `KVM_EXIT_SHUTDOWN` is an unclassified fatal
exit and never means reset or poweroff. Terminal PIO/MMIO exits are completed
before their normalized outcome is published, and evidence retains the vCPU,
raw KVM exit reason, envelope, and value. Every normal and error teardown path
joins the complete set of started vCPU workers before unmapping any `kvm_run`
page or closing a vCPU fd, so a live worker cannot address another vCPU's
released wake page.

The Intel MP floating pointer remains at GPA zero because the exact managed
Linux 6.1.155 kernel scans the bottom 1KiB in 16-byte steps. E820 reserves
`0x000..0x3ff`, and the maximum generated MP table ends within that scan window
below the GDT, so Linux cannot allocate over the discovery data. Replacing the
managed kernel requires revalidating this dependency. Stage 0a.3 records the
KVM API and required capability values, supported CPUID entry count, vendor,
leaf 1 and topology-leaf presence, x2APIC support plus guest `nox2apic` mode,
irqchip/PIT, TSS/identity-map, memory-slot, CPUID-install, and AP-state setup.
XSAVE/XCRS, MSR, LAPIC-state, dirty-log, and clock capture probes remain
explicitly deferred to Slice 0b.

**Exit:** the finite PIO/device-control table produces distinct deterministic
`guest_reset` and `guest_off` outcomes, each classification records its raw KVM
exit or board control, unknown PIO fails closed, and the documented board and
host-capability evidence matches the native run.

These stages are the Slice 0a review and commit boundaries. The spike may cap
RAM below the 32-bit hole and omit snapshots; its loop is disposable, but its
pure board, boot, MP, and PIO modules are the modules later wired into the
product. Completing the three stages is enough to begin Slices 1 through 3a;
it does not approve capture.

### Slice 0b: Build and approve the capture CPU/clock profile on bare metal

#### Stage 0b.1: Freeze the profile-probe UAPI and reset-state inventory

- Extend only the x86 KVM binding with the exact CPUID2, MSR-list/batch,
  XSAVE/XSAVE2, XCRS, TSC-frequency, VM-clock, and pvclock-pause UAPI. Bound
  every flexible buffer and reject short MSR transfers as incomplete state.
- Add one narrow host-only probe that records canonical capability values, raw
  and effective CPUID, leaf-D layout, ordinary and feature MSR inventories,
  reset-state XSAVE/XCRS round trips, TSC kHz, and VM-clock observations from
  disposable VM/vCPU fds. It must perform no `KVM_RUN` and cannot approve a
  profile. The no-irqchip probe reads the complete advertised MSR inventory but
  does not treat it as a writable restore set; MSR writeability and ordering are
  proven against the real irqchip-owning machine in Stage 0b.2.

**Exit:** pure ABI and evidence validators pass on both architectures, and the
dedicated x86 host reproduces a bounded reset-state inventory whose exact
counts and KVM-reported sizes match the emitted evidence.

#### Stage 0b.2: Prove dirty CPU state and clocks across a new process

- Reuse the existing x86 boot lifecycle with a tiny deterministic guest probe
  that dirties known x87, SSE, and AVX values; reports CPUID and XCR0; and
  samples serialized TSC plus `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME`, and
  `CLOCK_REALTIME` at a host-controlled capture barrier.
- Capture into a bounded task-owned state file, exit the VMM process, restore
  into a new process without allowing any vCPU to run early, and prove the
  guest state patterns and monotonic clocks survive. Treat reset-state byte
  equality as ABI evidence only, never migration evidence.

**Exit:** the candidate xstate and time contract survives a complete
process-boundary restore on the dedicated host with no backward monotonic or
boot-time observation.

#### Stage 0b.3: Approve the concrete candidate profile

- Starting from Stage 1.3's audit contract and the prior two native proofs,
  finalize the CPUID allowlist/topology, required/default/excluded MSRs,
  XSAVE/XCRS layout, capability predicate, clock policy, profile identity, and
  typed host compatibility tests. Product fresh runs may use the visibly
  experimental candidate; capture may use it only after this stage approves
  it.
- Round-trip the candidate LAPIC/x2APIC, vCPU-event, MP, irqchip/PIT, CPU, and
  clock inventory, with every VM-wide and per-vCPU phase complete before the
  first `KVM_RUN`.

**Exit:** the named CPU/clock profile is instantiable on dedicated hardware and
guest monotonic time does not move backwards across the proposed restore. This
same-host proof gates Slice 4, not fresh-run work; release reproducibility on a
replacement or second same-class host remains a Slice 7 gate.

### Slice 1: Establish architecture and KVM module boundaries

#### Stage 1.1: Extract the proven common KVM UAPI

- Add one `src/kvm/common.zig` module for the fixed architecture-neutral Linux
  KVM API version, generic ioctl numbers, memory and IRQ structs, shared
  `kvm_run` header/MMIO/system-event layouts, and low-level helpers required by
  the existing ARM backend and the planned x86 path.
- Keep ARM one-reg, VGICv3, PSCI, counter, device-attribute, and completion
  policy in the ARM module. Keep x86 CPUID, register, irqchip/PIT, MP, TSS,
  PIO, immediate-exit, and `EAGAIN` policy in the x86 module.
- Preserve the existing public helpers and architecture-specific `/dev/kvm`
  open, capability-result, IRQ encoding, MMIO decoding, exit-classification,
  run-completion, and error/log semantics while removing duplicate constants
  and layouts. Do not add a generic backend trait or change either run loop.
- Assert the shared `kvm_run` header, MMIO, system-event, memory-region, and IRQ
  ABI layouts in host-runnable tests.

**Exit:** both architecture bindings consume the one common UAPI source and
all existing callers compile unchanged. `mise run test`, `mise run build`, the
cross-builds, and the native ARM64 fresh/multi-vCPU smoke pass. The
default-debug x86 harness remains byte-identical; if it changes, rerun the
complete Stage 0a.3 idle, reboot, native-poweroff, and doorbell matrix against
its new SHA256 before committing.

#### Stage 1.2: Add canonical architecture and backend selection

- Add one internal architecture identifier and the conversions required now
  for compile targets, manifests, CLI display, and host classification. Slice
  3b owns OCI selection policy, and Slice 7 owns release asset names after the
  mise/ubi fixture.
- Allow Linux x86-64 product builds and compile-time host detection, selecting
  the x86 KVM binding and internal capability predicate. Stage 1.4 owns public
  host-info exposure. Keep launch, attach, and capture entry points fail closed
  with an explicit runner-not-landed error until Slices 2a and 3a wire the
  fresh-run path.
- Promote the spike's x86 bindings behind the architecture boundary and expose
  one internal backend-availability result without maintaining a second set of
  common constants.
- Limit this stage's availability probe to the KVM device, API version, and
  already-proven bring-up capabilities. Stage 1.3 exclusively owns the CPU
  profile's CPUID, XSAVE, MSR, and clock predicates.

**Exit:** the Linux x86-64 binary builds, internal backend tests report the
exact KVM availability reason, and product launch fails at the explicit runner
boundary before artifact resolution or VM creation, while every existing ARM
backend-selection test remains green.

#### Stage 1.3: Freeze the candidate-profile audit contract

- Add the bounded `x86_cpu_profile` module with one atomic
  `pending_stage0b` status, the CPUID selectors and nested-virtualization bits
  requiring a decision, the architectural legacy-XSAVE and Linux KVM XSAVE2
  boundary, the complete plan-named MSR and profile-specific KVM-capability
  inventories, the unresolved clock-decision inventory, and pure fixtures. Do
  not publish a partially approved profile or a caller-asserted compatibility
  result.
- Slice 0b turns these audit obligations into the concrete CPUID allowlist,
  XSAVE/XCRS layout, MSR dispositions, clock policy, profile identity, typed
  host facts, and fail-closed compatibility predicate, then owns native
  approval. Existing KVM topology normalization remains its single owner until
  that concrete profile consumes it.

**Exit:** fixtures prove every audit inventory is bounded, ordered, unique,
and atomically pending Slice 0b, with VMX/SVM exposure explicitly forbidden
and no runtime or public availability claim. Native values and compatibility
remain unavailable until Slice 0b closes them with bare-metal evidence.

#### Stage 1.4: Add the host-info v2 contract

- Add `spore.host-info.v2` with architecture-discriminated facts and the final
  profile field shape. Preserve C v1 on ARM, add the versioned C v2 entry point,
  update the Zig API deliberately, and report the unapproved candidate through
  backend availability rather than a transitional public schema state.
- Add exact JSON, Zig, and C schema/ABI tests, including byte-for-byte C v1 ARM
  compatibility.

**Exit:** the x86 binary reports the exact missing capability or candidate
profile fact, and the v1 ARM host-info ABI remains byte-for-byte compatible.

#### Stage 1.5: Parameterize embedded guest artifacts and CI builds

- Parameterize the comptime-embedded minimal exec initrd and digest pins by
  target architecture so the x86 CLI cross-build never embeds an ARM initrd.
- Cross-compile the CLI and libraries for `x86_64-linux-musl` in ordinary CI,
  retaining the native ARM build and test matrix.

**Exit:** the x86 CLI and libraries cross-build with architecture-correct
embedded artifacts, report why KVM is or is not supported, and all ARM
unit/native tests remain unchanged. Completing Stage 1.5 completes Slice 1.

### Slice 2a: Land the x86 board and fresh run loop on low RAM

- Promote the reviewed Slice 0a board, bzImage, MP, and PIO modules into the
  product path without reimplementing their contracts.
- Write the frozen product board to `docs/spore-format.md` before wiring it into
  the runner.
- Keep the existing contiguous `GuestRam` with a fixed low RAM region of at
  most 2GiB; generate E820 and every boot placement from the frozen board.
- Create in-kernel irqchip/PIT state and route fixed GSIs.
- Implement only the frozen PIO allow/ignore/decode table; reject all other
  PIO and MMIO exits.
- Run all existing virtio-mmio devices and the generation device.
- Run the Stage 1.5 x86 embedded initrd and helpers natively through the
  existing guest-agent protocol.
- Add one agent/vsock execution plus generation and device-enumeration smokes
  through an explicit kernel/initrd. Slice 3a owns the complete product matrix.

**Exit:** the low-level x86 runner executes the existing guest-agent protocol
and device set with no architecture-specific device fork. Capture and
auto-memory remain unavailable.

**Completed 2026-07-19.** The mechanically extracted fresh-only runner uses
the approved `sporevm-x86_64-v0` CPUID/TSC profile, the frozen board-v0 device
slots, and the shared console, block, net, vsock, RNG, generation, and
guest-agent implementations. A ReleaseSafe smoke with SHA-256
`9b25841524e6d3fde77a3d447d53345ff20134ea841b5888b75faace7cebce68`
ran on the dedicated x86 bare-metal development host against the approved
managed kernel
`07a9b6d8a9efd2b7c5e886d1c010e67245fa132c8b48cf567f200099b55abee8`
and embedded initrd
`e81e3d071f25adb384838e45b4353c549c5b55db949a40dac124e9eb469d7fc6`.
The guest-agent command completed with distinct stdout and stderr, observed
generation 1 and acknowledged its interrupt, and enumerated all eight frozen
virtio-mmio slots before the host reported `probe_complete`. A second run with
an unconnectable probe returned the typed `ExecProbeTimeout` in 642 ms and
joined its worker without process residue.

Because the runner extraction changed the default-Debug harness, the complete
Stage 0a.3 lifecycle matrix was rerun with harness SHA-256
`058bfdc128e83e0df5ba284ae3c8331096b7f3423f2080f74b06a05b16a45b77`,
the managed kernel above, and lifecycle initrd
`ee05bff31ee93e51ea570f68e18e321a1c4eab0ac606b64065edd7ac30c40eb5`.
Every case reported CPUs `0-1`, eight transports, and the exact device IDs per
slot. Idle reached ready and timed out with rc 124; reboot returned rc 0 as
`guest_reset` from one-byte PIO port `0x64`, value `0xfe`; native poweroff
reached `System halted` and timed out with rc 124 without a terminal outcome;
and doorbell poweroff returned rc 0 as `guest_off` from MMIO GPA `0xd0001020`,
value `0x46464f50`. No case emitted a failure marker or raw
`KVM_EXIT_SHUTDOWN`, no process remained, and the retained evidence checksum
file has SHA-256
`a3e71872052382a19fdb07f813d8516f55e842359fcfdae3c14acead069ffe0b`.
All proofs used 512 MiB fixed RAM. Product routing, capture, resume, and
automatic memory remain disabled for the next slices.

### Slice 3a: Integrate managed artifacts and fresh product execution

- Add managed x86 kernel/initrd resolution and verification. Publish exactly
  the candidate kernel approved in Stages 0a.2 and 0a.3 or rerun those stages.
- Route `spore run`, create, and monitor startup through x86 KVM while keeping
  savable/capture options rejected until v4 machine state lands.
- Promote the small x86 fresh-run loop behind the existing backend boundary and
  reuse shared leaf helpers. Do not add capture, quiescence, lazy RAM, dirty
  sealing, or snapshot orchestration to this loop; Slice 4 extracts those
  concrete shared mechanics before x86 capture uses them.
- Run single-vCPU agent, environment, stdin/TTY, vsock, block, RNG, generation,
  and complete device-topology smokes against the managed artifacts.
- Keep x86 memory fixed at the experimental low-RAM limit. Do not publish an
  x86 support statement while this temporary limit is observable. Omitted or
  automatic `--memory` fails closed on x86 with an explicit experimental-limit
  error until Slice 6; it must not silently clamp.

**Exit:** a managed development binary runs the existing guest-agent and frozen
device contracts on the x86 host through the product lifecycle contracts.

### Slice 3b: Add OCI, rootfs, networking, and image commit

- Accept `linux/amd64` OCI config, layouts, imports, local refs, and rootfs
  caches while rejecting native execution mismatches.
- Route `run --image` and `run --commit` through the x86 product path.
- Run writable-rootfs, image-commit, network config, DNS, HTTP, deny, bind, and
  forward smokes on the x86 host.

**Exit:** fresh amd64 image runs, rootfs mutation, image commit, and the network
policy graph pass natively without enabling capture.

### Slice 3c: Add native build and libspore fresh-run support

- Make `spore build` native-platform aware and run its conformance suite on x86.
- Route libspore fresh-run APIs through the shared x86 product path while
  keeping capture APIs fail-closed until Slice 4.
- Cross-check generated OCI architecture, build cache identities, and
  `TARGETARCH=amd64` behavior.

**Exit:** Dockerfile builds and standalone development libspore fresh-run
smokes pass on x86. This slice gates release, but does not block Slice 4.

### Slice 4: Add manifest v4 and fixed-memory single-vCPU capture

Stage 4a requires Slice 0b's approved profile and Slice 2a's frozen board;
Stage 4b additionally requires Slice 3a's fresh product path, and Stage 4c
requires Slice 3b. Fixed-memory capture keeps one low-RAM `GuestRam` region and
one KVM slot; segmented high RAM is a Slice 6 change.

#### Stage 4a: Specify and parse the concrete x86 v4 format

- Specify v4 and the x86 normalized state inventory in
  `docs/spore-format.md` and `docs/state-portability.md`.
- Add the strict x86-only v4 parser/writer, validate the complete bounded
  memory-region schema, replace nullable `bundle.LoadedManifest` modes with a
  tagged v2/v3/v4 ownership union, and preserve byte-compatible v2/v3 ARM
  readers and writers. The execution capability check, not the parser,
  temporarily requires one low-RAM region.
- Add parser, version-dispatch, state-count, allocation-bound, and region fuzz
  coverage in the same commit.

**Exit:** offline inspect and round-trip tests accept valid v2/v3/v4 manifests
and reject malformed or cross-architecture state without executing KVM.

#### Stage 4b: Capture and restore normalized single-vCPU machine state

- Extract and reuse the concrete quiescence, transport capture, disk
  publication, wake, lazy-RAM, dirty-sealing, and monitor mechanics required by
  both KVM paths before enabling x86 capture; do not force a generic run-loop
  trait or duplicate capture orchestration.
- Capture/apply the approved CPU profile, VM clock, irqchip/PIT, one vCPU,
  transport, generation, fixed RAM, rootfs, and disk state.
- Prove the complete restore order and fail closed for every missing or
  mismatched required state class before any vCPU can run.
- Prove process-boundary capture and eager restore on the same host.

**Exit:** a single-vCPU fixed-memory x86 spore restores eagerly with monotonic
guest time and no pre-restore vCPU execution.

#### Stage 4c: Wire product save, restore, and bundle lifecycle

- Add `run --save`, `run --from`, inspect, pack, unpack, push, and pull with
  network, annotation, and session state preserved.
- Exercise bundle transfer and restore through the public CLI and libspore
  capture APIs.

**Exit:** a captured x86 spore survives product bundle round trips on the same
compatible host class.

#### Stage 4d: Add local, lazy, dirty, and offline-fork paths

- Add proof-backed local RAM restore, lazy KVM RAM, dirty tracking,
  capture-on-signal, and offline single-child fork while retaining the one
  low-memory region.
- Validate generation changes, VMM-originated dirty observations, and eager,
  local, and lazy restore equivalence.

**Exit:** all fixed-memory single-vCPU restore modes and offline fork pass on
the same compatible host class.

### Slice 5: Add multi-vCPU and named lifecycle parity

#### Stage 5a: Add multi-vCPU capture and restore

- Add normalized per-vCPU topology and state under the concrete x86 v4 schema.
- Extend and validate the existing Slice 0a MP CPU-discovery module for product
  topology; do not build a second table implementation.
- Pause and resume every vCPU around snapshots with no completed-exit loss.
- Capture/apply LAPIC state per vCPU plus shared IOAPIC/PIC/PIT/clock state.

**Exit:** multi-vCPU run, save, and restore preserve CPU, interrupt, device, and
clock state across a process boundary.

#### Stage 5b: Add fork and non-destructive-save parity

- Support multi-vCPU offline fork, non-destructive save, and disk-backed live
  fork while keeping the source runnable beside restored and forked children.
- Prove generation, disk authority, and pause-barrier behavior with concurrent
  source and child smokes.

**Exit:** the multi-vCPU source and each restored or forked child run
concurrently with independent generation and disk state.

#### Stage 5c: Add named lifecycle parity

- Support named create, exec, copy, save, remove, and restore through the
  already-proven multi-vCPU state and fork layers.
- Run the current named lifecycle smoke contracts on x86.

**Exit:** x86 passes the same fixed-memory multi-vCPU lifecycle graph as ARM64,
including a still-running source beside restored/forked children.

### Slice 6: Restore segmented high RAM, automatic memory, and performance parity

#### Stage 6a.1: Introduce the bounded region translator

- Replace device-facing `GuestRam` with the bounded region table and adapt ARM
  through one implicit region without changing v2/v3 manifests.
- Retain one contiguous host VMA and linear backing. Reject accesses crossing
  regions or holes, and add overflow, boundary, and fuzz coverage in the same
  commit.
- Keep every backend on its existing single region/slot while tests establish
  that the new translator preserves current `GuestRam` behavior.

**Exit:** device and virtqueue tests pass through the bounded translator, the
aarch64 adapter preserves v2/v3 behavior, and malformed regions cannot escape
the backing allocation.

#### Stage 6a.2: Add x86 high-RAM slots and dirty-offset mapping

- Carve low/high x86 GPA KVM slots from the one linear backing VMA and generate
  E820 from the same validated region table.
- Translate per-slot dirty logs back to backing offsets and verify the board
  holes, slot boundaries, and 2MiB chunk selection on the native host.

**Exit:** a fixed high-RAM x86 guest boots and dirty observations from every
slot select the correct linear-backing chunks.

#### Stage 6a.3: Extend lazy and local backing across regions

- Prove userfaultfd, lazy/local-backed restore, chunking, and dirty sealing
  across every slot while retaining one userfaultfd registration for the
  linear VMA.
- Run unchanged ARM64 KVM and HVF memory, virtio, lazy/local-backed, and
  snapshot regressions before x86 capture uses multiple regions.
- Prove a single-region v4 spore produced by Slice 4 still restores after the
  segmented-memory refactor.

**Exit:** low/high x86 RAM and the aarch64 single-region adapter share one
security boundary and one linear-backing contract without ARM regressions.

#### Stage 6b: Restore automatic-memory parity

- Define the x86 transient virtio-mem placement above fixed high RAM without
  colliding with board holes or device MMIO.
- Keep auto-memory state unsavable and normalize capture to fixed RAM exactly as
  the current product contract requires.
- Run 16GiB sparse fresh-run and lifecycle accounting smokes.

**Exit:** omitted `--memory` exposes the documented sparse 16GiB x86 contract,
capture normalizes it to fixed RAM, and saved state contains no transient
virtio-mem state.

#### Stage 6c: Establish performance evidence

- Validate dirty logging, VMM-originated dirty observations, lazy faults, and
  O(dirty) disk snapshots across segmented regions.
- Establish architecture-separated startup, restore, fork, save-pause, disk,
  network, and build benchmark baselines.

**Exit:** architecture-specific benchmark history detects regressions without
comparing x86 numbers to ARM. Completing Stage 6c is the first point at which
the ordinary x86 product memory contract may be advertised.

### Slice 7: Package, release, and make support durable

- Before freezing archive names, build a fixture release and run the supported
  mise/ubi selectors against every candidate CLI and libspore asset set.
- Add native x86 Buildkite test, smoke, packaged-smoke, and benchmark steps on
  the ops-provided queue.
- Build and publish the x86 CLI and the libspore asset names proven by the
  mise/ubi selection fixture.
- Extend checksum, download, pinned-release, installer, and release scripts,
  including `release-publish` dependencies and the ARM-only download list in
  `scripts/ci/buildkite-release.sh`.
- Run standalone C and Go libspore smokes from the packaged archive.
- Update README, durable format/state/memory/lifecycle/rootfs/libspore docs,
  `SECURITY.md`, release notes, and support statements.
- Repeat the CPU/clock profile and packaged correctness proof on a replacement
  or second machine of the same declared vendor/host class.
- Require exact-head ARM64 KVM, ARM64 HVF, and x86-64 KVM proof before the first
  release claiming x86 support.

**Exit:** a tagged release installs and passes packaged native smokes on all
three supported host/backend combinations.

## Validation Matrix

| Capability | Unit/cross build | x86 KVM native | ARM64 KVM | ARM64 HVF |
| --- | --- | --- | --- | --- |
| Build and unit tests | required | required | required | required |
| Managed fresh run and exec | n/a | required | regression | regression |
| OCI/rootfs and image commit | parser tests | required | regression | regression |
| Network policy and forwarding | parser tests | required | regression | regression |
| Single-vCPU save/restore/fork | schema/state tests | required | regression | regression |
| Multi-vCPU lifecycle | topology/state tests | required | regression | regression |
| Lazy/local-backed RAM restore | planner tests | required | regression | regression |
| 16GiB auto memory | policy tests | required | regression | regression |
| `spore build` conformance | self-tests | required | regression | not duplicated if unchanged |
| Packaged CLI/libspore | archive tests | required | required | required |
| Benchmarks | parser tests | separate baseline | separate baseline | separate baseline |

Native evidence must use the exact candidate artifact or commit. Cross-compile
success is never a substitute for `/dev/kvm` execution. First-release evidence
is retained as Buildkite artifacts with host-info, KVM capability output,
kernel/initrd identities, archive checksums, and smoke logs.

## Security and Failure Rules

- Treat x86 guest register values, MMIO/PIO exits, virtqueue addresses, memory
  region descriptors, and manifest state as attacker-influenced.
- Keep all guest-memory access behind the checked `GuestRam` boundary; after
  Slice 6, that boundary is the segmented `GuestMemory` translator.
- Reject region crossings unless the API explicitly supports bounded scatter/
  gather; never assume host contiguity from guest contiguity.
- Validate every KVM-reported variable-length count before allocation or ioctl
  replay, including CPUID, MSR, and XSAVE sizes.
- Never persist raw KVM structures or backend-private CPU/irqchip blobs.
- Hide CPU features whose state is not completely captured and restored.
- Reject unknown manifest versions, platforms, profiles, register names,
  required MSRs, XSAVE features, or interrupt-controller fields.
- Add fuzz coverage in the same slice as every new untrusted parser or exit
  decoder and update `SECURITY.md` with the actual boundary.
- Keep ReleaseSafe as the shipping optimization mode.
- Preserve the monitor jail and ensure the x86 Linux seccomp audit architecture
  is exercised by a native packaged smoke.
- Fail capture when a device queue or x86 machine-state component is not
  quiescent; do not publish a partial spore.
- Fail restore before running any vCPU when RAM, rootfs/disk authority,
  platform profile, state inventory, or interrupt/clock setup is invalid.

## Risks and Mitigations

### CPU and time portability is the largest correctness risk

Host-derived CPUID or TSC behavior can produce spores that restore only by
accident. Define and instantiate a named profile before enabling capture, hide
unsupported state, require stable clock controls, and start with one compatible
host class.

### Sparse memory reaches every virtio device

Changing guest-memory translation is security-sensitive and can regress ARM.
Land it with the aarch64 single-region adapter, focused region-boundary tests,
fuzzing, and unchanged ARM smoke evidence before x86 snapshots depend on it.

### Manifest version growth can spread conditional logic

The current code already falls back between v2 and v3 in several callers.
Extend the existing private bundle view first, keep architecture-specific
machine operations explicit, and extract a broader common view only when two
callers demonstrate the same field set.

### The mature ARM KVM loop contains shared product behavior

A from-scratch x86 loop can miss subtle exit ordering, network wake, disk
quiescence, dirty tracking, and monitor semantics. Treat the current KVM/HVF
smokes as contracts, extract shared behavior only with tests, and require parity
slice by slice.

### Managed artifacts can make a working harness look like product support

Keep explicit-kernel bring-up separate from managed artifact resolution. Do not
enable x86 in support statements until kernel config verification, embedded
initrd, OCI amd64, packaged archive, and native smokes all pass together.

### Release naming can break existing installers

The architecture-less libspore Linux asset predates multi-architecture Linux.
Add selection tests and a documented compatibility alias before publishing new
asset names.

### Dev-host success may hide host-class assumptions

Record capabilities and CPU profile from the first host, then validate on a
second x86 machine or replaced instance before widening support beyond the
original host class. Benchmark and correctness history stay keyed by profile.

## Key Learnings From Pressure-Testing

- First boot does not require segmented RAM. A low-RAM `GuestRam` harness
  can also support fixed-memory capture, so the shared memory security boundary
  changes only when high and automatic RAM require it.
- Board and PIO evidence is meaningful only against a pinned kernel digest and
  verified config; publishing a different managed kernel invalidates the gate.
- A small x86-specific loop is the safer fresh-run path because the mature KVM
  loop interleaves ARM boot, VGIC, PSCI, and snapshot policy. Capture lands only
  after its concrete quiescence and lifecycle mechanics are shared rather than
  duplicated.
- Slice 1 shares literal KVM UAPI and layouts before behavior. Architecture
  modules retain open flags, IRQ encoding, MMIO decoding, run completion, and
  exit policy; x86 build and host inspection remain fail closed at product
  launch until the reviewed runner lands.
- PIO, reboot, and poweroff behavior cannot be frozen from documentation. The
  native trace is the source of truth, followed by a finite fail-closed table.
- Nested KVM is useful for board bring-up but not clock portability evidence;
  the bare-metal TSC gate blocks capture rather than fresh-run work.
- x86 snapshot correctness depends on named KVM clock/MSR/LAPIC/XSAVE state,
  not raw ioctl blobs or a vague same-host promise.
- KVM's advertised ordinary MSR list is a readable inventory, not a
  context-free restore batch. Writable profile MSRs must be classified
  explicitly and proven under the final irqchip-owning vCPU context.
- Release asset names stay undecided until real supported mise/ubi selectors
  prove that CLI and libspore archives remain unambiguous.

## Documentation Updates

- `docs/spore-format.md`: x86 board, v4 manifest, memory regions, normalized
  x86 machine and interrupt/clock state.
- `docs/state-portability.md`: architecture matrix, x86 same-host-class scope,
  CPU/TSC gates, and explicit cross-ISA rejection.
- `docs/memory.md`: segmented fixed RAM and transient x86 virtio-mem layout.
- `docs/lifecycle.md`: x86 capture/fork/named lifecycle support and gates.
- `docs/rootfs.md`: native OCI-platform selection and cache identity.
- `docs/libspore.md`: x86 build/install targets and host-info changes.
- `SECURITY.md`: x86 manifest, guest-memory, KVM exit, CPUID/MSR, and restore
  boundaries with fuzz coverage.
- `docs/release-notes.md`: user-visible support and any archive-name migration.
- README: supported host matrix and installation examples only after packaged
  validation succeeds.

## Done When

- The fixed x86 board and CPU profiles are documented and versioned.
- `spore host-info` proves required KVM capabilities on the supported x86 host
  class and explains failures precisely.
- Fresh `linux/amd64` run, image, commit, network, and build paths pass natively.
- Manifest v4 is strict, bounded, fuzzed, documented, and preserves v2/v3 ARM
  compatibility.
- Fixed-memory single- and multi-vCPU x86 spores capture, restore, bundle,
  offline fork, live disk fork, and run concurrently with their source.
- Named lifecycle and non-destructive save pass on x86.
- Default 16GiB auto memory behaves sparsely and remains outside saved state.
- The native x86 smoke and benchmark graph runs on the ops-provided host.
- Packaged x86 CLI and libspore archives pass standalone smokes.
- Exact-head ARM64 KVM and HVF regression gates remain green.
- Durable docs, security inventory, release notes, checksums, and installer
  selection describe the shipped contract accurately.
