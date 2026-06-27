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

const minABIVersion uint32 = 7

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
	var info HostInfo
	if err := json.Unmarshal(goBytes(out), &info); err != nil {
		return HostInfo{}, fmt.Errorf("decode host info: %w", err)
	}
	return info, nil
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
	var inspected InspectBundleResult
	if err := json.Unmarshal(goBytes(out), &inspected); err != nil {
		return InspectBundleResult{}, fmt.Errorf("decode inspect bundle: %w", err)
	}
	return inspected, nil
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
	var pulled PullResult
	if err := json.Unmarshal(goBytes(out), &pulled); err != nil {
		return PullResult{}, fmt.Errorf("decode pull result: %w", err)
	}
	return pulled, nil
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

func cString(s string) (C.SporeString, func()) {
	if s == "" {
		return C.SporeString{}, func() {}
	}
	ptr := C.CString(s)
	return C.SporeString{ptr: ptr, len: C.size_t(len(s))}, func() {
		C.free(unsafe.Pointer(ptr))
	}
}

func cCacheRoot(root CacheRoot) (C.SporeCacheRoot, func()) {
	path, freePath := cString(root.Path)
	return C.SporeCacheRoot{
		kind: C.uint32_t(root.Kind),
		path: path,
	}, freePath
}
