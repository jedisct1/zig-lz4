const std = @import("std");
const lz4 = @import("lz4.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("LZ4 Zig Implementation - Test Suite\n", .{});
    try stdout.print("===================================\n\n", .{});

    // Test 0: Very simple test - minimal input
    {
        try stdout.print("Test 0: Minimal input (ABC)...\n", .{});
        const original = "AAAA";

        const maxCompressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Original size: {d}\n", .{original.len});
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});
        try stdout.print("  Compressed bytes: ", .{});
        for (compressed[0..compressedSize]) |b| {
            try stdout.print("{x:0>2} ", .{b});
        }
        try stdout.print("\n", .{});
        try stdout.flush();

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);
        try stdout.print("  Decompressed size: {d}\n", .{decompressedSize});

        if (decompressedSize != original.len) {
            try stdout.print("  ERROR: Size mismatch!\n", .{});
            return error.TestFailed;
        }

        if (!std.mem.eql(u8, original, decompressed)) {
            try stdout.print("  ERROR: Content mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
        try stdout.flush();
    }

    // Test 1: Simple string compression and decompression
    {
        try stdout.print("Test 1: Simple string...\n", .{});
        const original = "Hello, World! This is a test of the LZ4 compression algorithm.";

        const maxCompressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Original size: {d}\n", .{original.len});
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});
        try stdout.flush();

        if (compressedSize == 0) {
            try stdout.print("  ERROR: Compression returned 0 bytes!\n", .{});
            try stdout.flush();
            return error.TestFailed;
        }
        try stdout.print("  Compression ratio: {d:.2}%\n", .{(@as(f64, @floatFromInt(compressedSize)) / @as(f64, @floatFromInt(original.len))) * 100});
        try stdout.flush();

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);
        try stdout.print("  Decompressed size: {d}\n", .{decompressedSize});
        try stdout.flush();

        try stdout.print("  Checking size...\n", .{});
        try stdout.flush();
        if (decompressedSize != original.len) {
            try stdout.print("  ERROR: Size mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  Checking content...\n", .{});
        try stdout.flush();

        // Manual comparison to avoid std.mem.eql hang
        try stdout.print("  Comparing {} bytes...\n", .{original.len});
        try stdout.flush();
        var mismatch = false;
        for (original, 0..) |byte, i| {
            if (byte != decompressed[i]) {
                try stdout.print("  Mismatch at position {}: expected {x}, got {x}\n", .{ i, byte, decompressed[i] });
                try stdout.flush();
                mismatch = true;
                break;
            }
        }
        try stdout.print("  Comparison done\n", .{});
        try stdout.flush();

        try stdout.print("  Checking mismatch flag: {}\n", .{mismatch});
        try stdout.flush();

        if (mismatch) {
            try stdout.print("  ERROR: Content mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
        try stdout.flush();
    }

    // Test 2: Repeated pattern (should compress well)
    try stdout.print("About to start Test 2...\n", .{});
    try stdout.flush();
    {
        try stdout.print("Test 2: Repeated pattern...\n", .{});
        try stdout.flush();
        const original = "AAAAAAAAAAAAAAAA" ** 10; // 160 bytes of 'A'

        const maxCompressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        try stdout.print("  About to compress...\n", .{});
        try stdout.flush();
        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Original size: {d}\n", .{original.len});
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});
        try stdout.print("  Compression ratio: {d:.2}%\n", .{(@as(f64, @floatFromInt(compressedSize)) / @as(f64, @floatFromInt(original.len))) * 100});
        try stdout.flush();

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        try stdout.print("  About to decompress...\n", .{});
        try stdout.flush();
        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);
        try stdout.print("  Decompressed {} bytes\n", .{decompressedSize});
        try stdout.flush();

        try stdout.print("  About to check size...\n", .{});
        try stdout.flush();
        if (decompressedSize != original.len) {
            try stdout.print("  ERROR: Size mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  About to check content (original len = {})...\n", .{original.len});
        try stdout.flush();
        var matches = true;
        for (original, 0..) |byte, i| {
            if (byte != decompressed[i]) {
                try stdout.print("  Mismatch at {}: expected {}, got {}\n", .{ i, byte, decompressed[i] });
                matches = false;
                break;
            }
        }
        if (!matches) {
            try stdout.print("  ERROR: Content mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
        try stdout.flush();
    }

    // Test 3: Empty input
    try stdout.print("About to start Test 3...\n", .{});
    try stdout.flush();
    {
        try stdout.print("Test 3: Empty input...\n", .{});
        try stdout.flush();
        const original = "";

        const maxCompressed = lz4.compressBound(1);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});

        const decompressed = try allocator.alloc(u8, 1);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);
        try stdout.print("  Decompressed size: {d}\n", .{decompressedSize});

        if (decompressedSize != 0) {
            try stdout.print("  ERROR: Expected 0 bytes!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
    }

    // Test 4: Small input (no matches)
    {
        try stdout.print("Test 4: Small input...\n", .{});
        const original = "ABC";

        const maxCompressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Original size: {d}\n", .{original.len});
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);

        if (decompressedSize != original.len) {
            try stdout.print("  ERROR: Size mismatch!\n", .{});
            return error.TestFailed;
        }

        if (!std.mem.eql(u8, original, decompressed)) {
            try stdout.print("  ERROR: Content mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
    }

    // Test 5: Large buffer with patterns
    {
        try stdout.print("Test 5: Large buffer...\n", .{});
        const size: usize = 10000;
        const original = try allocator.alloc(u8, size);
        defer allocator.free(original);

        // Fill with pattern
        for (0..size) |i| {
            original[i] = @intCast(i % 256);
        }

        const maxCompressed = lz4.compressBound(size);
        const compressed = try allocator.alloc(u8, maxCompressed);
        defer allocator.free(compressed);

        const compressedSize = try lz4.compressDefault(original, compressed);
        try stdout.print("  Original size: {d}\n", .{size});
        try stdout.print("  Compressed size: {d}\n", .{compressedSize});
        try stdout.print("  Compression ratio: {d:.2}%\n", .{(@as(f64, @floatFromInt(compressedSize)) / @as(f64, @floatFromInt(size))) * 100});

        const decompressed = try allocator.alloc(u8, size);
        defer allocator.free(decompressed);

        const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], decompressed);

        if (decompressedSize != size) {
            try stdout.print("  ERROR: Size mismatch! Got {d}, expected {d}\n", .{ decompressedSize, size });
            return error.TestFailed;
        }

        if (!std.mem.eql(u8, original, decompressed)) {
            try stdout.print("  ERROR: Content mismatch!\n", .{});
            return error.TestFailed;
        }

        try stdout.print("  PASS\n\n", .{});
    }

    try stdout.print("All tests passed!\n", .{});
}
