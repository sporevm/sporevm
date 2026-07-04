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
	"os"
	"path/filepath"
	"unsafe"
)

const minABIVersion uint32 = 13
const reexecContractVersion uint32 = C.SPORE_REEXEC_CONTRACT_VERSION
const reexecRoleEnv = "SPORE_REEXEC_ROLE"
const reexecContractEnv = "SPORE_REEXEC_CONTRACT"

var ErrClosed = errors.New("spore client closed")
var ErrStreamClosed = errors.New("spore exec stream closed")

func init() {
	if os.Getenv(reexecRoleEnv) == "" {
		return
	}
	exitCode, err := reexecMain(os.Args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "spore: reexec failed: %v\n", err)
		os.Exit(2)
	}
	os.Exit(exitCode)
}

func reexecMain(args []string) (int, error) {
	if len(args) == 0 {
		return 1, errors.New("missing argv")
	}
	argv, freeArgv := cArgv(args)
	defer freeArgv()

	var exitCode C.int
	if result := Result(C.spore_reexec_main(C.int(len(args)), argv, &exitCode)); result != Success {
		return 1, &CallError{Code: result}
	}
	return int(exitCode), nil
}

func cArgv(args []string) (**C.char, func()) {
	ptr := C.malloc(C.size_t(len(args)) * C.size_t(unsafe.Sizeof((*C.char)(nil))))
	if ptr == nil {
		panic("spore: out of memory")
	}
	argv := unsafe.Slice((**C.char)(ptr), len(args))
	for i, arg := range args {
		argv[i] = C.CString(arg)
	}
	return (**C.char)(ptr), func() {
		for _, arg := range argv {
			C.free(unsafe.Pointer(arg))
		}
		C.free(ptr)
	}
}

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

// ExecNamedStream owns a streaming named exec session.
type ExecNamedStream struct {
	client *Client
	stream C.SporeExecNamedStream
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

// NetworkCapabilities returns libspore's enforceable network capability facts.
func (c *Client) NetworkCapabilities(ctx context.Context) (NetworkCapabilities, error) {
	if err := c.ready(ctx); err != nil {
		return NetworkCapabilities{}, err
	}
	var out C.SporeOwnedString
	if result := Result(C.spore_network_capabilities_json(c.ctx, &out)); result != Success {
		return NetworkCapabilities{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[NetworkCapabilities](goBytes(out), "network capabilities")
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

// InspectSpore returns metadata and annotations for a local spore artifact.
func (c *Client) InspectSpore(ctx context.Context, options InspectSporeOptions) (SporeInspectResult, error) {
	if err := c.ready(ctx); err != nil {
		return SporeInspectResult{}, err
	}
	sporeDir, freeSporeDir := cString(options.SporeDir)
	defer freeSporeDir()

	var opts C.SporeInspectSporeOptions
	C.spore_inspect_spore_options_init(&opts)
	opts.spore_dir = sporeDir

	var out C.SporeOwnedString
	if result := Result(C.spore_inspect_spore_json(c.ctx, &opts, &out)); result != Success {
		return SporeInspectResult{}, c.callError(result)
	}
	defer C.spore_free_string(c.ctx, out)
	return decodeJSON[SporeInspectResult](goBytes(out), "inspect spore")
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
	sporeExecutable, freeSporeExecutable, err := cNamedSporeExecutable(options.SporeExecutable)
	if err != nil {
		return NamedLifecycleResult{}, err
	}
	defer freeSporeExecutable()
	consoleLogPath, freeConsoleLogPath := cString(options.ConsoleLogPath)
	defer freeConsoleLogPath()
	allowCIDRs, freeAllowCIDRs := cStringList(options.AllowCIDRs)
	defer freeAllowCIDRs()
	allowHosts, freeAllowHosts := cStringList(options.AllowHosts)
	defer freeAllowHosts()
	networkRules, freeNetworkRules := cNetworkRules(options.NetworkRules)
	defer freeNetworkRules()
	boundServices, freeBoundServices := cBoundUnixServices(options.BoundServices)
	defer freeBoundServices()
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
	if options.NetworkEnabled {
		opts.network_enabled = 1
	}
	if len(allowCIDRs) != 0 {
		opts.allow_cidrs = &allowCIDRs[0]
		opts.allow_cidr_count = C.size_t(len(allowCIDRs))
	}
	if len(allowHosts) != 0 {
		opts.allow_hosts = &allowHosts[0]
		opts.allow_host_count = C.size_t(len(allowHosts))
	}
	if len(networkRules) != 0 {
		opts.network_rules = &networkRules[0]
		opts.network_rule_count = C.size_t(len(networkRules))
	}
	if len(boundServices) != 0 {
		opts.bound_unix_services = &boundServices[0]
		opts.bound_unix_service_count = C.size_t(len(boundServices))
	}
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

// CopyInNamed copies an explicit host file or directory into a named VM.
func (c *Client) CopyInNamed(ctx context.Context, options CopyNamedOptions) error {
	if err := c.ready(ctx); err != nil {
		return err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	hostPath, freeHostPath := cString(options.HostPath)
	defer freeHostPath()
	guestPath, freeGuestPath := cString(options.GuestPath)
	defer freeGuestPath()

	var opts C.SporeCopyNamedOptions
	C.spore_copy_named_options_init(&opts)
	opts.name = name
	opts.host_path = hostPath
	opts.guest_path = guestPath

	if result := Result(C.spore_copy_in_named(c.ctx, &opts)); result != Success {
		return c.callError(result)
	}
	return nil
}

// CopyOutNamed copies an explicit guest file or directory out of a named VM.
func (c *Client) CopyOutNamed(ctx context.Context, options CopyNamedOptions) error {
	if err := c.ready(ctx); err != nil {
		return err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	hostPath, freeHostPath := cString(options.HostPath)
	defer freeHostPath()
	guestPath, freeGuestPath := cString(options.GuestPath)
	defer freeGuestPath()

	var opts C.SporeCopyNamedOptions
	C.spore_copy_named_options_init(&opts)
	opts.name = name
	opts.host_path = hostPath
	opts.guest_path = guestPath

	if result := Result(C.spore_copy_out_named(c.ctx, &opts)); result != Success {
		return c.callError(result)
	}
	return nil
}

// OpenExecNamedStream opens a bidirectional streaming exec session.
func (c *Client) OpenExecNamedStream(ctx context.Context, options ExecNamedStreamOptions) (*ExecNamedStream, error) {
	if err := c.ready(ctx); err != nil {
		return nil, err
	}
	name, freeName := cString(options.Name)
	defer freeName()
	argv, freeArgv := cStringList(options.Argv)
	defer freeArgv()
	terminalName, freeTerminalName := cString(options.TerminalName)
	defer freeTerminalName()

	var opts C.SporeExecNamedStreamOptions
	C.spore_exec_named_stream_options_init(&opts)
	opts.name = name
	if len(argv) != 0 {
		opts.argv = &argv[0]
		opts.argc = C.size_t(len(argv))
	}
	if options.Interactive {
		opts.interactive = 1
	}
	if options.TTY {
		opts.tty = 1
	}
	opts.terminal_name = terminalName
	if options.TerminalRows != 0 {
		opts.terminal_rows = C.uint16_t(options.TerminalRows)
	}
	if options.TerminalCols != 0 {
		opts.terminal_cols = C.uint16_t(options.TerminalCols)
	}

	var stream C.SporeExecNamedStream
	if result := Result(C.spore_exec_named_stream_open(c.ctx, &opts, &stream)); result != Success {
		return nil, c.callError(result)
	}
	return &ExecNamedStream{client: c, stream: stream}, nil
}

// Next returns the next stdout, stderr, terminal, exit, or error event.
func (s *ExecNamedStream) Next(ctx context.Context) (ExecNamedStreamEvent, error) {
	if err := s.ready(ctx); err != nil {
		return ExecNamedStreamEvent{}, err
	}
	var event C.SporeExecNamedStreamEvent
	if result := Result(C.spore_exec_named_stream_next(s.client.ctx, s.stream, &event)); result != Success {
		return ExecNamedStreamEvent{}, s.client.callError(result)
	}
	return ExecNamedStreamEvent{
		Type:     ExecNamedStreamEventType(event._type),
		Bytes:    goBorrowedBytes(event.bytes),
		ExitCode: uint8(event.exit_code),
	}, nil
}

// WriteStdin sends pipe stdin bytes to the guest process.
func (s *ExecNamedStream) WriteStdin(ctx context.Context, data []byte) error {
	if err := s.ready(ctx); err != nil {
		return err
	}
	if result := Result(C.spore_exec_named_stream_write_stdin(s.client.ctx, s.stream, bytesString(data))); result != Success {
		return s.client.callError(result)
	}
	return nil
}

// WriteTerminal sends terminal input bytes to the guest process.
func (s *ExecNamedStream) WriteTerminal(ctx context.Context, data []byte) error {
	if err := s.ready(ctx); err != nil {
		return err
	}
	if result := Result(C.spore_exec_named_stream_write_terminal(s.client.ctx, s.stream, bytesString(data))); result != Success {
		return s.client.callError(result)
	}
	return nil
}

// CloseStdin closes pipe stdin for the guest process.
func (s *ExecNamedStream) CloseStdin(ctx context.Context) error {
	if err := s.ready(ctx); err != nil {
		return err
	}
	if result := Result(C.spore_exec_named_stream_close_stdin(s.client.ctx, s.stream)); result != Success {
		return s.client.callError(result)
	}
	return nil
}

// CloseTerminal closes terminal input for the guest process.
func (s *ExecNamedStream) CloseTerminal(ctx context.Context) error {
	if err := s.ready(ctx); err != nil {
		return err
	}
	if result := Result(C.spore_exec_named_stream_close_terminal(s.client.ctx, s.stream)); result != Success {
		return s.client.callError(result)
	}
	return nil
}

// ResizeTerminal resizes the guest terminal.
func (s *ExecNamedStream) ResizeTerminal(ctx context.Context, rows, cols uint16) error {
	if err := s.ready(ctx); err != nil {
		return err
	}
	if result := Result(C.spore_exec_named_stream_resize_terminal(s.client.ctx, s.stream, C.uint16_t(rows), C.uint16_t(cols))); result != Success {
		return s.client.callError(result)
	}
	return nil
}

// Close frees the stream handle. It does not signal guest stdin.
func (s *ExecNamedStream) Close() {
	if s == nil || s.stream == nil {
		return
	}
	C.spore_exec_named_stream_free(s.client.ctx, s.stream)
	s.stream = nil
}

func (s *ExecNamedStream) ready(ctx context.Context) error {
	if s == nil || s.client == nil || s.stream == nil {
		return ErrStreamClosed
	}
	return s.client.ready(ctx)
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
	sporeExecutable, freeSporeExecutable, err := cNamedSporeExecutable(options.SporeExecutable)
	if err != nil {
		return NamedLifecycleResult{}, err
	}
	defer freeSporeExecutable()
	boundServices, freeBoundServices := cBoundUnixServiceBindings(options.BoundServiceBindings)
	defer freeBoundServices()

	var opts C.SporeResumeNamedOptions
	C.spore_resume_named_options_init(&opts)
	opts.spore_dir = sporeDir
	opts.name = name
	opts.spore_executable = sporeExecutable
	if len(boundServices) != 0 {
		opts.bound_unix_services = &boundServices[0]
		opts.bound_unix_service_count = C.size_t(len(boundServices))
	}

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

func goBorrowedBytes(s C.SporeString) []byte {
	if s.ptr == nil || s.len == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(s.ptr), C.int(s.len))
}

func bytesString(b []byte) C.SporeString {
	if len(b) == 0 {
		return C.SporeString{}
	}
	return C.SporeString{ptr: (*C.char)(unsafe.Pointer(&b[0])), len: C.size_t(len(b))}
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

func cNamedSporeExecutable(explicit string) (C.SporeString, func(), error) {
	if explicit != "" {
		value, free := cString(explicit)
		return value, free, nil
	}
	path, err := currentExecutablePath()
	if err != nil {
		return C.SporeString{}, func() {}, err
	}
	value, free := cString(path)
	return value, free, nil
}

func currentExecutablePath() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("discover current executable: %w", err)
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	return path, nil
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

func cNetworkRules(values []NetworkRule) ([]C.SporeNetworkRule, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.SporeNetworkRule{})))
	if ptr == nil {
		panic("spore: out of memory")
	}
	out := unsafe.Slice((*C.SporeNetworkRule)(ptr), len(values))
	frees := make([]func(), 0, len(values))
	for i, value := range values {
		host, freeHost := cString(value.Host)
		rule := C.SporeNetworkRule{
			host:       host,
			port_count: C.size_t(len(value.Ports)),
		}
		if len(value.Ports) != 0 {
			bytes := C.size_t(len(value.Ports)) * C.size_t(unsafe.Sizeof(C.uint16_t(0)))
			ports := (*C.uint16_t)(C.malloc(bytes))
			if ports == nil {
				panic("spore: out of memory")
			}
			portSlice := unsafe.Slice(ports, len(value.Ports))
			for i, port := range value.Ports {
				portSlice[i] = C.uint16_t(port)
			}
			rule.ports = ports
			frees = append(frees, func() { C.free(unsafe.Pointer(ports)) })
		}
		out[i] = rule
		frees = append(frees, freeHost)
	}
	return out, func() {
		for _, free := range frees {
			free()
		}
		C.free(ptr)
	}
}

func cBoundUnixServices(values []BoundUnixService) ([]C.SporeBoundUnixService, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.SporeBoundUnixService{})))
	if ptr == nil {
		panic("spore: out of memory")
	}
	out := unsafe.Slice((*C.SporeBoundUnixService)(ptr), len(values))
	frees := make([]func(), 0, len(values)*3)
	for i, value := range values {
		name, freeName := cString(value.Name)
		guestHost, freeGuestHost := cString(value.GuestHost)
		unixPath, freeUnixPath := cString(value.UnixPath)
		out[i] = C.SporeBoundUnixService{
			name:       name,
			guest_host: guestHost,
			guest_port: C.uint16_t(value.GuestPort),
			unix_path:  unixPath,
		}
		frees = append(frees, freeName, freeGuestHost, freeUnixPath)
	}
	return out, func() {
		for _, free := range frees {
			free()
		}
		C.free(ptr)
	}
}

func cBoundUnixServiceBindings(values []BoundUnixServiceBinding) ([]C.SporeBoundUnixServiceBinding, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.SporeBoundUnixServiceBinding{})))
	if ptr == nil {
		panic("spore: out of memory")
	}
	out := unsafe.Slice((*C.SporeBoundUnixServiceBinding)(ptr), len(values))
	frees := make([]func(), 0, len(values)*2)
	for i, value := range values {
		name, freeName := cString(value.Name)
		unixPath, freeUnixPath := cString(value.UnixPath)
		out[i] = C.SporeBoundUnixServiceBinding{
			name:      name,
			unix_path: unixPath,
		}
		frees = append(frees, freeName, freeUnixPath)
	}
	return out, func() {
		for _, free := range frees {
			free()
		}
		C.free(ptr)
	}
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
