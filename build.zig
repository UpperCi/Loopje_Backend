const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // deps
    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // db seeding
    const exe_seed = b.addExecutable(.{
        .name = "Loopje Server",
        .root_source_file = b.path("src/seed.zig"),
        .target = target,
        .optimize = optimize,
        //      | cold  | hot  | norm cold, norm hot
        // llvm | 11.0s | 3.8s | 1.0 , 1.0
        //  zig |  8.3s | 1.4s | 0.75, 0.36
        .use_llvm = false,
    });

    exe_seed.root_module.addImport("pg", pg.module("pg"));

    b.installArtifact(exe_seed);

    const run_exe_seed = b.addRunArtifact(exe_seed);
    const run_step_seed = b.step("seed", "Seed the db");
    run_step_seed.dependOn(&run_exe_seed.step);

    // webserver
    const exe = b.addExecutable(.{
        .name = "Loopje Seed",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = false,
    });

    exe.root_module.addImport("pg", pg.module("pg"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    // tests
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/navigation.zig"),
        .target = target,
    });

    unit_tests.root_module.addImport("pg", pg.module("pg"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
