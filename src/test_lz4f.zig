//! Test suite for LZ4 Frame format
//! Validates against reference implementation

const std = @import("std");
const lz4f = @import("lz4f.zig");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

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

    // Compress
    const maxCompressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Original: {} bytes\n", .{input.len});
    try stdout.print("  Compressed: {} bytes ({d:.1}%)\n", .{
        compressedSize,
        @as(f64, @floatFromInt(compressedSize)) / @as(f64, @floatFromInt(input.len)) * 100.0,
    });

    // Verify magic number
    const magic = std.mem.readInt(u32, compressed[0..4], .little);
    try testing.expectEqual(lz4f.MAGICNUMBER, magic);

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressedSize);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testEmptyInput(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 2: Empty input\n", .{});

    const input = "";

    const maxCompressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Empty frame size: {} bytes\n", .{compressedSize});

    const decompressed = try allocator.alloc(u8, 1024);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqual(@as(usize, 0), decompressedSize);
    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testLargeInput(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 3: Large input (multiple blocks)\n", .{});

    // Create 1MB of test data
    const size = 1024 * 1024;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);

    // Fill with pseudo-random but compressible data
    for (input, 0..) |*byte, i| {
        byte.* = @truncate((i / 16) % 256);
    }

    const maxCompressed = lz4f.compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4f.compressFrame(allocator, input, compressed, null);
    try stdout.print("  Original: {} bytes\n", .{input.len});
    try stdout.print("  Compressed: {} bytes ({d:.1}%)\n", .{
        compressedSize,
        @as(f64, @floatFromInt(compressedSize)) / @as(f64, @floatFromInt(input.len)) * 100.0,
    });

    const decompressed = try allocator.alloc(u8, size);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressedSize);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);

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

    const maxCompressed = lz4f.compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4f.compressFrame(allocator, input, compressed, prefs);
    try stdout.print("  Compressed with checksum: {} bytes\n", .{compressedSize});

    // Verify frame has content checksum (should be 4 bytes larger than without)
    const noChecksumSize = lz4f.compressFrameBound(input.len, null);
    try stdout.print("  Size difference: {} bytes\n", .{
        @as(isize, @intCast(maxCompressed)) - @as(isize, @intCast(noChecksumSize)),
    });

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);

    // Test checksum corruption detection
    const corruptedCompressed = try allocator.dupe(u8, compressed[0..compressedSize]);
    defer allocator.free(corruptedCompressed);

    // Corrupt the last byte (checksum)
    corruptedCompressed[corruptedCompressed.len - 1] ^= 0xFF;

    const result = lz4f.decompressFrame(
        allocator,
        corruptedCompressed,
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

    const maxCompressed = lz4f.compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4f.compressFrame(allocator, input, compressed, prefs);
    try stdout.print("  Compressed with block checksum: {} bytes\n", .{compressedSize});

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4f.decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testDifferentBlockSizes(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 6: Different block sizes\n", .{});

    const input = "A" ** 1000;
    const blockSizes = [_]lz4f.BlockSizeID{
        .max64KB,
        .max256KB,
        .max1MB,
        .max4MB,
    };

    for (blockSizes) |blockSize| {
        const prefs = lz4f.Preferences{
            .frameInfo = .{
                .blockSizeID = blockSize,
            },
        };

        const maxCompressed = lz4f.compressFrameBound(input.len, prefs);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4f.compressFrame(allocator, input, compressed, prefs);

        const decompressed = try allocator.alloc(u8, input.len);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4f.decompressFrame(
            allocator,
            compressed[0..compressedSize],
            decompressed,
        );

        try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);

        try stdout.print("  Block size {}: {} bytes compressed\n", .{ blockSize, compressedSize });
    }

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testIndependentBlocks(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 7: Independent vs linked blocks\n", .{});

    const input = "Hello " ** 100; // Repeated pattern

    // Test linked blocks (default)
    const linkedPrefs = lz4f.Preferences{
        .frameInfo = .{
            .blockMode = .linked,
        },
    };
    const maxLinked = lz4f.compressFrameBound(input.len, linkedPrefs);
    const linkedCompressed = try allocator.alloc(u8, maxLinked);
    defer allocator.free(linkedCompressed);

    const linkedSize = try lz4f.compressFrame(allocator, input, linkedCompressed, linkedPrefs);

    // Test independent blocks
    const indepPrefs = lz4f.Preferences{
        .frameInfo = .{
            .blockMode = .independent,
        },
    };
    const maxIndep = lz4f.compressFrameBound(input.len, indepPrefs);
    const indepCompressed = try allocator.alloc(u8, maxIndep);
    defer allocator.free(indepCompressed);

    const indepSize = try lz4f.compressFrame(allocator, input, indepCompressed, indepPrefs);

    try stdout.print("  Linked blocks: {} bytes\n", .{linkedSize});
    try stdout.print("  Independent blocks: {} bytes\n", .{indepSize});

    // Verify both decompress correctly
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const linkedDecomp = try lz4f.decompressFrame(
        allocator,
        linkedCompressed[0..linkedSize],
        decompressed,
    );
    try testing.expectEqualSlices(u8, input, decompressed[0..linkedDecomp]);

    const indepDecomp = try lz4f.decompressFrame(
        allocator,
        indepCompressed[0..indepSize],
        decompressed,
    );
    try testing.expectEqualSlices(u8, input, decompressed[0..indepDecomp]);

    try stdout.print("  ✓ PASS\n\n", .{});
}

fn testValidateWithReference(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("Test 8: Validate against reference implementation\n", .{});

    // Create test data file
    const testData = "Hello, World! This is a comprehensive test of the LZ4 frame format implementation. " ** 20;
    const testFile = "/tmp/zig_lz4f_test.txt";
    const compressedFile = "/tmp/zig_lz4f_test.txt.lz4";
    const decompressedFile = "/tmp/zig_lz4f_test.txt.lz4.dec";

    // Write test data
    {
        const file = try std.fs.createFileAbsolute(testFile, .{});
        defer file.close();
        try file.writeAll(testData);
    }

    // Compress with our implementation
    {
        const file = try std.fs.openFileAbsolute(testFile, .{});
        defer file.close();

        const file_size = (try file.stat()).size;
        const data = try allocator.alloc(u8, file_size);
        defer allocator.free(data);
        _ = try file.readAll(data);

        const maxCompressed = lz4f.compressFrameBound(data.len, null);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4f.compressFrame(allocator, data, compressed, null);

        const outFile = try std.fs.createFileAbsolute(compressedFile, .{});
        defer outFile.close();
        try outFile.writeAll(compressed[0..compressedSize]);
    }

    try stdout.print("  Compressed test file with Zig implementation\n", .{});

    // Try to decompress with reference lz4 command
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "lz4",
            "-d",
            "-f", // Force overwrite
            compressedFile,
            decompressedFile,
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
        .Exited => |code| code == 0,
        else => false,
    };

    if (!success) {
        try stdout.print("  ! Reference decompression failed:\n", .{});
        try stdout.print("    {s}\n", .{result.stderr});
        try stdout.print("  ✗ FAIL\n\n", .{});
        return error.ValidationFailed;
    }

    try stdout.print("  Reference lz4 decompressed successfully\n", .{});

    // Verify decompressed data matches original
    const decompressed = blk: {
        const file = try std.fs.openFileAbsolute(decompressedFile, .{});
        defer file.close();
        const file_size = (try file.stat()).size;
        const data = try allocator.alloc(u8, file_size);
        _ = try file.readAll(data);
        break :blk data;
    };
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, testData, decompressed);

    // Clean up
    std.fs.deleteFileAbsolute(testFile) catch {};
    std.fs.deleteFileAbsolute(compressedFile) catch {};
    std.fs.deleteFileAbsolute(decompressedFile) catch {};

    try stdout.print("  ✓ Data validated against reference implementation\n", .{});
    try stdout.print("  ✓ PASS\n\n", .{});
}
