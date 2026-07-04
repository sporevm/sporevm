//! Shared machine-output contracts for the `spore` CLI and future bindings.

const std = @import("std");
const Io = std.Io;

pub const error_schema = "spore.error.v1";
pub const error_schema_version: u32 = 1;
pub const run_events_schema = "spore.run-events.v1";
pub const run_events_schema_version: u32 = 1;

pub const Mode = enum {
    human,
    json,
};

pub const Scope = enum {
    usage,
    host,
    platform,
    object,
    cache,
    manifest,
    guest,
    runtime,

    pub fn text(self: Scope) []const u8 {
        return @tagName(self);
    }
};

pub const ErrorCode = enum {
    usage_invalid_argument,
    usage_missing_argument,
    host_unsupported,
    host_unavailable,
    object_not_found,
    object_invalid,
    cache_unavailable,
    cache_integrity_failed,
    runtime_start_failed,
    runtime_execution_failed,

    pub fn text(self: ErrorCode) []const u8 {
        return switch (self) {
            .usage_invalid_argument => "usage.invalid_argument",
            .usage_missing_argument => "usage.missing_argument",
            .host_unsupported => "host.unsupported",
            .host_unavailable => "host.unavailable",
            .object_not_found => "object.not_found",
            .object_invalid => "object.invalid",
            .cache_unavailable => "cache.unavailable",
            .cache_integrity_failed => "cache.integrity_failed",
            .runtime_start_failed => "runtime.start_failed",
            .runtime_execution_failed => "runtime.execution_failed",
        };
    }

    pub fn scope(self: ErrorCode) Scope {
        return switch (self) {
            .usage_invalid_argument, .usage_missing_argument => .usage,
            .host_unsupported, .host_unavailable => .host,
            .object_not_found, .object_invalid => .object,
            .cache_unavailable, .cache_integrity_failed => .cache,
            .runtime_start_failed, .runtime_execution_failed => .runtime,
        };
    }

    pub fn retryable(self: ErrorCode) bool {
        return switch (self) {
            .host_unavailable,
            .cache_unavailable,
            .runtime_start_failed,
            => true,
            else => false,
        };
    }

    pub fn exitCode(self: ErrorCode) u8 {
        return switch (self) {
            .usage_invalid_argument, .usage_missing_argument => 2,
            .host_unsupported, .host_unavailable => 69,
            .object_not_found,
            .object_invalid,
            .cache_integrity_failed,
            => 22,
            .cache_unavailable => 73,
            .runtime_start_failed, .runtime_execution_failed => 1,
        };
    }

    pub fn defaultMessage(self: ErrorCode) []const u8 {
        return switch (self) {
            .usage_invalid_argument => "An argument was present but invalid.",
            .usage_missing_argument => "A required argument was absent.",
            .host_unsupported => "The host lacks a required capability.",
            .host_unavailable => "A required host service or device is temporarily unavailable.",
            .object_not_found => "A required object reference could not be resolved.",
            .object_invalid => "A resolved object is malformed or fails validation.",
            .cache_unavailable => "A required cache root cannot be reached or prepared.",
            .cache_integrity_failed => "Cached bytes do not match the expected digest.",
            .runtime_start_failed => "Runtime setup failed before guest execution completed.",
            .runtime_execution_failed => "Guest execution reached a SporeVM-managed failure state.",
        };
    }
};

pub const CliError = struct {
    code: ErrorCode,
    message: []const u8,
    source: []const u8,
    retryable: bool,
    scope: Scope,
    exit_code: u8,

    pub fn init(code: ErrorCode, message: []const u8, source: []const u8) CliError {
        return .{
            .code = code,
            .message = message,
            .source = source,
            .retryable = code.retryable(),
            .scope = code.scope(),
            .exit_code = code.exitCode(),
        };
    }

    pub fn envelope(self: CliError) ErrorEnvelope {
        return .{
            .@"error" = .{
                .code = self.code.text(),
                .message = self.message,
                .retryable = self.retryable,
                .scope = self.scope.text(),
                .exit_code = self.exit_code,
                .source = self.source,
            },
        };
    }
};

pub const ErrorEnvelope = struct {
    schema: []const u8 = error_schema,
    schema_version: u32 = error_schema_version,
    @"error": ErrorBody,
};

pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
    retryable: bool,
    scope: []const u8,
    exit_code: u8,
    source: []const u8,
};

pub fn usageInvalidArgument(message: []const u8, source: []const u8) CliError {
    return CliError.init(.usage_invalid_argument, message, source);
}

pub fn usageMissingArgument(message: []const u8, source: []const u8) CliError {
    return CliError.init(.usage_missing_argument, message, source);
}

pub fn forkUnsupportedVcpuBody(allocator: std.mem.Allocator, vcpu_count: u32) []const u8 {
    return std.fmt.allocPrint(
        allocator,
        "source has {d} vCPUs but uses a fork topology or GIC state this backend cannot mint safely yet. Capture the fork source with a supported backend and manifest v1 GIC state.",
        .{vcpu_count},
    ) catch "source uses a fork topology or GIC state this backend cannot mint safely yet. Capture the fork source with a supported backend and manifest v1 GIC state.";
}

pub fn forkUnsupportedVcpuMessage(allocator: std.mem.Allocator, vcpu_count: u32) []const u8 {
    const body = forkUnsupportedVcpuBody(allocator, vcpu_count);
    return std.fmt.allocPrint(allocator, "spore fork: {s}", .{body}) catch body;
}

pub fn fromZigError(err: anyerror) CliError {
    return switch (err) {
        error.InvalidRootfsInput,
        error.UnsupportedVcpuCount,
        error.BadManagedKernelRepository,
        error.BadManagedKernelVersion,
        error.BadManagedKernelAsset,
        error.BadInjectedFileId,
        error.BadInjectedFilePath,
        error.BadInjectedFile,
        error.TooManyInjectedFiles,
        error.DuplicateInjectedFile,
        error.InjectedFileTooLarge,
        error.InjectedFileCaptureUnsupported,
        error.InjectedFileResumeUnsupported,
        error.InjectedFileMonitorUnsupported,
        => CliError.init(.usage_invalid_argument, ErrorCode.usage_invalid_argument.defaultMessage(), @errorName(err)),
        error.FileNotFound => CliError.init(.object_not_found, ErrorCode.object_not_found.defaultMessage(), @errorName(err)),
        error.AccessDenied,
        error.PermissionDenied,
        error.BadPathName,
        error.NotDir,
        error.IsDir,
        error.InvalidManifest,
        error.BadManifest,
        error.PlatformMismatch,
        error.MissingRootfsArtifact,
        error.UnsupportedRootfsDeviceCount,
        error.ManagedKernelConfigMissing,
        error.ManagedKernelHTTPStatus,
        error.ManagedKernelBodyTooLarge,
        => CliError.init(.object_invalid, ErrorCode.object_invalid.defaultMessage(), @errorName(err)),
        error.UnsupportedHost,
        error.UnsupportedBackend,
        => CliError.init(.host_unsupported, ErrorCode.host_unsupported.defaultMessage(), @errorName(err)),
        error.RootfsCacheUnavailable,
        error.MissingHome,
        => CliError.init(.cache_unavailable, ErrorCode.cache_unavailable.defaultMessage(), @errorName(err)),
        error.BadChunk,
        error.BadBundleDigest,
        error.BadRootfsDigest,
        error.BadManagedKernelChecksum,
        error.ManagedKernelChecksumMismatch,
        => CliError.init(.cache_integrity_failed, ErrorCode.cache_integrity_failed.defaultMessage(), @errorName(err)),
        else => CliError.init(.runtime_execution_failed, ErrorCode.runtime_execution_failed.defaultMessage(), @errorName(err)),
    };
}

pub fn writeJson(allocator: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    try writer.writeAll(json);
    try writer.writeByte('\n');
}

pub fn writeError(allocator: std.mem.Allocator, writer: *Io.Writer, err: CliError) !void {
    try writeJson(allocator, writer, err.envelope());
}

test "stable error code table matches the plan" {
    try std.testing.expectEqualStrings("usage.invalid_argument", ErrorCode.usage_invalid_argument.text());
    try std.testing.expectEqualStrings("usage.missing_argument", ErrorCode.usage_missing_argument.text());
    try std.testing.expectEqualStrings("host.unsupported", ErrorCode.host_unsupported.text());
    try std.testing.expectEqualStrings("host.unavailable", ErrorCode.host_unavailable.text());
    try std.testing.expectEqualStrings("object.not_found", ErrorCode.object_not_found.text());
    try std.testing.expectEqualStrings("object.invalid", ErrorCode.object_invalid.text());
    try std.testing.expectEqualStrings("cache.unavailable", ErrorCode.cache_unavailable.text());
    try std.testing.expectEqualStrings("cache.integrity_failed", ErrorCode.cache_integrity_failed.text());
    try std.testing.expectEqualStrings("runtime.start_failed", ErrorCode.runtime_start_failed.text());
    try std.testing.expectEqualStrings("runtime.execution_failed", ErrorCode.runtime_execution_failed.text());
}

test "setup errors classify for API callers" {
    try std.testing.expectEqual(ErrorCode.usage_invalid_argument, fromZigError(error.InvalidRootfsInput).code);
    try std.testing.expectEqual(ErrorCode.usage_invalid_argument, fromZigError(error.InjectedFileCaptureUnsupported).code);
    try std.testing.expectEqual(ErrorCode.usage_invalid_argument, fromZigError(error.InjectedFileTooLarge).code);
    try std.testing.expectEqual(ErrorCode.object_invalid, fromZigError(error.MissingRootfsArtifact).code);
    try std.testing.expectEqual(ErrorCode.cache_integrity_failed, fromZigError(error.ManagedKernelChecksumMismatch).code);
}

test "error envelope uses shared schema" {
    const err = usageInvalidArgument("unknown argument", "Test");
    const envelope = err.envelope();
    try std.testing.expectEqualStrings(error_schema, envelope.schema);
    try std.testing.expectEqual(error_schema_version, envelope.schema_version);
    try std.testing.expectEqualStrings("usage.invalid_argument", envelope.@"error".code);
    try std.testing.expectEqualStrings("usage", envelope.@"error".scope);
    try std.testing.expectEqual(@as(u8, 2), envelope.@"error".exit_code);
}
