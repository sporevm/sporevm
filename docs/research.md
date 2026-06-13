# Research Notes

## QEMU Cross-Accelerator Restore Experiment

**Status:** pending. Slice 0 of [plans/foundation.md](plans/foundation.md).

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

Not yet run.
