# Saved Spore Ownership Safety

Issue #544 closes with three explicit ownership classes: ordinary disk-backed
saves are `machine-local-pinned`, unpacked or cloned artifacts are
`portable-self-contained`, and offline fork children are `batch-relative`.

The machine-local contract uses one cache-side hard-link anchor per new pin.
The anchor plus saved-spore reference are the only valid links, so renames keep
working while ordinary copies, hard-link duplicates, and ambiguous references
fail closed. Cache GC can identify raw-deletion leaks from a one-link anchor.
Pending publication metadata also lets GC distinguish a crashed two-link stage
from a committed artifact. Ordinary publication failures preserve the staged
manifest, and diskless batches use the same hidden-stage rename transaction.
Legacy v1 pins stay readable and transportable but refuse destructive removal
because their copy count cannot be established safely.

The implementation slice is complete when inspect, save, removal, clone,
pin-listing, and cache-GC output expose this contract; pack remains the transport
encoding behind clone; and adversarial tests cover copy forms, duplicate links,
raw deletion, removal ordering, and batch-relative children. Resource aliases
and broader lifecycle capability vocabulary remain in issues #546 and #553.
