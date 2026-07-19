package spore

// HostInfo is the decoded spore.host-info.v2 contract.
type HostInfo struct {
	Schema        string                `json:"schema"`
	SchemaVersion uint32                `json:"schema_version"`
	HostClass     string                `json:"host_class"`
	Platform      PlatformFacts         `json:"platform"`
	Backends      []BackendAvailability `json:"backends"`
	CacheRoots    CacheRoots            `json:"cache_roots"`
}

type PlatformFacts struct {
	OS                     string `json:"os"`
	Arch                   string `json:"arch"`
	CPUProfile             string `json:"cpu_profile"`
	DeviceModelVersion     uint32 `json:"device_model_version"`
	RAMBase                uint64 `json:"ram_base"`
	GICDistBase            uint64 `json:"gic_dist_base"`
	GICRedistBase          uint64 `json:"gic_redist_base"`
	CounterFrequencySource string `json:"counter_frequency_source"`
	CounterFrequencyHz     uint64 `json:"counter_frequency_hz"`
}

type BackendAvailability struct {
	Name      string `json:"name"`
	Supported bool   `json:"supported"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
}

type CacheRoots struct {
	Kernels PathFact `json:"kernels"`
	Rootfs  PathFact `json:"rootfs"`
	Bundles PathFact `json:"bundles"`
	Runtime PathFact `json:"runtime"`
}

type PathFact struct {
	Path     *string `json:"path"`
	Resolved bool    `json:"resolved"`
	Source   string  `json:"source"`
}

// NetworkCapabilities is the decoded libspore network capability contract.
type NetworkCapabilities struct {
	Supported         bool `json:"supported"`
	TCPIPv4           bool `json:"tcp_ipv4"`
	TCPIPv6           bool `json:"tcp_ipv6"`
	UDPDNS            bool `json:"udp_dns"`
	ExactHostPort     bool `json:"exact_host_port"`
	StagePolicyUpdate bool `json:"stage_policy_update"`
	BoundServices     bool `json:"bound_services"`
	DecisionEvents    bool `json:"decision_events"`
}

// InspectBundleOptions selects local bundle metadata to inspect.
type InspectBundleOptions struct {
	Source     string
	ChildID    string
	ChildRange *ChildRange
}

type ChildRange struct {
	Start uint32
	End   uint32
}

// InspectSporeOptions selects a local spore artifact to inspect.
type InspectSporeOptions struct {
	SporeDir string
}

// SporeInspectResult is the decoded local spore inspection result.
type SporeInspectResult struct {
	Version                 uint32               `json:"version"`
	VMStatePresent          bool                 `json:"vm_state_present"`
	StorageMode             string               `json:"storage_mode"`
	Platform                SporePlatformSummary `json:"platform"`
	DeviceCount             uint64               `json:"device_count"`
	MemoryChunkCount        uint64               `json:"memory_chunk_count"`
	PresentMemoryChunkCount uint64               `json:"present_memory_chunk_count"`
	MemoryBackingKind       *string              `json:"memory_backing_kind"`
	MemoryBackingSize       *uint64              `json:"memory_backing_size"`
	GICKind                 string               `json:"gic_kind"`
	Sessions                []Session            `json:"sessions"`
	Network                 *SporeNetworkSummary `json:"network"`
	Annotations             map[string]string    `json:"annotations"`
	AnnotationKeys          []string             `json:"annotation_keys"`
}

type SporeNetworkSummary struct {
	Kind          string                           `json:"kind"`
	Requirements  NetworkRequirements              `json:"requirements"`
	BoundServices []NetworkBoundServiceRequirement `json:"bound_services"`
}

type NetworkRequirements struct {
	TCPIPv4       bool `json:"tcp_ipv4"`
	ExactHostPort bool `json:"exact_host_port"`
	BoundServices bool `json:"bound_services"`
}

type NetworkBoundServiceRequirement struct {
	Name      string `json:"name"`
	GuestHost string `json:"guest_host"`
	GuestPort uint16 `json:"guest_port"`
}

type Session struct {
	ID      string         `json:"id"`
	Kind    string         `json:"kind"`
	Streams SessionStreams `json:"streams"`
}

type SessionStreams struct {
	Stdin    bool `json:"stdin"`
	Stdout   bool `json:"stdout"`
	Stderr   bool `json:"stderr"`
	Terminal bool `json:"terminal"`
}

type SporePlatformSummary struct {
	Arch               string `json:"arch"`
	CPUProfile         string `json:"cpu_profile"`
	DeviceModelVersion uint32 `json:"device_model_version"`
	RAMBase            uint64 `json:"ram_base"`
	RAMSize            uint64 `json:"ram_size"`
	GICDistBase        uint64 `json:"gic_dist_base"`
	GICRedistBase      uint64 `json:"gic_redist_base"`
	CounterFrequencyHz uint64 `json:"counter_frequency_hz"`
}

// CacheRootKind selects how libspore resolves a cache root.
type CacheRootKind uint32

const (
	CacheRootEnv CacheRootKind = iota
	CacheRootNone
	CacheRootPath
)

// CacheRoot selects a SporeVM cache root. The zero value uses environment
// defaults, matching the CLI.
type CacheRoot struct {
	Kind CacheRootKind
	Path string
}

// InspectBundleResult is the decoded spore.bundle.inspect.v1 contract.
type InspectBundleResult struct {
	Schema         string                 `json:"schema"`
	SchemaVersion  uint32                 `json:"schema_version"`
	Source         string                 `json:"source"`
	BundleDir      string                 `json:"bundle_dir"`
	BundleDigest   DigestRef              `json:"bundle_digest"`
	Indexed        bool                   `json:"indexed"`
	ParentManifest string                 `json:"parent_manifest"`
	ChunkpackIndex string                 `json:"chunkpack_index"`
	Chunkpack      ChunkpackSummary       `json:"chunkpack"`
	ChildCount     uint64                 `json:"child_count"`
	Children       []BundleChildSummary   `json:"children"`
	Selection      BundleSelectionSummary `json:"selection"`
	Rootfs         RootfsBundleSummary    `json:"rootfs"`
}

// PullOptions selects a bundle child to materialize into a local spore directory.
type PullOptions struct {
	Source                  string
	OutDir                  string
	RootfsCache             CacheRoot
	BundleCache             CacheRoot
	ChildID                 string
	AllowMetadataOnlyRootfs bool
	AWSRegion               string
	AWSExecutable           string
}

// PullResult is the decoded spore.pull.result.v1 contract.
type PullResult struct {
	Schema          string                       `json:"schema"`
	SchemaVersion   uint32                       `json:"schema_version"`
	Source          string                       `json:"source"`
	BundleDir       string                       `json:"bundle_dir"`
	OutDir          string                       `json:"out_dir"`
	BundleDigest    DigestRef                    `json:"bundle_digest"`
	Materialization ChunkMaterializationSummary  `json:"materialization"`
	Rootfs          RootfsMaterializationSummary `json:"rootfs"`
	Remote          RemoteBundleCache            `json:"remote"`
	Children        BundleChildrenSummary        `json:"children"`
}

type DigestRef struct {
	Algorithm string `json:"algorithm"`
	Hex       string `json:"hex"`
}

type CacheState struct {
	HitCount     uint64 `json:"hit_count"`
	MissCount    uint64 `json:"miss_count"`
	BytesFetched uint64 `json:"bytes_fetched"`
	BytesReused  uint64 `json:"bytes_reused"`
}

type ChunkMaterializationSummary struct {
	ChunkCount             uint64     `json:"chunk_count"`
	MaterializedChunkCount uint64     `json:"materialized_chunk_count"`
	PayloadBytes           uint64     `json:"payload_bytes"`
	LinkedChunkCount       uint64     `json:"linked_chunk_count"`
	CopiedChunkCount       uint64     `json:"copied_chunk_count"`
	Cache                  CacheState `json:"cache"`
}

type RootfsMaterializationSummary struct {
	ArtifactCount uint64     `json:"artifact_count"`
	PayloadBytes  uint64     `json:"payload_bytes"`
	Cache         CacheState `json:"cache"`
}

type RemoteBundleCache struct {
	CacheHit        bool   `json:"cache_hit"`
	OriginBytesRead uint64 `json:"origin_bytes_read"`
	PeerBytesRead   uint64 `json:"peer_bytes_read"`
}

type BundleChildrenSummary struct {
	Count         uint64  `json:"count"`
	SelectedChild *string `json:"selected_child"`
}

type ChunkpackSummary struct {
	ChunkCount   uint64 `json:"chunk_count"`
	PackCount    uint64 `json:"pack_count"`
	PayloadBytes uint64 `json:"payload_bytes"`
}

type BundleChildSummary struct {
	ID       string `json:"id"`
	Manifest string `json:"manifest"`
}

type BundleSelectionSummary struct {
	Kind          string               `json:"kind"`
	SelectedCount uint64               `json:"selected_count"`
	Children      []BundleChildSummary `json:"children"`
}

type RootfsBundleSummary struct {
	ArtifactCount     uint64 `json:"artifact_count"`
	StorageCount      uint64 `json:"storage_count"`
	ExactBytesCount   uint64 `json:"exact_bytes_count"`
	MetadataOnlyCount uint64 `json:"metadata_only_count"`
	ObjectCount       uint64 `json:"object_count"`
	PayloadBytes      uint64 `json:"payload_bytes"`
}

// NetworkRule allows one exact guest egress host and port set.
type NetworkRule struct {
	Host  string
	Ports []uint16
}

// BoundUnixService declares a host Unix socket exposed to the guest.
type BoundUnixService struct {
	Name      string
	GuestHost string
	GuestPort uint16
	UnixPath  string
}

// BoundUnixServiceBinding supplies a fresh host socket path for a
// manifest-declared bound service at restore time.
type BoundUnixServiceBinding struct {
	Name     string
	UnixPath string
}

// CreateNamedOptions starts a long-lived named VM.
type CreateNamedOptions struct {
	Name            string
	Backend         string
	KernelPath      string
	InitrdPath      string
	RootfsPath      string
	ImageRef        string
	SporeExecutable string
	MemoryBytes     uint64
	VCPUs           uint32
	GuestPort       uint32
	TimeoutMs       uint64
	ConsoleLogPath  string
	NetworkEnabled  bool
	AllowCIDRs      []string
	AllowHosts      []string
	NetworkRules    []NetworkRule
	BoundServices   []BoundUnixService
	Annotations     map[string]string
}

// SaveNamedOptions writes a named VM to a spore.
type SaveNamedOptions struct {
	Name        string
	OutDir      string
	Stop        bool
	Annotations map[string]string
}

// ExecNamedOptions runs an exact argv in a named VM.
type ExecNamedOptions struct {
	Name string
	Argv []string
}

// ExecNamedStreamOptions opens a streaming exact argv in a named VM.
type ExecNamedStreamOptions struct {
	Name         string
	Argv         []string
	Interactive  bool
	TTY          bool
	TerminalName string
	TerminalRows uint16
	TerminalCols uint16
}

// ExecNamedStreamEventType identifies a streaming exec event.
type ExecNamedStreamEventType int

const (
	ExecNamedStreamStdout ExecNamedStreamEventType = iota + 1
	ExecNamedStreamStderr
	ExecNamedStreamTerminal
	ExecNamedStreamExit
	ExecNamedStreamError
)

// ExecNamedStreamEvent carries one streaming exec event.
type ExecNamedStreamEvent struct {
	Type     ExecNamedStreamEventType
	Bytes    []byte
	ExitCode uint8
}

// CopyNamedOptions selects one explicit host and guest path for named VM copy.
type CopyNamedOptions struct {
	Name      string
	HostPath  string
	GuestPath string
}

// RestoreNamedOptions starts a named VM from a spore directory.
type RestoreNamedOptions struct {
	SporeDir             string
	Name                 string
	SporeExecutable      string
	BoundServiceBindings []BoundUnixServiceBinding
}

// RemoveNamedOptions destroys a named VM and removes its local lifecycle state.
type RemoveNamedOptions struct {
	Name string
}

// RemoveSavedOptions selects a saved spore whose verified pinned or portable disk authority will be removed.
type RemoveSavedOptions struct {
	SporeDir string
}

// RemovedSavedSpore reports the removed save directory and whether a disk pin was removed.
type RemovedSavedSpore struct {
	Action     string `json:"action"`
	SporeDir   string `json:"spore_dir"`
	PinID      string `json:"pin_id"`
	PinRemoved bool   `json:"pin_removed"`
}

// NamedLifecycleResult is the decoded spore.lifecycle.v1 contract.
type NamedLifecycleResult struct {
	Schema         string                `json:"schema"`
	SchemaVersion  uint32                `json:"schema_version"`
	Action         string                `json:"action"`
	Name           string                `json:"name"`
	State          string                `json:"state"`
	PID            *int64                `json:"pid"`
	ConsoleLogPath *string               `json:"console_log_path"`
	SporeDir       *string               `json:"spore_dir"`
	Timing         *NamedLifecycleTiming `json:"timing"`
}

// NamedLifecycleTiming reports named VM startup phases in milliseconds.
type NamedLifecycleTiming struct {
	PrepareMs       uint64 `json:"prepare_ms"`
	SpawnMonitorMs  uint64 `json:"spawn_monitor_ms"`
	WaitExecReadyMs uint64 `json:"wait_exec_ready_ms"`
	TotalMs         uint64 `json:"total_ms"`
}

// ExecNamedResult is the decoded named exec result contract.
type ExecNamedResult struct {
	ExitCode           uint8  `json:"exit_code"`
	Stdout             string `json:"stdout"`
	Stderr             string `json:"stderr"`
	NetworkEventsJSONL string `json:"network_events_jsonl"`
	StdoutTruncated    bool   `json:"stdout_truncated"`
	StderrTruncated    bool   `json:"stderr_truncated"`
}

// NamedListEntry describes one VM returned by ListNamed.
type NamedListEntry struct {
	Name   string           `json:"name"`
	State  string           `json:"state"`
	PID    *int64           `json:"pid"`
	Memory *NamedListMemory `json:"memory"`
	Stats  NamedListStats   `json:"stats"`
}

type NamedListMemory struct {
	Policy string `json:"policy"`
	Bytes  uint64 `json:"bytes"`
}

type NamedListStats struct {
	ResidentBytes         *uint64 `json:"resident_bytes"`
	BackingLogicalBytes   *uint64 `json:"backing_logical_bytes"`
	BackingAllocatedBytes *uint64 `json:"backing_allocated_bytes"`
	ChunkSize             *uint64 `json:"chunk_size"`
	ChunksTotal           *uint64 `json:"chunks_total"`
	ChunksNonzero         *uint64 `json:"chunks_nonzero"`
	DirtyChunksPending    *uint64 `json:"dirty_chunks_pending"`
}
