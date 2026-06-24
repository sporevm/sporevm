//! Public libspore Zig module.
//!
//! This is the product-facing interface for embedders. It exposes product
//! operations and result contracts; backend, device, storage, daemon, and CLI
//! modules stay behind the in-repo implementation module.

const api = @import("api.zig");
pub const version = "1.1.0";

pub const Backend = api.Backend;
pub const CacheRoot = api.CacheRoot;
pub const CacheState = api.CacheState;
pub const ChildRange = api.ChildRange;
pub const ChunkMaterializationSummary = api.ChunkMaterializationSummary;
pub const ChunkpackSummary = api.ChunkpackSummary;
pub const Context = api.Context;
pub const Disk = api.Disk;
pub const EventSink = api.EventSink;
pub const ExitEvent = api.ExitEvent;
pub const FailureEvent = api.FailureEvent;
pub const ClassifiedFailure = api.ClassifiedFailure;
pub const FailureCode = api.FailureCode;
pub const FailureScope = api.FailureScope;
pub const BundleChildrenSummary = api.BundleChildrenSummary;
pub const BundleChildSummary = api.BundleChildSummary;
pub const BundleSelectionSummary = api.BundleSelectionSummary;
pub const CaptureTrigger = api.CaptureTrigger;
pub const DigestRef = api.DigestRef;
pub const ForkOptions = api.ForkOptions;
pub const ForkResult = api.ForkResult;
pub const HostInfo = api.HostInfo;
pub const InspectBundleOptions = api.InspectBundleOptions;
pub const InspectBundleResult = api.InspectBundleResult;
pub const MemoryConfig = api.MemoryConfig;
pub const NetworkMode = api.NetworkMode;
pub const NetworkPolicy = api.NetworkPolicy;
pub const OutputEvent = api.OutputEvent;
pub const PackOptions = api.PackOptions;
pub const PackResult = api.PackResult;
pub const PathFact = api.PathFact;
pub const PullOptions = api.PullOptions;
pub const PullResult = api.PullResult;
pub const PushOptions = api.PushOptions;
pub const PushResult = api.PushResult;
pub const ReadyEvent = api.ReadyEvent;
pub const RemoteBundleCache = api.RemoteBundleCache;
pub const ResumeOptions = api.ResumeOptions;
pub const ResumeResult = api.ResumeResult;
pub const Rootfs = api.Rootfs;
pub const RootfsBundleSummary = api.RootfsBundleSummary;
pub const RootfsBundlePolicy = api.RootfsBundlePolicy;
pub const RootfsMaterializationSummary = api.RootfsMaterializationSummary;
pub const RunEvent = api.RunEvent;
pub const RunOptions = api.RunOptions;
pub const RunResult = api.RunResult;
pub const SporeInspectResult = api.SporeInspectResult;
pub const SporePlatformSummary = api.SporePlatformSummary;
pub const StartEvent = api.StartEvent;
pub const Timings = api.Timings;
pub const UnpackOptions = api.UnpackOptions;
pub const UnpackResult = api.UnpackResult;

pub const classifyFailure = api.classifyFailure;
pub const deinitForkResult = api.deinitForkResult;
pub const deinitHostInfo = api.deinitHostInfo;
pub const deinitInspectBundleResult = api.deinitInspectBundleResult;
pub const deinitPackResult = api.deinitPackResult;
pub const deinitPullResult = api.deinitPullResult;
pub const deinitPushResult = api.deinitPushResult;
pub const deinitSporeInspectResult = api.deinitSporeInspectResult;
pub const deinitUnpackResult = api.deinitUnpackResult;
pub const fork = api.fork;
pub const hostInfo = api.hostInfo;
pub const inspectBundle = api.inspectBundle;
pub const inspectSpore = api.inspectSpore;
pub const pack = api.pack;
pub const pull = api.pull;
pub const push = api.push;
pub const resumeSpore = api.resumeSpore;
pub const run = api.run;
pub const unpack = api.unpack;

test {
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    testing.refAllDecls(api);
}
