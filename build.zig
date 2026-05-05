const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const openjpeg_root = b.option([]const u8, "openjpeg-root", "OpenJPEG/vcpkg installed root") orelse findOpenJpegRoot(b);
    const has_openjpeg = openjpeg_root != null;

    const options = b.addOptions();
    options.addOption(bool, "has_openjpeg", has_openjpeg);

    const mod = b.addModule("bioformats", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", options);
    if (openjpeg_root) |root| {
        const include_dir = b.pathJoin(&.{ root, "include", "openjpeg-2.5" });
        const lib_dir = b.pathJoin(&.{ root, "lib" });
        mod.addIncludePath(.{ .cwd_relative = include_dir });
        mod.addLibraryPath(.{ .cwd_relative = lib_dir });
        mod.linkSystemLibrary("openjp2", .{});
        mod.linkSystemLibrary("c", .{});
        mod.addCSourceFile(.{ .file = b.path("src/openjpeg_bridge.c"), .flags = &.{} });
        if (target.result.os.tag == .windows) {
            const dll_path = b.pathJoin(&.{ root, "bin", "openjp2.dll" });
            b.getInstallStep().dependOn(&b.addInstallBinFile(.{ .cwd_relative = dll_path }, "openjp2.dll").step);
        }
    }

    const exe = b.addExecutable(.{
        .name = "bioformats-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bioformats", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (openjpeg_root) |root| run_cmd.addPathDir(b.pathJoin(&.{ root, "bin" }));
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the JSON-RPC server");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (openjpeg_root) |root| run_mod_tests.addPathDir(b.pathJoin(&.{ root, "bin" }));

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    if (openjpeg_root) |root| run_exe_tests.addPathDir(b.pathJoin(&.{ root, "bin" }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn findOpenJpegRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("VCPKG_ROOT")) |root| {
        if (isOpenJpegRoot(b, root)) return root;
        const installed = b.pathJoin(&.{ root, "installed", "x64-windows" });
        if (isOpenJpegRoot(b, installed)) return installed;
    }

    const candidates = [_][]const u8{
        "C:\\Users\\ctyja\\scoop\\persist\\vcpkg\\installed\\x64-windows",
        "C:\\Users\\ctyja\\vcpkg\\installed\\x64-windows",
    };
    for (candidates) |candidate| {
        if (isOpenJpegRoot(b, candidate)) return candidate;
    }
    return null;
}

fn isOpenJpegRoot(b: *std.Build, root: []const u8) bool {
    const header = b.pathJoin(&.{ root, "include", "openjpeg-2.5", "openjpeg.h" });
    std.Io.Dir.accessAbsolute(b.graph.io, header, .{}) catch return false;
    const lib_dir = b.pathJoin(&.{ root, "lib" });
    const candidates = [_][]const u8{
        "openjp2.lib",
        "libopenjp2.a",
        "libopenjp2.so",
        "libopenjp2.dylib",
    };
    for (candidates) |name| {
        const lib = b.pathJoin(&.{ lib_dir, name });
        std.Io.Dir.accessAbsolute(b.graph.io, lib, .{}) catch continue;
        return true;
    }
    return false;
}
