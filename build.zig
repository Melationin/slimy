const std = @import("std");
const localasm = @import("localasm");

const slimy_version = std.SemanticVersion.parse("0.1.0-dev") catch @panic("Parse error");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const singlethread = b.option(bool, "singlethread", "Build in single-threaded mode") orelse false;
    const gpu_support = b.option(bool, "gpu", "Support using gpu search") orelse true;
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse false;
    const suffix = b.option(bool, "suffix", "Suffix binary names with version and target") orelse false;
    const timestamp = b.option(bool, "timestamp", "Include build timestamp in version information") orelse false;
    const glslc = b.option([]const u8, "glslc", "Specify the path to the glslc binary") orelse "glslc";
    const size_opt = b.option(u16, "size", "Block size (256, 512, 1024)") orelse 512;
    const lanes_opt = b.option(u8, "lanes", "SIMD lanes (8, 16)") orelse 16;

    const version = try getVersion(b);

    // Default CLI executable
    const default_exe = try addExe(b, target, optimize, singlethread, gpu_support, strip, suffix, timestamp, glslc, version, size_opt, lanes_opt, "slimy");
    b.installArtifact(default_exe);
    const run_cmd = b.addRunArtifact(default_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = default_exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // JNI shared library (uses same opts as default)
    {
        const jni_opts = b.addOptions();
        jni_opts.addOption(u16, "size", size_opt);
        jni_opts.addOption(u8, "lanes", lanes_opt);

        const jni_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "slimy_jni",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/jni.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
                .link_libc = true,
            }),
            .use_llvm = true,
        });
        jni_lib.root_module.addImport("jni", b.dependency("jni", .{}).module("JNI"));
        jni_lib.root_module.addImport("build_opts", jni_opts.createModule());
        jni_lib.root_module.addImport("optz", b.dependency("optz", .{}).module("optz"));
        b.installArtifact(jni_lib);
    }

    // Build all 6 size×lanes variants
    const all_step = b.step("all", "Build all 6 size×lanes variants");
    const variants = [_]struct { size: u16, lanes: u8 }{
        .{ .size = 256, .lanes = 8 },
        .{ .size = 256, .lanes = 16 },
        .{ .size = 512, .lanes = 8 },
        .{ .size = 512, .lanes = 16 },
        .{ .size = 1024, .lanes = 8 },
        .{ .size = 1024, .lanes = 16 },
    };
    for (variants) |v| {
        const name = b.fmt("slimy-{}-{}", .{ v.size, v.lanes });
        const exe = try addExe(b, target, optimize, singlethread, gpu_support, strip, suffix, timestamp, glslc, version, v.size, v.lanes, name);
        all_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    singlethread: bool,
    gpu_support: bool,
    strip: bool,
    suffix: bool,
    timestamp: bool,
    glslc: []const u8,
    version: std.SemanticVersion,
    size: u16,
    lanes: u8,
    name: []const u8,
) !*std.Build.Step.Compile {
    const shader_compile = b.addSystemCommand(&.{ glslc, "-o" });
    const shader_spv = shader_compile.addOutputFileArg("search.spv");
    shader_compile.addFileArg(b.path("src/shader/search.comp"));

    const consts = b.addOptions();
    consts.addOption(std.SemanticVersion, "version", version);
    consts.addOption(?i64, "timestamp", if (timestamp) std.time.timestamp() else null);
    consts.addOption(bool, "gpu_support", gpu_support);

    const opts = b.addOptions();
    opts.addOption(u16, "size", size);
    opts.addOption(u8, "lanes", lanes);

    const exe_name = if (suffix)
        b.fmt("{s}-{f}-{s}", .{ name, version, target.query.zigTriple(b.allocator) catch @panic("OOM") })
    else
        name;

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = singlethread,
            .strip = strip,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    exe.root_module.addImport("build_consts", consts.createModule());
    exe.root_module.addImport("build_opts", opts.createModule());
    exe.root_module.addImport("optz", b.dependency("optz", .{}).module("optz"));
    exe.root_module.addImport("cpuinfo", b.dependency("cpuinfo", .{}).module("cpuinfo"));

    if (gpu_support) gpu_support: {
        exe.root_module.addImport("zcompute", (b.lazyDependency("zcompute", .{}) orelse break :gpu_support).module("zcompute"));
        exe.root_module.addImport("search_spv", b.createModule(.{ .root_source_file = shader_spv }));
    }

    return exe;
}

fn getVersion(b: *std.Build) !std.SemanticVersion {
    var version = slimy_version;
    if (version.pre != null) {
        var code: u8 = undefined;
        if (b.runAllowFail(
            &.{ "git", "rev-parse", "--short", "HEAD" },
            &code,
            .Inherit,
        )) |commit| {
            version.build = std.mem.trimRight(u8, commit, "\n");
            _ = b.runAllowFail(
                &.{ "git", "diff-index", "--quiet", "HEAD" },
                &code,
                .Inherit,
            ) catch |err| switch (err) {
                error.ExitCodeFailure => version.build = b.fmt("{s}-dirty", .{version.build.?}),
                else => |e| return e,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    return version;
}
