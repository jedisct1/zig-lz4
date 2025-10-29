// Comprehensive compatibility test with reference lz4 implementation
const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");
const lz4f = @import("lz4f.zig");

const TestCase = struct {
    name: []const u8,
    data: []const u8,
};

const text_data =
    \\Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    \\Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
    \\Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.
;

const TestData = struct {
    repeated: []u8,
    random: []u8,
    large: []u8,

    cases: [6]TestCase,

    pub fn init(allocator: std.mem.Allocator) !TestData {
        // Repeated pattern (good compression)
        const repeated = try allocator.alloc(u8, 1000);
        for (0..125) |i| {
            @memcpy(repeated[i * 8 ..][0..8], "ABCDEFGH");
        }

        // Random data (incompressible)
        const random = try allocator.alloc(u8, 256);
        var prng = std.Random.DefaultPrng.init(12345);
        const rand = prng.random();
        rand.bytes(random);

        // Large data (multiple blocks in frame format)
        const large = try allocator.alloc(u8, 100000);
        for (0..large.len) |i| {
            large[i] = @intCast(i % 256);
        }

        return .{
            .repeated = repeated,
            .random = random,
            .large = large,
            .cases = [_]TestCase{
                .{ .name = "small", .data = "Hello World!" },
                .{ .name = "repeated", .data = repeated },
                .{ .name = "text", .data = text_data },
                .{ .name = "random", .data = random },
                .{ .name = "empty", .data = "" },
                .{ .name = "large", .data = large },
            },
        };
    }

    pub fn deinit(self: TestData, allocator: std.mem.Allocator) void {
        allocator.free(self.repeated);
        allocator.free(self.random);
        allocator.free(self.large);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== LZ4 Reference Compatibility Test Suite ===\n\n", .{});

    const test_data = try TestData.init(allocator);
    defer test_data.deinit(allocator);

    const test_cases = &test_data.cases;

    var total_tests: usize = 0;
    var passed_tests: usize = 0;

    // Test 1: Frame format (fast) - Zig -> lz4 tool
    std.debug.print("Test Group 1: Frame Format Fast (Zig compress -> lz4 decompress)\n", .{});
    std.debug.print("{s}\n", .{"-" ** 60});
    for (test_cases) |tc| {
        total_tests += 1;
        if (testFrameFormat(allocator, tc.name, tc.data, null)) {
            passed_tests += 1;
            std.debug.print("✓ {s:<20} PASS\n", .{tc.name});
        } else |err| {
            std.debug.print("✗ {s:<20} FAIL: {}\n", .{ tc.name, err });
        }
    }
    std.debug.print("\n", .{});

    // Test 2: Frame format (fast) - lz4 tool -> Zig
    std.debug.print("Test Group 2: Frame Format Fast (lz4 compress -> Zig decompress)\n", .{});
    std.debug.print("{s}\n", .{"-" ** 60});
    for (test_cases) |tc| {
        total_tests += 1;
        if (testFrameFormatReverse(allocator, tc.name, tc.data)) {
            passed_tests += 1;
            std.debug.print("✓ {s:<20} PASS\n", .{tc.name});
        } else |err| {
            std.debug.print("✗ {s:<20} FAIL: {}\n", .{ tc.name, err });
        }
    }
    std.debug.print("\n", .{});

    // Test 3: Frame format with HC - all levels
    std.debug.print("Test Group 3: Frame Format HC (all levels 2-12)\n", .{});
    std.debug.print("{s}\n", .{"-" ** 60});
    const levels = [_]i32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    for (levels) |level| {
        // Test with repeated pattern (best compression test)
        const tc = test_cases[1]; // repeated pattern
        total_tests += 1;
        if (testFrameFormat(allocator, tc.name, tc.data, level)) {
            passed_tests += 1;
            std.debug.print("✓ Level {d:<2} ({s:<10})  PASS\n", .{ level, tc.name });
        } else |err| {
            std.debug.print("✗ Level {d:<2} ({s:<10})  FAIL: {}\n", .{ level, tc.name, err });
        }
    }
    std.debug.print("\n", .{});

    // Summary
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Total tests: {}\n", .{total_tests});
    std.debug.print("Passed: {}\n", .{passed_tests});
    std.debug.print("Failed: {}\n", .{total_tests - passed_tests});
    std.debug.print("Success rate: {d:.1}%\n\n", .{@as(f64, @floatFromInt(passed_tests)) / @as(f64, @floatFromInt(total_tests)) * 100.0});

    if (passed_tests == total_tests) {
        std.debug.print("🎉 All tests passed! Full compatibility with reference implementation.\n", .{});
    } else {
        std.debug.print("❌ Some tests failed. Please review.\n", .{});
        std.process.exit(1);
    }
}

fn testFrameFormat(allocator: std.mem.Allocator, name: []const u8, src: []const u8, compression_level: ?i32) !void {
    // Compress with frame format
    const prefs = if (compression_level) |level| lz4f.Preferences{
        .compressionLevel = level,
    } else null;

    const compressed = try allocator.alloc(u8, lz4f.compressFrameBound(src.len, prefs));
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, src, compressed, prefs);

    // Write to file
    var filename_buf: [256]u8 = undefined;
    const compressed_file = if (compression_level) |level|
        try std.fmt.bufPrint(&filename_buf, "compat_test_frame_{s}_hc{d}.lz4", .{ name, level })
    else
        try std.fmt.bufPrint(&filename_buf, "compat_test_frame_{s}.lz4", .{name});
    {
        const file = try std.fs.cwd().createFile(compressed_file, .{});
        defer file.close();
        try file.writeAll(compressed[0..compressed_size]);
    }

    // Decompress with lz4 tool
    var decompressed_file_buf: [256]u8 = undefined;
    const decompressed_file = if (compression_level) |level|
        try std.fmt.bufPrint(&decompressed_file_buf, "compat_test_frame_{s}_hc{d}.txt", .{ name, level })
    else
        try std.fmt.bufPrint(&decompressed_file_buf, "compat_test_frame_{s}.txt", .{name});

    std.fs.cwd().deleteFile(decompressed_file) catch {};

    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "lz4 -d -f {s} {s}", .{ compressed_file, decompressed_file });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", cmd },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        std.debug.print("\nFrame decompression failed: {s}\n", .{result.stderr});
        return error.DecompressionFailed;
    }

    // Verify
    const decompressed = try std.fs.cwd().readFileAlloc(decompressed_file, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(decompressed);

    if (!std.mem.eql(u8, src, decompressed)) {
        return error.DataMismatch;
    }

    // Cleanup
    try std.fs.cwd().deleteFile(compressed_file);
    try std.fs.cwd().deleteFile(decompressed_file);
}

fn testFrameFormatReverse(allocator: std.mem.Allocator, name: []const u8, src: []const u8) !void {
    // Write source
    var src_file_buf: [256]u8 = undefined;
    const src_file = try std.fmt.bufPrint(&src_file_buf, "compat_test_frame_{s}_src2.txt", .{name});
    {
        const file = try std.fs.cwd().createFile(src_file, .{});
        defer file.close();
        try file.writeAll(src);
    }

    // Compress with lz4 tool
    var compressed_file_buf: [256]u8 = undefined;
    const compressed_file = try std.fmt.bufPrint(&compressed_file_buf, "compat_test_frame_{s}_lz4.lz4", .{name});

    std.fs.cwd().deleteFile(compressed_file) catch {};

    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "lz4 -f {s} {s}", .{ src_file, compressed_file });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", cmd },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        std.fs.cwd().deleteFile(src_file) catch {};
        return error.CompressionFailed;
    }

    // Read compressed
    const compressed = try std.fs.cwd().readFileAlloc(compressed_file, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(compressed);

    // Decompress with our frame format
    const decompressed = try allocator.alloc(u8, src.len + 1000);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(allocator, compressed, decompressed);

    // Verify
    if (!std.mem.eql(u8, src, decompressed[0..decompressed_size])) {
        return error.DataMismatch;
    }

    // Cleanup
    try std.fs.cwd().deleteFile(src_file);
    try std.fs.cwd().deleteFile(compressed_file);
}
