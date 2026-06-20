const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;
    const target_is_hvf = target_os == .macos and target_arch == .aarch64;
    const target_is_kvm = target_os == .linux and target_arch == .aarch64;
    const host_is_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const optimize = b.standardOptimizeOption(.{
        // Shipping builds are ReleaseSafe only; see SECURITY.md.
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const macos_framework_path = macosFrameworkPath(b);

    const mod = b.addModule("sporevm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    const zmoltcp_dep = b.dependency("zmoltcp", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
    if (target_is_hvf) {
        linkHypervisor(mod, macos_framework_path);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sporevm", .module = mod },
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

    const minimal_exec_initrd = b.addSystemCommand(&.{
        "scripts/make-minimal-exec-initrd.sh",
        b.getInstallPath(.prefix, "share/sporevm/minimal-exec-initrd.cpio"),
    });
    b.getInstallStep().dependOn(&minimal_exec_initrd.step);

    if (target_is_hvf and host_is_hvf) {
        const sign_spore = b.addSystemCommand(&.{
            "codesign",                      "--sign", "-", "--force", "--entitlements", "spore.entitlements",
            b.getInstallPath(.bin, "spore"),
        });
        sign_spore.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign_spore.step);
    }

    const run_step = b.step("run", "Run the spore CLI");
    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "spore")});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
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
    if (target_is_hvf and host_is_hvf) {
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/hvf_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sporevm", .module = mod },
            },
        });
        linkHypervisor(smoke_mod, macos_framework_path);

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

        const run_gic_probe = b.addSystemCommand(&.{ b.getInstallPath(.bin, "hvf-smoke"), "--gic-probe" });
        run_gic_probe.step.dependOn(&sign.step);

        const gic_probe_step = b.step("hvf-gic-probe", "Probe Hypervisor.framework GICv3 portable-state support");
        gic_probe_step.dependOn(&run_gic_probe.step);

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
        linkHypervisor(boot_mod, macos_framework_path);

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

    // Linux KVM boot harness: host-only, needs /dev/kvm on aarch64 Linux.
    if (target_is_kvm) {
        const kvm_boot_mod = b.createModule(.{
            .root_source_file = b.path("src/kvm_boot.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sporevm", .module = mod },
            },
        });

        const kvm_boot_exe = b.addExecutable(.{
            .name = "kvm-boot",
            .root_module = kvm_boot_mod,
        });
        const install_kvm_boot = b.addInstallArtifact(kvm_boot_exe, .{});

        const kvm_boot_step = b.step("kvm-boot", "Build the Linux KVM kernel boot harness");
        kvm_boot_step.dependOn(&install_kvm_boot.step);
    }
}

fn macosFrameworkPath(b: *std.Build) ?std.Build.LazyPath {
    const sdkroot = b.graph.environ_map.get("SDKROOT") orelse return null;
    if (sdkroot.len == 0) {
        return null;
    }
    return .{ .cwd_relative = b.pathJoin(&.{ sdkroot, "System/Library/Frameworks" }) };
}

fn linkHypervisor(mod: *std.Build.Module, framework_path: ?std.Build.LazyPath) void {
    if (framework_path) |path| {
        mod.addSystemFrameworkPath(path);
    }
    mod.linkFramework("Hypervisor", .{});
}
