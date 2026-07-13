const std = @import("std");
const builtin = @import("builtin");

const macos_deployment_target = std.SemanticVersion{ .major = 13, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = defaultTarget(),
    });
    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;
    const target_is_hvf = target_os == .macos and target_arch == .aarch64;
    const target_is_kvm = target_os == .linux and target_arch == .aarch64;
    const host_is_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const host_is_kvm = builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    const optimize = b.standardOptimizeOption(.{
        // Shipping builds are ReleaseSafe only; see SECURITY.md.
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const macos_framework_path = macosFrameworkPath(b);
    const libspore_version = std.SemanticVersion{ .major = 0, .minor = 13, .patch = 0 };

    const libspore_mod = b.addModule("libspore", .{
        .root_source_file = b.path("src/libspore.zig"),
        .target = target,
        .link_libc = true,
    });
    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    const toybox_dep = b.dependency("toybox", .{});
    const minimal_exec_assets = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\set -euo pipefail
        \\scripts/kernel/make-minimal-exec-initrd.sh --toybox-source "$3" "$1"
        \\if command -v sha256sum >/dev/null 2>&1; then
        \\  initrd_sha256="$(sha256sum "$1" | awk '{print $1}')"
        \\else
        \\  initrd_sha256="$(shasum -a 256 "$1" | awk '{print $1}')"
        \\fi
        \\printf '%s\n' \
        \\  'pub const minimal_exec_initrd = @embedFile("minimal-exec-initrd.cpio");' \
        \\  "pub const minimal_exec_initrd_sha256_hex = \"${initrd_sha256}\";" \
        \\  >"$2"
        ,
        "sporevm-initrd-assets",
    });
    _ = minimal_exec_assets.addOutputFileArg("minimal-exec-initrd.cpio");
    const minimal_exec_initrd_module = minimal_exec_assets.addOutputFileArg("minimal-exec-initrd.zig");
    minimal_exec_assets.addDirectoryArg(toybox_dep.path(""));
    minimal_exec_assets.addFileInput(b.path("scripts/kernel/make-minimal-exec-initrd.sh"));
    minimal_exec_assets.addFileInput(b.path("guest/minimal-initrd/toybox.config"));
    const minimal_exec_sources = [_][]const u8{ "agent", "true", "false", "writeout", "sleeper", "finite", "counter", "nproc", "gencheck", "netcheck", "nslookup", "wget", "httpd", "flockcheck", "cgroupcheck", "toybox-sh" };
    for (minimal_exec_sources) |src| {
        minimal_exec_assets.addFileInput(b.path(b.fmt("guest/minimal-initrd/{s}.c", .{src})));
    }
    minimal_exec_assets.addFileInput(b.path("guest/minimal-initrd/build_copy.c"));
    minimal_exec_assets.addFileInput(b.path("guest/minimal-initrd/build_copy.h"));
    libspore_mod.addAnonymousImport("run_assets", .{
        .root_source_file = minimal_exec_initrd_module,
    });
    internal_mod.addAnonymousImport("run_assets", .{
        .root_source_file = minimal_exec_initrd_module,
    });

    const zmoltcp_dep = b.dependency("zmoltcp", .{
        .target = target,
        .optimize = optimize,
    });
    libspore_mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
    internal_mod.addImport("zmoltcp", zmoltcp_dep.module("zmoltcp"));
    if (target_is_hvf) {
        linkHypervisor(libspore_mod, macos_framework_path);
        linkHypervisor(internal_mod, macos_framework_path);
    }

    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "spore_internal", .module = internal_mod },
        },
    });
    if (target_is_hvf) {
        linkHypervisor(c_api_mod, macos_framework_path);
    }
    const libspore_shared = b.addLibrary(.{
        .name = "spore",
        .root_module = c_api_mod,
        .linkage = .dynamic,
        .version = libspore_version,
    });
    const libspore_static = b.addLibrary(.{
        .name = "spore",
        .root_module = c_api_mod,
        .linkage = .static,
        .version = libspore_version,
    });
    const install_libspore_shared = b.addInstallArtifact(libspore_shared, .{});
    const install_libspore_static = b.addInstallArtifact(libspore_static, .{});
    const install_libspore_header = b.addInstallHeaderFile(b.path("include/spore.h"), "spore.h");
    const pc_files = b.addWriteFiles();
    const libspore_pc = pc_files.add("libspore.pc",
        \\prefix=${pcfiledir}/../..
        \\libdir=${prefix}/lib
        \\includedir=${prefix}/include
        \\
        \\Name: libspore
        \\Description: SporeVM C ABI
        \\Version: 0.13.0
        \\Libs: -L${libdir} -lspore
        \\Cflags: -I${includedir}
        \\
    );
    const install_libspore_pc = b.addInstallFileWithDir(libspore_pc, .lib, "pkgconfig/libspore.pc");
    b.getInstallStep().dependOn(&install_libspore_shared.step);
    b.getInstallStep().dependOn(&install_libspore_static.step);
    b.getInstallStep().dependOn(&install_libspore_header.step);
    b.getInstallStep().dependOn(&install_libspore_pc.step);

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

    const libspore_tests = b.addTest(.{ .root_module = libspore_mod });
    const run_libspore_tests = b.addRunArtifact(libspore_tests);
    const libspore_docs = b.addObject(.{
        .name = "libspore-docs",
        .root_module = libspore_mod,
    });
    const install_libspore_docs = b.addInstallDirectory(.{
        .source_dir = libspore_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "share/doc/spore/libspore-zig",
    });
    const docs_step = b.step("docs", "Generate libspore API documentation");
    docs_step.dependOn(&install_libspore_docs.step);

    const libspore_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/libspore_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libspore", .module = libspore_mod },
        },
    });
    const libspore_smoke_tests = b.addTest(.{ .root_module = libspore_smoke_mod });
    const run_libspore_smoke_tests = b.addRunArtifact(libspore_smoke_tests);
    const c_api_tests = b.addTest(.{ .root_module = c_api_mod });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
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
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-DSPORE_AGENT_REQUEST_FUZZ" },
        });
        mod.addCSourceFile(.{
            .file = b.path("guest/minimal-initrd/build_copy.c"),
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
    const c_smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_smoke_mod.addCSourceFile(.{
        .file = b.path("test/c/libspore_smoke.c"),
        .flags = if (target_arch == .aarch64)
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DSPORE_SMOKE_HOST_INFO" }
        else
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.linkLibrary(libspore_static);
    if (target_is_hvf) {
        linkHypervisor(c_smoke_mod, macos_framework_path);
    }
    const c_smoke = b.addExecutable(.{
        .name = "libspore-c-smoke",
        .root_module = c_smoke_mod,
    });
    const run_c_smoke = b.addRunArtifact(c_smoke);

    // ponytail: test artifacts share fixed zig-cache paths; serialize until tests use per-process temp dirs.
    run_libspore_smoke_tests.step.dependOn(&run_libspore_tests.step);
    run_c_api_tests.step.dependOn(&run_libspore_smoke_tests.step);
    run_internal_tests.step.dependOn(&run_c_api_tests.step);
    run_durable_crash_tests_suite.step.dependOn(&run_internal_tests.step);
    run_exe_tests.step.dependOn(&run_durable_crash_tests_suite.step);
    run_c_smoke.step.dependOn(&run_exe_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_libspore_tests.step);
    test_step.dependOn(&run_libspore_smoke_tests.step);
    test_step.dependOn(&run_c_api_tests.step);
    test_step.dependOn(&run_internal_tests.step);
    test_step.dependOn(&run_durable_crash_tests_suite.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_c_smoke.step);

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

    // Hypervisor.framework smoke test: host-only, needs entitlement signing.
    // Run with `zig build hvf-smoke` on an Apple Silicon Mac.
    if (target_is_hvf and host_is_hvf) {
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/hvf_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "spore_internal", .module = internal_mod },
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
                .{ .name = "spore_internal", .module = internal_mod },
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
                .{ .name = "spore_internal", .module = internal_mod },
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
