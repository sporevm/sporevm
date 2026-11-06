const std = @import("std");
const builtin = @import("builtin");
const aarch64_board = @import("src/aarch64/board.zig");
const x86_64_board = @import("src/x86_64/board.zig");

const macos_deployment_target = std.SemanticVersion{ .major = 13, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = defaultTarget(),
    });
    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;
    const target_is_hvf = target_os == .macos and target_arch == .aarch64;
    const target_is_kvm = target_os == .linux and target_arch == .aarch64;
    const target_is_x86_kvm = target_os == .linux and target_arch == .x86_64;
    const host_is_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const host_is_kvm = builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    const optimize = b.standardOptimizeOption(.{
        // Shipping builds are ReleaseSafe only; see SECURITY.md.
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const macos_framework_path = macosFrameworkPath(b);

    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    const smoke_helpers = b.option(bool, "smoke-helpers", "Embed the test-only helper binaries the VM smoke scripts run in the guest initrd") orelse false;
    const toybox = b.dependency("toybox", .{}).path("");
    const aarch64_initrd = addMinimalExecInitrd(b, toybox, .aarch64, false);
    const x86_64_initrd = addMinimalExecInitrd(b, toybox, .x86_64, false);
    const minimal_exec_initrd_module = if (smoke_helpers)
        addMinimalExecInitrd(b, toybox, target_arch, true).module
    else switch (target_arch) {
        .aarch64 => aarch64_initrd.module,
        .x86_64 => x86_64_initrd.module,
        else => std.debug.panic("unsupported embedded guest architecture: {s}", .{@tagName(target_arch)}),
    };
    const guest_generation_base = generationBase(target_arch) orelse unreachable;
    internal_mod.addAnonymousImport("run_assets", .{
        .root_source_file = minimal_exec_initrd_module,
    });

    const zmoltcp_dep = b.dependency("zmoltcp", .{
        .target = target,
        .optimize = optimize,
    });
    internal_mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
    if (target_is_hvf) {
        linkHypervisor(internal_mod, macos_framework_path);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spore_internal", .module = internal_mod },
        },
    });
    if (target_is_hvf) {
        linkHypervisor(exe_mod, macos_framework_path);
    }

    const exe = b.addExecutable(.{
        .name = "spore",
        .root_module = exe_mod,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const spore_ready = if (target_is_hvf and host_is_hvf) blk: {
        const sign_spore = b.addSystemCommand(&.{
            "codesign",                      "--sign", "-", "--force", "--entitlements", "spore.entitlements",
            b.getInstallPath(.bin, "spore"),
        });
        sign_spore.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign_spore.step);
        break :blk &sign_spore.step;
    } else &install_exe.step;

    const run_step = b.step("run", "Run the spore CLI");
    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "spore")});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const internal_test_mod = if (target_is_kvm) blk: {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .link_libc = true,
        });
        mod.addAnonymousImport("run_assets", .{
            .root_source_file = minimal_exec_initrd_module,
        });
        mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
        mod.addCSourceFile(.{
            .file = b.path("guest/minimal-initrd/agent.c"),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-function",
                "-DSPORE_AGENT_REQUEST_FUZZ",
                b.fmt("-DSPORE_GENERATION_BASE=0x{x}ULL", .{guest_generation_base}),
            },
        });
        mod.addCSourceFile(.{
            .file = b.path("guest/minimal-initrd/build_copy.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-DSPORE_AGENT_REQUEST_FUZZ" },
        });
        mod.addCSourceFile(.{
            .file = b.path("guest/minimal-initrd/build_run_sandbox.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-DSPORE_AGENT_REQUEST_FUZZ" },
        });
        break :blk mod;
    } else internal_mod;
    const internal_tests = b.addTest(.{ .root_module = internal_test_mod });
    const run_internal_tests = b.addRunArtifact(internal_tests);
    const durable_crash_test_mod = b.createModule(.{
        .root_source_file = b.path("src/durable_release_proof.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const durable_crash_tests = b.addTest(.{
        .root_module = durable_crash_test_mod,
        .filters = &.{"durable process-boundary release proof"},
    });
    const run_durable_crash_tests = b.addRunArtifact(durable_crash_tests);
    const run_durable_crash_tests_suite = b.addRunArtifact(durable_crash_tests);
    const durable_crash_test_step = b.step("durable-crash-test", "Run saved-disk process-boundary crash recovery proof");
    durable_crash_test_step.dependOn(&run_durable_crash_tests.step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const rootfs_slow_mod = b.createModule(.{
        .root_source_file = b.path("src/rootfs_slow_tests.zig"),
        .target = target,
        .link_libc = true,
    });
    const rootfs_slow_tests = b.addTest(.{ .root_module = rootfs_slow_mod });
    const run_rootfs_slow_tests = b.addRunArtifact(rootfs_slow_tests);

    const x86_64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x86_64_tests.zig"),
            .target = b.graph.host,
        }),
    });
    x86_64_tests.root_module.link_libc = true;
    const run_x86_64_tests = b.addRunArtifact(x86_64_tests);

    // ponytail: test artifacts share fixed zig-cache paths; serialize until tests use per-process temp dirs.
    run_durable_crash_tests_suite.step.dependOn(&run_internal_tests.step);
    run_exe_tests.step.dependOn(&run_durable_crash_tests_suite.step);
    run_x86_64_tests.step.dependOn(&run_exe_tests.step);

    const test_step = b.step("test", "Run unit tests");
    const minimal_exec_initrd_tests = b.addSystemCommand(&.{"bash"});
    minimal_exec_initrd_tests.addFileArg(b.path("scripts/kernel/test-minimal-exec-initrd.sh"));
    minimal_exec_initrd_tests.addDirectoryArg(toybox);
    minimal_exec_initrd_tests.addFileArg(aarch64_initrd.cpio);
    minimal_exec_initrd_tests.addFileArg(x86_64_initrd.cpio);
    // Files the check reads besides its arguments.
    minimal_exec_initrd_tests.addFileInput(b.path("scripts/kernel/make-minimal-exec-initrd.sh"));
    minimal_exec_initrd_tests.addFileInput(b.path("build.zig"));
    minimal_exec_initrd_tests.addFileInput(b.path("guest/minimal-initrd/agent.c"));
    // An output makes the check cacheable instead of rerunning every build.
    _ = minimal_exec_initrd_tests.captureStdOut(.{});
    const minimal_exec_initrd_test_step = b.step("minimal-exec-initrd-test", "Build every guest architecture's embedded initrd and check that it rebuilds byte-identically");
    minimal_exec_initrd_test_step.dependOn(&minimal_exec_initrd_tests.step);
    test_step.dependOn(minimal_exec_initrd_test_step);
    test_step.dependOn(&run_internal_tests.step);
    test_step.dependOn(&run_durable_crash_tests_suite.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_x86_64_tests.step);

    const rootfs_slow_test_step = b.step("rootfs-slow-test", "Run slow rootfs/ext4 conformance tests");
    rootfs_slow_test_step.dependOn(&run_rootfs_slow_tests.step);

    // VM-backed `spore build` RUN smoke. Kept out of the default test step so
    // plain `zig build test` remains hermetic.
    if ((target_is_hvf and host_is_hvf) or (target_is_kvm and host_is_kvm)) {
        const linux_arm64_musl = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .musl,
        });
        const build_smoke_shell_mod = b.createModule(.{
            .target = linux_arm64_musl,
            .optimize = .ReleaseSmall,
            .link_libc = true,
        });
        build_smoke_shell_mod.addCSourceFile(.{
            .file = b.path("guest/build-smoke-sh.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        const build_smoke_shell = b.addExecutable(.{
            .name = "spore-build-smoke-sh",
            .root_module = build_smoke_shell_mod,
        });
        const install_build_smoke_shell = b.addInstallArtifact(build_smoke_shell, .{});

        const build_run_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/build_run_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "spore_internal", .module = internal_mod },
            },
        });
        if (target_is_hvf) {
            linkHypervisor(build_run_smoke_mod, macos_framework_path);
        }
        const build_run_smoke = b.addExecutable(.{
            .name = "spore-build-run-smoke",
            .root_module = build_run_smoke_mod,
        });
        const install_build_run_smoke = b.addInstallArtifact(build_run_smoke, .{});

        const build_run_smoke_ready = if (target_is_hvf) blk: {
            const sign_build_run_smoke = b.addSystemCommand(&.{
                "codesign",                                      "--sign", "-", "--force", "--entitlements", "spore.entitlements",
                b.getInstallPath(.bin, "spore-build-run-smoke"),
            });
            sign_build_run_smoke.step.dependOn(&install_build_run_smoke.step);
            break :blk &sign_build_run_smoke.step;
        } else &install_build_run_smoke.step;

        const run_build_smoke = b.addSystemCommand(&.{
            b.getInstallPath(.bin, "spore-build-run-smoke"),
            b.getInstallPath(.bin, "spore-build-smoke-sh"),
            b.getInstallPath(.bin, "spore"),
        });
        run_build_smoke.step.dependOn(build_run_smoke_ready);
        run_build_smoke.step.dependOn(&install_build_smoke_shell.step);
        run_build_smoke.step.dependOn(spore_ready);

        const build_run_smoke_step = b.step("spore-build-run-smoke", "Run the VM-backed spore build RUN executor smoke test");
        build_run_smoke_step.dependOn(&run_build_smoke.step);

        const run_large_copy_smoke = b.addSystemCommand(&.{
            b.getInstallPath(.bin, "spore-build-run-smoke"),
            b.getInstallPath(.bin, "spore-build-smoke-sh"),
            b.getInstallPath(.bin, "spore"),
            "--large-copy",
        });
        run_large_copy_smoke.step.dependOn(build_run_smoke_ready);
        run_large_copy_smoke.step.dependOn(&install_build_smoke_shell.step);
        run_large_copy_smoke.step.dependOn(spore_ready);

        const build_large_copy_smoke_step = b.step("spore-build-large-copy-smoke", "Run the VM-backed multi-GiB spore build COPY smoke test");
        build_large_copy_smoke_step.dependOn(&run_large_copy_smoke.step);

        const run_large_run_smoke = b.addSystemCommand(&.{
            b.getInstallPath(.bin, "spore-build-run-smoke"),
            b.getInstallPath(.bin, "spore-build-smoke-sh"),
            "--large-run",
        });
        run_large_run_smoke.step.dependOn(build_run_smoke_ready);
        run_large_run_smoke.step.dependOn(&install_build_smoke_shell.step);

        const build_large_run_smoke_step = b.step("spore-build-large-run-smoke", "Run the VM-backed 512 MiB nonzero spore build RUN smoke test");
        build_large_run_smoke_step.dependOn(&run_large_run_smoke.step);

        const run_block_enospc_cli_smoke = b.addSystemCommand(&.{
            "bash",
            "test/smoke/rootfs/build-enospc-cli.sh",
            "block",
            b.getInstallPath(.bin, "spore"),
            b.getInstallPath(.bin, "spore-build-run-smoke"),
            b.getInstallPath(.bin, "spore-build-smoke-sh"),
        });
        run_block_enospc_cli_smoke.step.dependOn(build_run_smoke_ready);
        run_block_enospc_cli_smoke.step.dependOn(&install_build_smoke_shell.step);
        run_block_enospc_cli_smoke.step.dependOn(b.getInstallStep());

        const build_block_enospc_smoke_step = b.step("spore-build-block-enospc-smoke", "Run the VM-backed spore build block ENOSPC publication smoke test");
        build_block_enospc_smoke_step.dependOn(&run_block_enospc_cli_smoke.step);

        const run_inode_enospc_cli_smoke = b.addSystemCommand(&.{
            "bash",
            "test/smoke/rootfs/build-enospc-cli.sh",
            "inode",
            b.getInstallPath(.bin, "spore"),
            b.getInstallPath(.bin, "spore-build-run-smoke"),
            b.getInstallPath(.bin, "spore-build-smoke-sh"),
        });
        run_inode_enospc_cli_smoke.step.dependOn(build_run_smoke_ready);
        run_inode_enospc_cli_smoke.step.dependOn(&install_build_smoke_shell.step);
        run_inode_enospc_cli_smoke.step.dependOn(b.getInstallStep());

        const build_inode_enospc_smoke_step = b.step("spore-build-inode-enospc-smoke", "Run the VM-backed spore build inode ENOSPC publication smoke test");
        build_inode_enospc_smoke_step.dependOn(&run_inode_enospc_cli_smoke.step);
    }

    // x86-64 frozen-board smoke: host-only, needs /dev/kvm.
    if (target_is_x86_kvm) {
        const board_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/x86_64_board_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = true,
        });
        // The board smoke runs /bin/blkcheck, so it always embeds the helpers.
        board_smoke_mod.addAnonymousImport("run_assets", .{
            .root_source_file = if (smoke_helpers) minimal_exec_initrd_module else addMinimalExecInitrd(b, toybox, .x86_64, true).module,
        });
        board_smoke_mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
        const board_smoke_exe = b.addExecutable(.{
            .name = "x86-board-smoke",
            .root_module = board_smoke_mod,
        });
        const install_board_smoke = b.addInstallArtifact(board_smoke_exe, .{});
        const board_smoke_step = b.step("x86-board-smoke", "Build the native x86 frozen-board guest-agent smoke");
        board_smoke_step.dependOn(&install_board_smoke.step);
    }
}

const MinimalExecInitrd = struct {
    cpio: std.Build.LazyPath,
    module: std.Build.LazyPath,
};

/// Build the embedded guest initrd for one architecture, with the smoke
/// helpers for test builds. The generator owns the guest source list and
/// reports it in a depfile, so the cached result is rebuilt only when a guest
/// source, the generator, or Toybox changes.
fn addMinimalExecInitrd(b: *std.Build, toybox: std.Build.LazyPath, arch: std.Target.Cpu.Arch, smoke_helpers: bool) MinimalExecInitrd {
    const run = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\set -euo pipefail
        \\# Arguments after the two outputs are generator flags (--smoke-helpers).
        \\"$1" --arch "$2" --generation-base "$3" --toybox-source "$4" --depfile "$5" "${@:8}" "$6"
        \\if command -v sha256sum >/dev/null 2>&1; then
        \\  initrd_sha256="$(sha256sum "$6" | awk '{print $1}')"
        \\else
        \\  initrd_sha256="$(shasum -a 256 "$6" | awk '{print $1}')"
        \\fi
        \\printf '%s\n' \
        \\  'pub const minimal_exec_initrd = @embedFile("minimal-exec-initrd.cpio");' \
        \\  "pub const minimal_exec_initrd_sha256_hex = \"${initrd_sha256}\";" \
        \\  >"$7"
        ,
        "sporevm-initrd-assets",
    });
    run.setName(b.fmt("minimal exec initrd {s}{s}", .{ @tagName(arch), if (smoke_helpers) " with smoke helpers" else "" }));
    run.addFileArg(b.path("scripts/kernel/make-minimal-exec-initrd.sh"));
    run.addArg(@tagName(arch));
    run.addArg(b.fmt("0x{x}", .{generationBase(arch).?}));
    run.addDirectoryArg(toybox);
    _ = run.addDepFileOutputArg("minimal-exec-initrd.d");
    const initrd: MinimalExecInitrd = .{
        .cpio = run.addOutputFileArg("minimal-exec-initrd.cpio"),
        .module = run.addOutputFileArg("minimal-exec-initrd.zig"),
    };
    if (smoke_helpers) run.addArg("--smoke-helpers");
    return initrd;
}

/// Keep the guest agent's MMIO definition tied to the selected, validated
/// board instead of accepting a user-supplied build option or a second C
/// constant that can drift from the VMM.
fn generationBase(arch: std.Target.Cpu.Arch) ?u64 {
    return switch (arch) {
        .aarch64 => aarch64_board.generation_base,
        .x86_64 => x86_64_board.generation_base,
        else => null,
    };
}

fn macosFrameworkPath(b: *std.Build) ?std.Build.LazyPath {
    const sdkroot = macosSdkRoot(b) orelse return null;
    if (sdkroot.len == 0) {
        return null;
    }
    return .{ .cwd_relative = b.pathJoin(&.{ sdkroot, "System/Library/Frameworks" }) };
}

fn macosSdkRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        if (sdkroot.len != 0) {
            return sdkroot;
        }
    }
    if (builtin.os.tag != .macos) {
        return null;
    }

    var code: u8 = undefined;
    const stdout = b.runAllowFail(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }, &code, .ignore) catch return null;
    const sdkroot = std.mem.trim(u8, stdout, " \t\r\n");
    if (sdkroot.len == 0) {
        return null;
    }
    return sdkroot;
}

fn defaultTarget() std.Target.Query {
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        return .{
            .cpu_arch = .aarch64,
            .cpu_model = .native,
            .os_tag = .macos,
            .os_version_min = .{ .semver = macos_deployment_target },
        };
    }
    return .{};
}

fn linkHypervisor(mod: *std.Build.Module, framework_path: ?std.Build.LazyPath) void {
    if (framework_path) |path| {
        mod.addSystemFrameworkPath(path);
    }
    mod.linkFramework("Hypervisor", .{});
}
