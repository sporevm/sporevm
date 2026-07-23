# Saved Spore Ownership Safety

Status: complete

Last reviewed: 2026-07-23

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

The completed implementation exposes this contract through inspect, save,
removal, clone, pin-listing, and cache-GC output. Pack remains the transport
encoding behind clone, and adversarial tests cover copy forms, duplicate links,
raw deletion, removal ordering, and batch-relative children. Resource aliases
and broader lifecycle capability vocabulary remain in issues #546 and #553.

## Key Learnings From Pressure-Testing

A link count alone cannot distinguish a committed owner from a reference left
inside a crashed publication stage, so pending publication is explicit and GC
reconciles it under the cache lock. The hard-link contract also requires an
up-front same-filesystem check, while failed ordinary publication preserves the
captured manifest outside loadable authority instead of discarding it.
