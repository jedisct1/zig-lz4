//! Test suite for LZ4 Frame format
//! Validates against reference implementation

const std = @import("std");
const lz4f = @import("lz4f.zig");
const testing = std.testing;

inline fn repeatString(comptime n: usize, comptime str: []const u8) []const u8 {
    const buf: [n][str.len]u8 = @splat(str[0..str.len].*);
    return @ptrCast(&buf);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("\nLZ4F Frame Format - Test Suite\n", .{});
    try stdout.print("===============================\n\n", .{});

    try testBasicCompression(allocator, stdout);
    try testEmptyInput(allocator, stdout);
    try testLargeInput(allocator, stdout);
    try testContentChecksum(allocator, stdout);
    try testBlockChecksum(allocator, stdout);
    try testDifferentBlockSizes(allocator, stdout);
    try testIndependentBlocks(allocator, stdout);
    try testValidateWithReference(allocator, stdout);

    try stdout.print("\n✓ All tests passed!\n\n", .{});
}

fn testBasicCompression(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 1: Basic frame compression/decompression\n", .{});

    const input = "Hello, World! This is a test of LZ4 frame compression.";

    const max_compressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Original: {} bytes\n", .{input.len});
    try stdout.print("  Compressed: {} bytes ({d:.1}%)\n", .{
        compressed_size,
        @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(input.len)) * 100.0,
    });

    const magic = std.mem.readInt(u32, compressed[0..4], .little);
    try testing.expectEqual(lz4f.MAGICNUMBER, magic);

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressed_size);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testEmptyInput(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 2: Empty input\n", .{});

    const input = "";

    const max_compressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Empty frame size: {} bytes\n", .{compressed_size});

    const decompressed = try allocator.alloc(u8, 1024);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqual(@as(usize, 0), decompressed_size);
    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testLargeInput(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 3: Large input (multiple blocks)\n", .{});

    const size = 1024 * 1024;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);

    // Fill with pseudo-random but compressible data
    for (input, 0..) |*byte, i| {
        byte.* = @truncate((i / 16) % 256);
    }

    const max_compressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Original: {} bytes\n", .{input.len});
    try stdout.print("  Compressed: {} bytes ({d:.1}%)\n", .{
        compressed_size,
        @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(input.len)) * 100.0,
    });

    const decompressed = try allocator.alloc(u8, size);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressed_size);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testContentChecksum(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 4: Content checksum validation\n", .{});

    const input = "Testing content checksum functionality.";
    const prefs = lz4f.Preferences{
        .frameInfo = .{
            .contentChecksumFlag = .enabled,
        },
    };

    const max_compressed = lz4f.compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, input, compressed, prefs);
    try stdout.print("  Compressed with checksum: {} bytes\n", .{compressed_size});

    const no_checksum_size = lz4f.compressFrameBound(input.len, null);
    try stdout.print("  Size difference: {} bytes\n", .{
        @as(isize, @intCast(max_compressed)) - @as(isize, @intCast(no_checksum_size)),
    });

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    const corrupted_compressed = try allocator.dupe(u8, compressed[0..compressed_size]);
    defer allocator.free(corrupted_compressed);

    // Corrupt the last byte (checksum)
    corrupted_compressed[corrupted_compressed.len - 1] ^= 0xFF;

    const result = lz4f.decompressFrame(
        allocator,
        corrupted_compressed,
        decompressed,
    );
    try testing.expectError(lz4f.Error.ContentChecksumInvalid, result);

    try stdout.print("  ✓ Checksum validation works\n", .{});
    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testBlockChecksum(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 5: Block checksum validation\n", .{});

    const input = "Testing block checksum functionality.";
    const prefs = lz4f.Preferences{
        .frameInfo = .{
            .blockChecksumFlag = .enabled,
        },
    };

    const max_compressed = lz4f.compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4f.compressFrame(allocator, input, compressed, prefs);
    try stdout.print("  Compressed with block checksum: {} bytes\n", .{compressed_size});

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testDifferentBlockSizes(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 6: Different block sizes\n", .{});

    const input = &@as([1000]u8, @splat('A'));
    const block_sizes = [_]lz4f.BlockSizeID{
        .max64KB,
        .max256KB,
        .max1MB,
        .max4MB,
    };

    for (block_sizes) |block_size| {
        const prefs = lz4f.Preferences{
            .frameInfo = .{
                .blockSizeID = block_size,
            },
        };

        const max_compressed = lz4f.compressFrameBound(input.len, prefs);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4f.compressFrame(allocator, input, compressed, prefs);

        const decompressed = try allocator.alloc(u8, input.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4f.decompressFrame(
            allocator,
            compressed[0..compressed_size],
            decompressed,
        );

        try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

        try stdout.print("  Block size {}: {} bytes compressed\n", .{ block_size, compressed_size });
    }

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testIndependentBlocks(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 7: Independent vs linked blocks\n", .{});

    const input = repeatString(100, "Hello ");

    const linked_prefs = lz4f.Preferences{
        .frameInfo = .{
            .blockMode = .linked,
        },
    };
    const max_linked = lz4f.compressFrameBound(input.len, linked_prefs);
    const linked_compressed = try allocator.alloc(u8, max_linked);
    defer allocator.free(linked_compressed);

    const linked_size = try lz4f.compressFrame(allocator, input, linked_compressed, linked_prefs);

    const indep_prefs = lz4f.Preferences{
        .frameInfo = .{
            .blockMode = .independent,
        },
    };
    const max_indep = lz4f.compressFrameBound(input.len, indep_prefs);
    const indep_compressed = try allocator.alloc(u8, max_indep);
    defer allocator.free(indep_compressed);

    const indep_size = try lz4f.compressFrame(allocator, input, indep_compressed, indep_prefs);

    try stdout.print("  Linked blocks: {} bytes\n", .{linked_size});
    try stdout.print("  Independent blocks: {} bytes\n", .{indep_size});

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const linked_decomp = try lz4f.decompressFrame(
        allocator,
        linked_compressed[0..linked_size],
        decompressed,
    );
    try testing.expectEqualSlices(u8, input, decompressed[0..linked_decomp]);

    const indep_decomp = try lz4f.decompressFrame(
        allocator,
        indep_compressed[0..indep_size],
        decompressed,
    );
    try testing.expectEqualSlices(u8, input, decompressed[0..indep_decomp]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testValidateWithReference(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 8: Validate against reference implementation\n", .{});

    const io = std.Io.Threaded.global_single_threaded.io();

    const test_data = repeatString(20, "Hello, World! This is a comprehensive test of the LZ4 frame format implementation. ");
    const test_file = "/tmp/zig_lz4f_test.txt";
    const compressed_file = "/tmp/zig_lz4f_test.txt.lz4";
    const decompressed_file = "/tmp/zig_lz4f_test.txt.lz4.dec";

    {
        const file = try std.Io.Dir.createFileAbsolute(io, test_file, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_data);
    }

    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
        defer allocator.free(data);

        const max_compressed = lz4f.compressFrameBound(data.len, null);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4f.compressFrame(allocator, data, compressed, null);

        const out_file = try std.Io.Dir.createFileAbsolute(io, compressed_file, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, compressed[0..compressed_size]);
    }

    try stdout.print("  Compressed test file with Zig implementation\n", .{});

    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "lz4",
            "-d",
            "-f", // Force overwrite
            compressed_file,
            decompressed_file,
        },
    }) catch |err| {
        try stdout.print("  ! Reference lz4 command not available ({})\n", .{err});
        try stdout.print("  ✓ SKIP (install lz4 command to validate)\n\n", .{});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (!success) {
        try stdout.print("  ! Reference decompression failed:\n", .{});
        try stdout.print("    {s}\n", .{result.stderr});
        try stdout.print("  ✗ FAIL\n\n", .{});
        return error.ValidationFailed;
    }

    try stdout.print("  Reference lz4 decompressed successfully\n", .{});

    const decompressed = try std.Io.Dir.cwd().readFileAlloc(io, decompressed_file, allocator, .unlimited);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, test_data, decompressed);

    std.Io.Dir.deleteFileAbsolute(io, test_file) catch {};
    std.Io.Dir.deleteFileAbsolute(io, compressed_file) catch {};
    std.Io.Dir.deleteFileAbsolute(io, decompressed_file) catch {};

    try stdout.print("  ✓ Data validated against reference implementation\n", .{});
    try stdout.print("  ✓ PASS\n\n", .{});
}
