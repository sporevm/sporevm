// Package spore wraps the libspore C ABI.
package spore

/*
#cgo pkg-config: libspore
#include <stdlib.h>
#include <spore.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"unsafe"
)

const minABIVersion uint32 = 8

var ErrClosed = errors.New("spore client closed")

// Result is a libspore C ABI result code.
type Result int

const (
	Success      Result = C.SPORE_SUCCESS
	OutOfMemory  Result = C.SPORE_OUT_OF_MEMORY
	InvalidValue Result = C.SPORE_INVALID_VALUE
	Error        Result = C.SPORE_ERROR
)

// CallError reports a failed libspore C ABI call.
type CallError struct {
	Code    Result
	Message string
}

func (e *CallError) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("libspore error: %d", e.Code)
	}
	return fmt.Sprintf("libspore error: %s", e.Message)
}

// BuildInfo contains libspore version and C ABI version facts.
type BuildInfo struct {
	Version    string
	ABIVersion uint32
}

// Client owns a libspore process context.
type Client struct {
	ctx C.SporeContext
}

// New creates a libspore client and verifies the loaded C ABI is new enough.
func New() (*Client, error) {
	var ctx C.SporeContext
	if result := Result(C.spore_context_new(&ctx)); result != Success {
		return nil, &CallError{Code: result}
	}
	c := &Client{ctx: ctx}
	info, err := Build()
	if err != nil {
		c.Close()
		return nil, err
	}
	if info.ABIVersion < minABIVersion {
		c.Close()
		return nil, fmt.Errorf("libspore C ABI version %d is older than required %d", info.ABIVersion, minABIVersion)
	}
	return c, nil
}

// Close releases the libspore process context.
func (c *Client) Close() {
	if c == nil || c.ctx == nil {
		return
	}
	C.spore_context_free(c.ctx)
	c.ctx = nil
}

// Build returns libspore build information.
func Build() (BuildInfo, error) {
	var version C.SporeString
	if result := Result(C.spore_build_info(C.SPORE_BUILD_INFO_VERSION_STRING, unsafe.Pointer(&version))); result != Success {
		return BuildInfo{}, &CallError{Code: result}
	}
	var abi C.uint32_t
	if result := Result(C.spore_build_info(C.SPORE_BUILD_INFO_ABI_VERSION, unsafe.Pointer(&abi))); result != Success {
		return BuildInfo{}, &CallError{Code: result}
	}
	return BuildInfo{
		Version:    goString(version),
		ABIVersion: uint32(abi),
	}, nil
}

// SetEnv sets a context-local environment variable used by libspore operations.
func (c *Client) SetEnv(ctx context.Context, name, value string) error {
	if err := c.ready(ctx); err != nil {
		return err
	}
	cName, freeName := cString(name)
	defer freeName()
	cValue, freeValue := cString(value)
	defer freeValue()
	if result := Result(C.spore_context_set_env(c.ctx, cName, cValue)); result != Success {
		return c.callError(result)
	}
	return nil
}

// HostInfo returns host capability and cache-root facts.
func (c *Client) HostInfo(ctx context.Context) (HostInfo, error) {
	if err := c.ready(ctx); err != nil {
		return HostInfo{}, err
	}
	var out C.SporeOwnedString
	if result := Result(C.spore_host_info_json(c.ctx, &out)); result != Success {
		return HostInfo{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[HostInfo](goBytes(out), "host info")
}

// InspectBundle returns metadata for a local bundle reference.
func (c *Client) InspectBundle(ctx context.Context, options InspectBundleOptions) (InspectBundleResult, error) {
	if err := c.ready(ctx); err != nil {
		return InspectBundleResult{}, err
	}
	source, freeSource := cString(options.Source)
	defer freeSource()
	childID, freeChildID := cString(options.ChildID)
	defer freeChildID()

	var opts C.SporeInspectBundleOptions
	C.spore_inspect_bundle_options_init(&opts)
	opts.source = source
	opts.child_id = childID
	if options.ChildRange != nil {
		opts.has_child_range = 1
		opts.child_range_start = C.uint32_t(options.ChildRange.Start)
		opts.child_range_end = C.uint32_t(options.ChildRange.End)
	}

	var out C.SporeOwnedString
	if result := Result(C.spore_inspect_bundle_json(c.ctx, &opts, &out)); result != Success {
		return InspectBundleResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[InspectBundleResult](goBytes(out), "inspect bundle")
}

// Pull materializes a bundle into a local spore directory.
func (c *Client) Pull(ctx context.Context, options PullOptions) (PullResult, error) {
	if err := c.ready(ctx); err != nil {
		return PullResult{}, err
	}
	source, freeSource := cString(options.Source)
	defer freeSource()
	outDir, freeOutDir := cString(options.OutDir)
	defer freeOutDir()
	childID, freeChildID := cString(options.ChildID)
	defer freeChildID()
	awsRegion, freeAWSRegion := cString(options.AWSRegion)
	defer freeAWSRegion()
	awsExecutable, freeAWSExecutable := cString(options.AWSExecutable)
	defer freeAWSExecutable()
	rootfsCache, freeRootfsCache := cCacheRoot(options.RootfsCache)
	defer freeRootfsCache()
	bundleCache, freeBundleCache := cCacheRoot(options.BundleCache)
	defer freeBundleCache()

	var opts C.SporePullOptions
	C.spore_pull_options_init(&opts)
	opts.source = source
	opts.out_dir = outDir
	opts.rootfs_cache = rootfsCache
	opts.bundle_cache = bundleCache
	opts.child_id = childID
	if options.AllowMetadataOnlyRootfs {
		opts.allow_metadata_only_rootfs = 1
	}
	opts.aws_region = awsRegion
	opts.aws_executable = awsExecutable

	var out C.SporeOwnedString
	if result := Result(C.spore_pull_json(c.ctx, &opts, &out)); result != Success {
		return PullResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[PullResult](goBytes(out), "pull result")
}

// CreateNamed starts a long-lived named VM.
func (c *Client) CreateNamed(ctx context.Context, options CreateNamedOptions) (NamedLifecycleResult, error) {
	if err := c.ready(ctx); err != nil {
		return NamedLifecycleResult{}, err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	backend, freeBackend := cString(options.Backend)
	defer freeBackend()
	kernelPath, freeKernelPath := cString(options.KernelPath)
	defer freeKernelPath()
	initrdPath, freeInitrdPath := cString(options.InitrdPath)
	defer freeInitrdPath()
	rootfsPath, freeRootfsPath := cString(options.RootfsPath)
	defer freeRootfsPath()
	imageRef, freeImageRef := cString(options.ImageRef)
	defer freeImageRef()
	sporeExecutable, freeSporeExecutable := cString(options.SporeExecutable)
	defer freeSporeExecutable()
	consoleLogPath, freeConsoleLogPath := cString(options.ConsoleLogPath)
	defer freeConsoleLogPath()
	annotations, freeAnnotations := cAnnotations(options.Annotations)
	defer freeAnnotations()

	var opts C.SporeCreateNamedOptions
	C.spore_create_named_options_init(&opts)
	opts.name = name
	opts.backend = backend
	opts.kernel_path = kernelPath
	opts.initrd_path = initrdPath
	opts.rootfs_path = rootfsPath
	opts.image_ref = imageRef
	opts.spore_executable = sporeExecutable
	opts.memory_bytes = C.uint64_t(options.MemoryBytes)
	if options.VCPUs != 0 {
		opts.vcpus = C.uint32_t(options.VCPUs)
	}
	if options.GuestPort != 0 {
		opts.guest_port = C.uint32_t(options.GuestPort)
	}
	if options.TimeoutMs != 0 {
		opts.timeout_ms = C.uint64_t(options.TimeoutMs)
	}
	opts.console_log_path = consoleLogPath
	if len(annotations) != 0 {
		opts.annotations = &annotations[0]
		opts.annotation_count = C.size_t(len(annotations))
	}

	var out C.SporeOwnedString
	if result := Result(C.spore_create_named_json(c.ctx, &opts, &out)); result != Success {
		return NamedLifecycleResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[NamedLifecycleResult](goBytes(out), "named lifecycle result")
}

// ExecNamed runs an exact argv in a named VM and returns captured stdout,
// stderr, exit code, and network decision events.
func (c *Client) ExecNamed(ctx context.Context, options ExecNamedOptions) (ExecNamedResult, error) {
	if err := c.ready(ctx); err != nil {
		return ExecNamedResult{}, err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	argv, freeArgv := cStringList(options.Argv)
	defer freeArgv()

	var opts C.SporeExecNamedOptions
	C.spore_exec_named_options_init(&opts)
	opts.name = name
	if len(argv) != 0 {
		opts.argv = &argv[0]
		opts.argc = C.size_t(len(argv))
	}

	var out C.SporeOwnedString
	if result := Result(C.spore_exec_named_json(c.ctx, &opts, &out)); result != Success {
		return ExecNamedResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[ExecNamedResult](goBytes(out), "exec named result")
}

// ResumeNamed starts a named VM from a spore checkpoint directory.
func (c *Client) ResumeNamed(ctx context.Context, options ResumeNamedOptions) (NamedLifecycleResult, error) {
	if err := c.ready(ctx); err != nil {
		return NamedLifecycleResult{}, err
	}
	sporeDir, freeSporeDir := cString(options.SporeDir)
	defer freeSporeDir()
	name, freeName := cString(options.Name)
	defer freeName()
	sporeExecutable, freeSporeExecutable := cString(options.SporeExecutable)
	defer freeSporeExecutable()

	var opts C.SporeResumeNamedOptions
	C.spore_resume_named_options_init(&opts)
	opts.spore_dir = sporeDir
	opts.name = name
	opts.spore_executable = sporeExecutable

	var out C.SporeOwnedString
	if result := Result(C.spore_resume_named_json(c.ctx, &opts, &out)); result != Success {
		return NamedLifecycleResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[NamedLifecycleResult](goBytes(out), "named lifecycle result")
}

// SnapshotNamed snapshots a named VM. The current libspore mode always keeps
// the VM running, matching Continue: true.
func (c *Client) SnapshotNamed(ctx context.Context, options SnapshotNamedOptions) (NamedLifecycleResult, error) {
	if err := c.ready(ctx); err != nil {
		return NamedLifecycleResult{}, err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	outDir, freeOutDir := cString(options.OutDir)
	defer freeOutDir()
	annotations, freeAnnotations := cAnnotations(options.Annotations)
	defer freeAnnotations()

	var opts C.SporeSnapshotNamedOptions
	C.spore_snapshot_named_options_init(&opts)
	opts.name = name
	opts.out_dir = outDir
	if options.Continue {
		opts.continue_after = 1
	}
	if len(annotations) != 0 {
		opts.annotations = &annotations[0]
		opts.annotation_count = C.size_t(len(annotations))
	}

	var out C.SporeOwnedString
	if result := Result(C.spore_snapshot_named_json(c.ctx, &opts, &out)); result != Success {
		return NamedLifecycleResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[NamedLifecycleResult](goBytes(out), "named lifecycle result")
}

// RemoveNamed destroys a named VM and removes its local lifecycle state.
func (c *Client) RemoveNamed(ctx context.Context, options RemoveNamedOptions) (NamedLifecycleResult, error) {
	if err := c.ready(ctx); err != nil {
		return NamedLifecycleResult{}, err
	}
	name, freeName := cString(options.Name)
	defer freeName()

	var opts C.SporeRemoveNamedOptions
	C.spore_remove_named_options_init(&opts)
	opts.name = name

	var out C.SporeOwnedString
	if result := Result(C.spore_remove_named_json(c.ctx, &opts, &out)); result != Success {
		return NamedLifecycleResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[NamedLifecycleResult](goBytes(out), "named lifecycle result")
}

// ListNamed returns the current local named VM registry.
func (c *Client) ListNamed(ctx context.Context) ([]NamedListEntry, error) {
	if err := c.ready(ctx); err != nil {
		return nil, err
	}

	var out C.SporeOwnedString
	if result := Result(C.spore_list_named_json(c.ctx, &out)); result != Success {
		return nil, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[[]NamedListEntry](goBytes(out), "named list")
}

func (c *Client) ready(ctx context.Context) error {
	if c == nil || c.ctx == nil {
		return ErrClosed
	}
	if ctx == nil {
		return nil
	}
	return ctx.Err()
}

func (c *Client) callError(code Result) error {
	return &CallError{Code: code, Message: goString(C.spore_context_last_error(c.ctx))}
}

func goString(s C.SporeString) string {
	if s.ptr == nil || s.len == 0 {
		return ""
	}
	return C.GoStringN(s.ptr, C.int(s.len))
}

func goBytes(s C.SporeOwnedString) []byte {
	if s.ptr == nil || s.len == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(s.ptr), C.int(s.len))
}

func decodeJSON[T any](data []byte, description string) (T, error) {
	var value T
	if err := json.Unmarshal(data, &value); err != nil {
		return value, fmt.Errorf("decode %s: %w", description, err)
	}
	return value, nil
}

func (r *ExecNamedResult) UnmarshalJSON(data []byte) error {
	var raw struct {
		ExitCode           uint8           `json:"exit_code"`
		Stdout             json.RawMessage `json:"stdout"`
		Stderr             json.RawMessage `json:"stderr"`
		NetworkEventsJSONL json.RawMessage `json:"network_events_jsonl"`
		StdoutTruncated    bool            `json:"stdout_truncated"`
		StderrTruncated    bool            `json:"stderr_truncated"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	stdout, err := decodeOutputField(raw.Stdout, "stdout")
	if err != nil {
		return err
	}
	stderr, err := decodeOutputField(raw.Stderr, "stderr")
	if err != nil {
		return err
	}
	networkEvents, err := decodeOutputField(raw.NetworkEventsJSONL, "network_events_jsonl")
	if err != nil {
		return err
	}
	*r = ExecNamedResult{
		ExitCode:           raw.ExitCode,
		Stdout:             stdout,
		Stderr:             stderr,
		NetworkEventsJSONL: networkEvents,
		StdoutTruncated:    raw.StdoutTruncated,
		StderrTruncated:    raw.StderrTruncated,
	}
	return nil
}

func decodeOutputField(data json.RawMessage, field string) (string, error) {
	if len(data) == 0 || string(data) == "null" {
		return "", nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		return text, nil
	}
	var bytes []byte
	if err := json.Unmarshal(data, &bytes); err != nil {
		return "", fmt.Errorf("decode exec named %s: %w", field, err)
	}
	return string(bytes), nil
}

func cString(s string) (C.SporeString, func()) {
	if s == "" {
		return C.SporeString{}, func() {}
	}
	ptr := C.CString(s)
	return C.SporeString{ptr: ptr, len: C.size_t(len(s))}, func() {
		C.free(unsafe.Pointer(ptr))
	}
}

func cStringList(values []string) ([]C.SporeString, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.SporeString{})))
	if ptr == nil {
		panic("spore: out of memory")
	}
	strings := unsafe.Slice((*C.SporeString)(ptr), len(values))
	frees := make([]func(), 0, len(values))
	for i, value := range values {
		cValue, freeValue := cString(value)
		strings[i] = cValue
		frees = append(frees, freeValue)
	}
	return strings, func() {
		for _, free := range frees {
			free()
		}
		C.free(ptr)
	}
}

func cCacheRoot(root CacheRoot) (C.SporeCacheRoot, func()) {
	path, freePath := cString(root.Path)
	return C.SporeCacheRoot{
		kind: C.uint32_t(root.Kind),
		path: path,
	}, freePath
}

func cAnnotations(values map[string]string) ([]C.SporeAnnotation, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.SporeAnnotation{})))
	if ptr == nil {
		panic("spore: out of memory")
	}
	annotations := unsafe.Slice((*C.SporeAnnotation)(ptr), len(values))
	frees := make([]func(), 0, len(values)*2)
	i := 0
	for key, value := range values {
		cKey, freeKey := cString(key)
		cValue, freeValue := cString(value)
		annotations[i] = C.SporeAnnotation{key: cKey, value: cValue}
		frees = append(frees, freeKey, freeValue)
		i++
	}
	return annotations, func() {
		for _, free := range frees {
			free()
		}
		C.free(ptr)
	}
}
