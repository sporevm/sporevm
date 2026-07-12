const std = @import("std");

const dockerfile = @import("dockerfile.zig");
const variable_expansion = @import("variables.zig");

pub const Base = union(enum) {
    scratch,
    stage: usize,
    external: []const u8,
};

pub const CopySource = union(enum) {
    context,
    stage: usize,
    external: []const u8,
};

pub const PlannedCopy = struct {
    instruction_index: usize,
    source: CopySource,
};

pub const Stage = struct {
    source: *const dockerfile.Stage,
    base: Base,
    platform: ?[]const u8,
    copies: []const PlannedCopy,
    dependencies: []const usize,
    reachable: bool = false,
};

pub const Plan = struct {
    stages: []Stage,
    target_index: usize,
    order: []const usize,
};

pub const Options = struct {
    target: ?[]const u8 = null,
    variables: []const Variable = &.{},
};

pub const Variable = variable_expansion.Variable;

const ReferenceKind = enum { from, copy };

/// Resolve the immutable stage graph before any base fetch or guest boot.
/// Docker permits numeric references to earlier stages; names are matched
/// case-insensitively, as they are by BuildKit.
pub fn create(
    allocator: std.mem.Allocator,
    document: *const dockerfile.Document,
    options: Options,
    diagnostic: *dockerfile.Diagnostic,
) !Plan {
    if (document.stages.len == 0) return fail(diagnostic, 1, "Dockerfile requires at least one FROM instruction");

    for (document.stages, 0..) |stage, index| {
        if (stage.name) |name| {
            if (findNamedStage(document.stages[0..index], name) != null) {
                return fail(diagnostic, stage.from.line, "duplicate stage name");
            }
        }
    }

    const target_index = if (options.target) |target|
        findStageReference(document.stages, document.stages.len, target) orelse
            return fail(diagnostic, 0, try std.fmt.allocPrint(allocator, "unknown build target: {s}", .{target}))
    else
        document.stages.len - 1;

    const stages = try allocator.alloc(Stage, document.stages.len);
    for (document.stages, 0..) |*source_stage, stage_index| {
        var dependencies = std.array_list.Managed(usize).init(allocator);
        const source_name = try expand(allocator, source_stage.from.value.from.source, options.variables, source_stage.from.line, diagnostic);
        const platform = if (source_stage.from.value.from.platform) |raw| try expand(allocator, raw, options.variables, source_stage.from.line, diagnostic) else null;
        const base: Base = if (std.ascii.eqlIgnoreCase(source_name, "scratch"))
            .scratch
        else if (try resolveStageReference(document, stage_index, source_name, .from, source_stage.from.line, diagnostic)) |dependency| blk: {
            try appendDependency(&dependencies, dependency);
            break :blk .{ .stage = dependency };
        } else .{ .external = source_name };

        var copies = std.array_list.Managed(PlannedCopy).init(allocator);
        for (source_stage.instructions, 0..) |instruction, instruction_index| switch (instruction.value) {
            .copy => |copy| {
                const copy_source: CopySource = if (copy.from) |raw_reference| source: {
                    const reference = try expand(allocator, raw_reference, options.variables, instruction.line, diagnostic);
                    if (try resolveStageReference(document, stage_index, reference, .copy, instruction.line, diagnostic)) |dependency| {
                        try appendDependency(&dependencies, dependency);
                        break :source .{ .stage = dependency };
                    }
                    break :source .{ .external = reference };
                } else .context;
                try copies.append(.{ .instruction_index = instruction_index, .source = copy_source });
            },
            else => {},
        };
        stages[stage_index] = .{
            .source = source_stage,
            .base = base,
            .platform = platform,
            .copies = try copies.toOwnedSlice(),
            .dependencies = try dependencies.toOwnedSlice(),
        };
    }

    markReachable(stages, target_index);
    var order = std.array_list.Managed(usize).init(allocator);
    for (stages, 0..) |stage, index| if (stage.reachable) try order.append(index);
    return .{ .stages = stages, .target_index = target_index, .order = try order.toOwnedSlice() };
}

fn expand(
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: []const Variable,
    line: usize,
    diagnostic: *dockerfile.Diagnostic,
) ![]const u8 {
    return variable_expansion.expand(allocator, input, variables, .empty) catch |err| switch (err) {
        error.BadVariableSubstitution => return fail(diagnostic, line, "unsupported variable expansion"),
        else => |other| return other,
    };
}

fn resolveStageReference(
    document: *const dockerfile.Document,
    before: usize,
    reference: []const u8,
    kind: ReferenceKind,
    line: usize,
    diagnostic: *dockerfile.Diagnostic,
) !?usize {
    if (parseStageIndex(reference)) |index| {
        if (kind == .from) return null;
        if (index < before) return index;
        if (index < document.stages.len) return fail(diagnostic, line, "stage reference must name an earlier stage");
        return fail(diagnostic, line, "invalid stage index");
    }
    if (findNamedStage(document.stages[0..before], reference)) |index| return index;
    if (findNamedStage(document.stages[before..], reference) != null) {
        return fail(diagnostic, line, "stage reference must name an earlier stage");
    }
    return null;
}

fn findStageReference(stages: []const dockerfile.Stage, limit: usize, reference: []const u8) ?usize {
    if (parseStageIndex(reference)) |index| if (index < limit) return index;
    if (findNamedStage(stages[0..limit], reference)) |index| return index;
    return null;
}

fn findNamedStage(stages: []const dockerfile.Stage, name: []const u8) ?usize {
    for (stages, 0..) |stage, index| {
        if (stage.name) |candidate| if (std.ascii.eqlIgnoreCase(candidate, name)) return index;
    }
    return null;
}

fn parseStageIndex(reference: []const u8) ?usize {
    if (reference.len == 0) return null;
    for (reference) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(usize, reference, 10) catch null;
}

fn appendDependency(dependencies: *std.array_list.Managed(usize), dependency: usize) !void {
    for (dependencies.items) |existing| if (existing == dependency) return;
    try dependencies.append(dependency);
}

fn markReachable(stages: []Stage, index: usize) void {
    if (stages[index].reachable) return;
    stages[index].reachable = true;
    for (stages[index].dependencies) |dependency| markReachable(stages, dependency);
}

fn fail(diagnostic: *dockerfile.Diagnostic, line: usize, message: []const u8) error{DockerfilePlanFailed} {
    diagnostic.* = .{ .line = line, .message = message };
    return error.DockerfilePlanFailed;
}

test "planner selects the target closure in topological source order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator,
        \\FROM toolchain AS tools
        \\RUN make tool
        \\FROM base AS build
        \\COPY --from=tools /tool /bin/tool
        \\RUN make app
        \\FROM scratch AS runtime
        \\COPY --from=build /app /app
        \\FROM unrelated AS debug
        \\RUN debug
        \\
    , &diagnostic);
    const plan = try create(allocator, &document, .{ .target = "runtime" }, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), plan.target_index);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, plan.order);
    try std.testing.expect(!plan.stages[3].reachable);
    try std.testing.expectEqual(@as(usize, 1), plan.stages[1].copies.len);
    try std.testing.expectEqual(@as(usize, 0), plan.stages[1].copies[0].source.stage);
}

test "planner rejects forward references and duplicate aliases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const forward = try dockerfile.parse(allocator, "FROM base AS first\nCOPY --from=later /a /a\nFROM base AS later\n", &diagnostic);
    try std.testing.expectError(error.DockerfilePlanFailed, create(allocator, &forward, .{}, &diagnostic));
    try std.testing.expectEqualStrings("stage reference must name an earlier stage", diagnostic.message);

    const numeric_forward = try dockerfile.parse(allocator, "FROM base AS zero\nFROM base AS one\nCOPY --from=2 /a /a\nFROM base AS two\n", &diagnostic);
    try std.testing.expectError(error.DockerfilePlanFailed, create(allocator, &numeric_forward, .{}, &diagnostic));
    try std.testing.expectEqualStrings("stage reference must name an earlier stage", diagnostic.message);

    const numeric_missing = try dockerfile.parse(allocator, "FROM base\nCOPY --from=999 /a /a\n", &diagnostic);
    try std.testing.expectError(error.DockerfilePlanFailed, create(allocator, &numeric_missing, .{}, &diagnostic));
    try std.testing.expectEqualStrings("invalid stage index", diagnostic.message);

    const duplicate = try dockerfile.parse(allocator, "FROM base AS Build\nFROM base AS build\n", &diagnostic);
    try std.testing.expectError(error.DockerfilePlanFailed, create(allocator, &duplicate, .{}, &diagnostic));
    try std.testing.expectEqualStrings("duplicate stage name", diagnostic.message);
}

test "planner treats numeric FROM as an external image and supports numeric COPY stages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator, "FROM base AS zero\nFROM 0 AS numeric-image\nCOPY --from=0 /a /a\n", &diagnostic);
    const plan = try create(allocator, &document, .{}, &diagnostic);
    try std.testing.expectEqualStrings("0", plan.stages[1].base.external);
    try std.testing.expectEqual(@as(usize, 0), plan.stages[1].copies[0].source.stage);
}

test "planner names an unknown target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator, "FROM scratch AS runtime\n", &diagnostic);
    try std.testing.expectError(error.DockerfilePlanFailed, create(allocator, &document, .{ .target = "missing" }, &diagnostic));
    try std.testing.expectEqualStrings("unknown build target: missing", diagnostic.message);

    const numeric = try create(allocator, &document, .{ .target = "0" }, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), numeric.target_index);
}

test "planner treats external image copies as immutable inputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator, "FROM base\nCOPY --from=assets /logo /logo\n", &diagnostic);
    const plan = try create(allocator, &document, .{}, &diagnostic);
    try std.testing.expectEqualStrings("assets", plan.stages[0].copies[0].source.external);
}

test "planner expands global and automatic arguments before graph resolution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator,
        \\ARG BASE=ignored
        \\FROM --platform=$BUILDPLATFORM base AS build
        \\FROM ${BASE} AS inherited
        \\
    , &diagnostic);
    const plan = try create(allocator, &document, .{ .variables = &.{
        .{ .key = "BUILDPLATFORM", .value = "linux/arm64" },
        .{ .key = "BASE", .value = "build" },
    } }, &diagnostic);
    try std.testing.expectEqualStrings("linux/arm64", plan.stages[0].platform.?);
    try std.testing.expectEqual(@as(usize, 0), plan.stages[1].base.stage);
}
