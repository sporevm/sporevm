# Research Notes

## QEMU Cross-Accelerator Restore Experiment

**Status:** not run; superseded as the first de-risking step by direct HVF
state capture/restore work in SporeVM. The experiment remains a useful
cross-check once an aarch64 KVM host is available, but it no longer blocks the
foundation slices already landed.

### Question

Can an aarch64 `virt` machine snapshot taken under KVM be restored under
Hypervisor.framework (HVF), and what state fails to translate? This is the
cheapest possible test of SporeVM's riskiest claim — cross-hypervisor
machine-state restore — and it requires no SporeVM code.

### Why QEMU is a valid proxy

QEMU normalizes vCPU state into its own machine-independent vmstate format on
save, regardless of accelerator. QEMU upstream has an in-flight patch series
("hvf: save/restore Apple GIC state", using macOS 15's `hv_gic_get_state` /
`hv_gic_set_state`) that completes the HVF side. If QEMU's migration stream
restores KVM→HVF, the architectural-state normalization approach is sound. If
it fails, the failure modes tell us exactly which state needs explicit
handling in the spore format.

### Method

1. Build matching QEMU revisions (with the HVF GIC state patches) on an
   aarch64 Linux KVM host (`cleanroom-ops` fleet) and an Apple Silicon Mac on
   macOS 15+.
2. Boot an identical `-M virt` config on both sides: same QEMU machine type
   version, virtio-mmio devices only, GICv3, no ITS, identical CPU model
   restricted to a common feature set.
3. On Linux/KVM: run a workload with observable state (in-progress
   computation, established timer cadence), `migrate` to file, copy to the
   Mac.
4. On macOS/HVF: `-incoming` restore, then verify: workload completes
   correctly, clock behaves after offset fixup, interrupts still deliver
   (disk and network I/O work), no kernel warnings.
5. Repeat in the reverse direction (HVF→KVM).

### Record

For each direction: pass/fail, QEMU revision and command lines, dmesg output,
and a list of state that needed configuration to avoid (e.g. in-kernel vs
emulated devices) or failed to translate. Conclude with a keep/adjust decision
for the machine-state normalization design in the foundation plan.

### Results

The QEMU proxy experiment was not run before SporeVM's direct HVF
suspend/resume implementation landed. That implementation nevertheless
answered the highest-risk state-normalization questions on the macOS side:

- Apple's `hv_gic_get_state` / `hv_gic_set_state` blob is sufficient to
  round-trip distributor and redistributor state on HVF, but it does not
  include per-vCPU GIC CPU-interface (`ICC_*`) registers. Those registers must
  be saved via `hv_gic_get_icc_reg` and restored with `hv_gic_set_icc_reg`; if
  they are omitted, the resumed guest can hang with interrupts masked.
- The virtual timer cannot be restored as a raw host timestamp. The spore
  records guest virtual counter state and re-anchors `CNTV_CVAL_EL0` on
  restore so guest time continues from the snapshot point.
- Runtime GIC MMIO access through `hv_gic_{get,set}_*_reg` is not a substitute
  for normal device emulation; those APIs use architectural offsets but return
  `HV_DENIED` for this path. The board must describe the redistributor frame
  returned after setting `MPIDR_EL1`.
- The v0 spore format therefore keeps one documented backend-opaque exception:
  `machine.gic_state_b64` is currently an HVF GIC blob. Cross-hypervisor
  restore still needs either a normalized GICv3 representation or a proven
  blob translation path.

Decision: keep the architectural machine-state normalization design. Adjust
the cross-hypervisor slice to treat GICv3 CPU-interface state and virtual
timer anchoring as first-class normalized fields, and use the QEMU matrix only
as an additional validation tool once the KVM side exists.
