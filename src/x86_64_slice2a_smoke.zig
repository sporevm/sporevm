//! Native Slice 2a acceptance smoke for the fresh-only x86 KVM VM.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const run = @import("run.zig");
const assets = @import("run_assets");
const board = @import("x86_64/board.zig");
const vm = @import("x86_64/vm.zig");
const vsock = @import("virtio/vsock.zig");

const max_kernel_file = 256 * 1024 * 1024;
const guest_port: u32 = 10700;
const ram_size: u64 = 512 * 1024 * 1024;
const probe_disk_size = 1024 * 1024;

const generation_params =
    \\{"schema_version":0,"parent_generation":0,"generation":1,"fork_index":0,"fork_count":1,"parallel_index":0,"parallel_count":1,"fork_batch_id":"slice2a-proof","vm_id":"slice2a-vm","hostname":"slice2a-vm","mac_seed":"00112233445566778899aabbccddeeff","mac_address":"02:00:00:00:00:2a","resume_time_unix_ns":1700000000000000000,"resume_entropy_seed":"00112233445566778899aabbccddeeff"}
;

const guest_command =
    \\/bin/writeout
    \\/bin/gencheck
    \\printf 'devices='
    \\for d in /sys/bus/virtio/devices/virtio*; do printf '%s,' "${d##*/}"; done
    \\printf '\n'
;

const Capture = struct {
    stdout: [8192]u8 = undefined,
    stdout_len: usize = 0,
    stderr: [8192]u8 = undefined,
    stderr_len: usize = 0,

    fn sink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(context orelse return));
        switch (output) {
            .stdout => append(&self.stdout, &self.stdout_len, bytes),
            .stderr => append(&self.stderr, &self.stderr_len, bytes),
            .terminal => {},
        }
    }

    fn append(buffer: []u8, used: *usize, bytes: []const u8) void {
        if (used.* + bytes.len > buffer.len) return;
        @memcpy(buffer[used.*..][0..bytes.len], bytes);
        used.* += bytes.len;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedKernelPath;
    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(max_kernel_file));

    var descriptors_buffer: [board.max_virtio_command_line_len]u8 = undefined;
    const descriptors = try board.formatVirtioCommandLine(&descriptors_buffer);
    const cmdline = try std.fmt.allocPrint(
        allocator,
        "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1 {s}",
        .{ guest_port, descriptors },
    );
    const request = try run.execRequest(allocator, &.{ "/bin/sh", "-lc", guest_command });
    var stream = try vsock.HostStream.init(guest_port, request);
    var capture = Capture{};
    stream.setOutputSink(&capture, Capture.sink);

    var disks: [4][]u8 = undefined;
    for (&disks) |*disk| {
        disk.* = try allocator.alloc(u8, probe_disk_size);
        @memset(disk.*, 0);
    }

    const result = try vm.run(allocator, .{
        .kernel = kernel,
        .initrd = assets.minimal_exec_initrd,
        .cmdline = cmdline,
        .ram_size = ram_size,
        .vcpu_count = 1,
        .console_sink = discardConsole,
        .root_disk = .{ .memory = disks[0] },
        .context_disk = .{ .memory = disks[1] },
        .build_disk = .{ .memory = disks[2] },
        .cache_disk = .{ .memory = disks[3] },
        .exec_probe = &stream,
        .generation_seed = .{ .generation = 1, .params = generation_params },
    });
    if (result != .probe_complete) return error.UnexpectedVmExit;
    if (stream.state != .complete or stream.exit_code == null or stream.exit_code.? != 0) return error.ExecProbeFailed;

    const stdout = capture.stdout[0..capture.stdout_len];
    const stderr = capture.stderr[0..capture.stderr_len];
    if (std.mem.indexOf(u8, stdout, "spore stdout\n") == null) return error.MissingStdout;
    if (std.mem.indexOf(u8, stderr, "spore stderr\n") == null) return error.MissingStderr;
    if (std.mem.indexOf(u8, stdout, "spore generation ready generation=1 vm_id=slice2a-vm entropy_len=32\n") == null) return error.GenerationNotObserved;
    inline for (0..8) |index| {
        const device = std.fmt.comptimePrint("virtio{d}", .{index});
        if (std.mem.indexOf(u8, stdout, device) == null) return error.DeviceNotEnumerated;
    }

    // Point the host stream at a port the guest agent will never use. The
    // watchdog must interrupt KVM_RUN, join the vCPU, and return a typed error.
    var timeout_stream = try vsock.HostStream.init(guest_port + 1, request);
    const timeout_start_ms = monotonicMs();
    const timed_out = blk: {
        _ = vm.run(allocator, .{
            .kernel = kernel,
            .initrd = assets.minimal_exec_initrd,
            .cmdline = cmdline,
            .ram_size = ram_size,
            .vcpu_count = 1,
            .console_sink = discardConsole,
            .root_disk = .{ .memory = disks[0] },
            .context_disk = .{ .memory = disks[1] },
            .build_disk = .{ .memory = disks[2] },
            .cache_disk = .{ .memory = disks[3] },
            .exec_probe = &timeout_stream,
            .exec_probe_timeout_ms = 250,
        }) catch |err| {
            if (err != error.ExecProbeTimeout) return err;
            break :blk true;
        };
        break :blk false;
    };
    if (!timed_out) return error.ExpectedProbeTimeout;
    const timeout_elapsed_ms = monotonicMs() -| timeout_start_ms;
    if (timeout_elapsed_ms > 5_000) return error.ProbeTimeoutUnbounded;
    std.debug.print("slice2a smoke: timeout=ExecProbeTimeout bounded_ms={d}\n", .{timeout_elapsed_ms});

    var kernel_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(kernel, &kernel_digest, .{});
    const kernel_hex = std.fmt.bytesToHex(kernel_digest, .lower);
    var initrd_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(assets.minimal_exec_initrd, &initrd_digest, .{});
    const initrd_hex = std.fmt.bytesToHex(initrd_digest, .lower);
    std.debug.print("slice2a smoke: kernel_sha256={s} initrd_sha256={s} vcpus=1 ram_mib=512\n", .{ &kernel_hex, &initrd_hex });
    std.debug.print("slice2a smoke: stdout={s}", .{stdout});
    std.debug.print("slice2a smoke: stderr={s}", .{stderr});
    std.debug.print("slice2a smoke: exec=ok generation=acknowledged devices=8 result=probe_complete\n", .{});
}

fn discardConsole(_: []const u8) void {}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}
