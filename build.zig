const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        // Shipping builds are ReleaseSafe only; see SECURITY.md.
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const mod = b.addModule("sporevm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "spore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sporevm", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the spore CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Hypervisor.framework smoke test: host-only, needs entitlement signing.
    // Run with `zig build hvf-smoke` on an Apple Silicon Mac.
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/hvf_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sporevm", .module = mod },
            },
        });
        smoke_mod.linkFramework("Hypervisor", .{});

        const smoke = b.addExecutable(.{
            .name = "hvf-smoke",
            .root_module = smoke_mod,
        });
        const install_smoke = b.addInstallArtifact(smoke, .{});

        const sign = b.addSystemCommand(&.{
            "codesign",                          "--sign", "-", "--force", "--entitlements", "spore.entitlements",
            b.getInstallPath(.bin, "hvf-smoke"),
        });
        sign.step.dependOn(&install_smoke.step);

        const run_smoke = b.addSystemCommand(&.{b.getInstallPath(.bin, "hvf-smoke")});
        run_smoke.step.dependOn(&sign.step);

        const smoke_step = b.step("hvf-smoke", "Run the Hypervisor.framework smoke test (signs the binary)");
        smoke_step.dependOn(&run_smoke.step);

        // Kernel boot harness: builds and signs, does not run (needs a kernel).
        const boot_mod = b.createModule(.{
            .root_source_file = b.path("src/hvf_boot.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sporevm", .module = mod },
            },
        });
        boot_mod.linkFramework("Hypervisor", .{});

        const boot_exe = b.addExecutable(.{
            .name = "hvf-boot",
            .root_module = boot_mod,
        });
        const install_boot = b.addInstallArtifact(boot_exe, .{});

        const sign_boot = b.addSystemCommand(&.{
            "codesign",                         "--sign", "-", "--force", "--entitlements", "spore.entitlements",
            b.getInstallPath(.bin, "hvf-boot"),
        });
        sign_boot.step.dependOn(&install_boot.step);

        const boot_step = b.step("hvf-boot", "Build and sign the HVF kernel boot harness");
        boot_step.dependOn(&sign_boot.step);
    }
}
