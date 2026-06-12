const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lz4", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "lz4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lz4", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_executables = [_]struct {
        name: []const u8,
        source: []const u8,
        step: []const u8,
        description: []const u8,
    }{
        .{
            .name = "test_lz4f",
            .source = "src/test_lz4f.zig",
            .step = "test-lz4f",
            .description = "Run LZ4F frame format tests",
        },
        .{
            .name = "test_lz4hc",
            .source = "src/test_lz4hc.zig",
            .step = "test-lz4hc",
            .description = "Run LZ4 HC high compression tests",
        },
        .{
            .name = "test_lz4f_hc",
            .source = "src/test_lz4f_hc.zig",
            .step = "test-lz4f-hc",
            .description = "Run LZ4F + HC integration tests",
        },
        .{
            .name = "test_lz4f_hc_simple",
            .source = "src/test_lz4f_hc_simple.zig",
            .step = "test-lz4f-hc-simple",
            .description = "Run simple LZ4F + HC test",
        },
        .{
            .name = "test_lz4hc_stream",
            .source = "src/test_lz4hc_stream.zig",
            .step = "test-lz4hc-stream",
            .description = "Run LZ4 HC streaming API tests",
        },
        .{
            .name = "test_cross_compat",
            .source = "src/test_compat.zig",
            .step = "test-cross-compat",
            .description = "Test cross-compatibility with reference lz4 tool",
        },
        .{
            .name = "test_compat",
            .source = "src/test_compat.zig",
            .step = "test-compat",
            .description = "Run comprehensive compatibility test suite with reference lz4",
        },
    };

    for (test_executables) |config| {
        const test_exe = b.addExecutable(.{
            .name = config.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(config.source),
                .target = target,
                .optimize = optimize,
            }),
        });

        const step = b.step(config.step, config.description);
        const cmd = b.addRunArtifact(test_exe);
        step.dependOn(&cmd.step);
        cmd.step.dependOn(b.getInstallStep());
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
