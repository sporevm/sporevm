package spore

// HostInfo is the decoded spore.host-info.v1 contract.
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
