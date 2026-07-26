const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("render.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable = b.addExecutable(.{
        .name = "render",
        .root_module = module,
    });
    b.installArtifact(executable);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);

    const medium_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/medium_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_medium_tests = b.addRunArtifact(medium_tests);

    const ply_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ply_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ply_tests = b.addRunArtifact(ply_tests);

    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/golden.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_medium_tests.step);
    test_step.dependOn(&run_ply_tests.step);
    test_step.dependOn(&run_golden_tests.step);
}
