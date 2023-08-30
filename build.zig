const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "fsnotify",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // const target = (std.zig.system.NativeTargetInfo.detect(cross) catch unreachable).target;
    lib.addFrameworkPath(.{ .path = "/System/Library/Frameworks" });
    lib.addSystemIncludePath(.{ .path = "/System/Library/Frameworks/CoreFoundations.frameworks" });
    lib.linkFramework("CoreFoundation");
    lib.linkFramework("CoreServices");
    // if (target.os.tag.isDarwin()) {}
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.linkFramework("CoreFoundation");
    main_tests.linkFramework("CoreServices");

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
