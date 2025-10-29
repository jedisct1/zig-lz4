// Test suite for LZ4 HC compression
const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== LZ4 HC Test Suite ===\n\n", .{});

    try testEmptyInput();
    try testSmallInput();
    try testRepeatedPattern(allocator);
    try testTextData(allocator);
    try testRandomData(allocator);
    try testAllLevels(allocator);
    try testRoundTrip(allocator);

    // New tests for HC enhancements
    try testLZ4MID(allocator);
    try testPatternDetection(allocator);
    try testHCWithFrameFormat(allocator);
    try testOptimalParser(allocator);

    std.debug.print("\n=== All tests passed! ===\n", .{});
}

fn testEmptyInput() !void {
    std.debug.print("Test: Empty input... ", .{});

    const src: []const u8 = "";
    var dst: [100]u8 = undefined;

    const compressed_size = try lz4hc.compressHC(src, &dst, 9);
    try testing.expectEqual(@as(usize, 0), compressed_size);

    std.debug.print("PASS\n", .{});
}

fn testSmallInput() !void {
    std.debug.print("Test: Small input... ", .{});

    const src = "Hello";
    var compressed: [100]u8 = undefined;
    var decompressed: [100]u8 = undefined;

    const compressed_size = try lz4hc.compressHC(src, &compressed, 9);
    try testing.expect(compressed_size > 0);
    try testing.expect(compressed_size < src.len + 10);

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], &decompressed);
    try testing.expectEqual(src.len, decompressed_size);
    try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

    std.debug.print("PASS (compressed: {} -> {} bytes)\n", .{ src.len, compressed_size });
}

fn testRepeatedPattern(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Repeated pattern... ", .{});

    // Create a buffer with repeated pattern "ABCD"
    const pattern = "ABCD";
    const repeat_count = 1000;
    const src = try allocator.alloc(u8, pattern.len * repeat_count);
    defer allocator.free(src);

    for (0..repeat_count) |i| {
        @memcpy(src[i * pattern.len ..][0..pattern.len], pattern);
    }

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
    defer allocator.free(compressed);

    const compressed_size = try lz4hc.compressHC(src, compressed, 9);
    const ratio = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size));

    try testing.expect(compressed_size > 0);
    try testing.expect(compressed_size < src.len); // Should compress well

    // Decompress and verify
    const decompressed = try allocator.alloc(u8, src.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
    try testing.expectEqual(src.len, decompressed_size);
    try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

    std.debug.print("PASS (compressed: {} -> {} bytes, ratio: {d:.2}x)\n", .{ src.len, compressed_size, ratio });
}

fn testTextData(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Text data... ", .{});

    const text =
        \\Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        \\Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
        \\Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        \\Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.
    ;

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(text.len));
    defer allocator.free(compressed);

    const compressed_size = try lz4hc.compressHC(text, compressed, 9);
    const ratio = @as(f64, @floatFromInt(text.len)) / @as(f64, @floatFromInt(compressed_size));

    try testing.expect(compressed_size > 0);

    // Decompress and verify
    const decompressed = try allocator.alloc(u8, text.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
    try testing.expectEqual(text.len, decompressed_size);
    try testing.expectEqualSlices(u8, text, decompressed[0..decompressed_size]);

    std.debug.print("PASS (compressed: {} -> {} bytes, ratio: {d:.2}x)\n", .{ text.len, compressed_size, ratio });
}

fn testRandomData(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Random data (incompressible)... ", .{});

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const size = 1000;
    const src = try allocator.alloc(u8, size);
    defer allocator.free(src);

    random.bytes(src);

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
    defer allocator.free(compressed);

    const compressed_size = try lz4hc.compressHC(src, compressed, 9);

    try testing.expect(compressed_size > 0);
    // Random data should not compress well
    try testing.expect(compressed_size >= src.len);

    // Decompress and verify
    const decompressed = try allocator.alloc(u8, src.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
    try testing.expectEqual(src.len, decompressed_size);
    try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

    std.debug.print("PASS (compressed: {} -> {} bytes)\n", .{ src.len, compressed_size });
}

fn testAllLevels(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: All compression levels... \n", .{});

    const pattern = "ABCD";
    const repeat_count = 500;
    const src = try allocator.alloc(u8, pattern.len * repeat_count);
    defer allocator.free(src);

    for (0..repeat_count) |i| {
        @memcpy(src[i * pattern.len ..][0..pattern.len], pattern);
    }

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
    defer allocator.free(compressed);

    const decompressed = try allocator.alloc(u8, src.len);
    defer allocator.free(decompressed);

    // Test levels 2-12
    var level: i32 = 2;
    while (level <= 12) : (level += 1) {
        const compressed_size = try lz4hc.compressHC(src, compressed, level);
        const ratio = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size));

        try testing.expect(compressed_size > 0);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
        try testing.expectEqual(src.len, decompressed_size);
        try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

        std.debug.print("  Level {}: {} -> {} bytes (ratio: {d:.2}x)\n", .{ level, src.len, compressed_size, ratio });
    }

    std.debug.print("PASS\n", .{});
}

fn testRoundTrip(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Round-trip with various sizes... \n", .{});

    const sizes = [_]usize{ 1, 10, 100, 1000, 10000 };

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    for (sizes) |size| {
        const src = try allocator.alloc(u8, size);
        defer allocator.free(src);

        // Mix of repeated and random data
        const repeated_portion = size / 2;
        @memset(src[0..repeated_portion], 'X');
        random.bytes(src[repeated_portion..]);

        const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
        defer allocator.free(compressed);

        const compressed_size = try lz4hc.compressHC(src, compressed, 9);

        try testing.expect(compressed_size > 0);
        try testing.expect(compressed_size <= lz4hc.compressBound(src.len));

        const decompressed = try allocator.alloc(u8, src.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
        try testing.expectEqual(src.len, decompressed_size);
        try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

        std.debug.print("  Size {}: PASS\n", .{size});
    }

    std.debug.print("PASS\n", .{});
}

// Test LZ4MID (level 2) - dual hash table algorithm
fn testLZ4MID(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: LZ4MID (level 2)... ", .{});

    // Create data that should compress well with MID
    const pattern = "TestData";
    const repeat_count = 250;
    const src = try allocator.alloc(u8, pattern.len * repeat_count);
    defer allocator.free(src);

    for (0..repeat_count) |i| {
        @memcpy(src[i * pattern.len ..][0..pattern.len], pattern);
    }

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
    defer allocator.free(compressed);

    // Compress with level 2 (LZ4MID)
    const compressed_size_l2 = try lz4hc.compressHC(src, compressed, 2);
    const ratio_l2 = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size_l2));

    // Compress with level 3 (Hash Chain) for comparison
    const compressed_size_l3 = try lz4hc.compressHC(src, compressed, 3);
    const ratio_l3 = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size_l3));

    try testing.expect(compressed_size_l2 > 0);
    try testing.expect(compressed_size_l2 < src.len);

    // Verify decompression works
    const decompressed = try allocator.alloc(u8, src.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size_l2], decompressed);
    try testing.expectEqual(src.len, decompressed_size);
    try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

    std.debug.print("PASS\n", .{});
    std.debug.print("  Level 2 (MID): {} -> {} bytes (ratio: {d:.2}x)\n", .{ src.len, compressed_size_l2, ratio_l2 });
    std.debug.print("  Level 3 (HC):  {} -> {} bytes (ratio: {d:.2}x)\n", .{ src.len, compressed_size_l3, ratio_l3 });
}

// Test pattern detection at level 9+
fn testPatternDetection(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Pattern detection (level 9+)... ", .{});

    // Create highly repetitive pattern data
    const tests = [_]struct {
        name: []const u8,
        pattern: []const u8,
        repeat: usize,
    }{
        .{ .name = "1-byte", .pattern = "A", .repeat = 1000 },
        .{ .name = "2-byte", .pattern = "AB", .repeat = 1000 },
        .{ .name = "4-byte", .pattern = "ABCD", .repeat = 1000 },
    };

    for (tests) |t| {
        const src = try allocator.alloc(u8, t.pattern.len * t.repeat);
        defer allocator.free(src);

        for (0..t.repeat) |i| {
            @memcpy(src[i * t.pattern.len ..][0..t.pattern.len], t.pattern);
        }

        const compressed = try allocator.alloc(u8, lz4hc.compressBound(src.len));
        defer allocator.free(compressed);

        // Compress with level 9 (with pattern analysis)
        const compressed_size_l9 = try lz4hc.compressHC(src, compressed, 9);
        const ratio_l9 = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size_l9));

        // Compress with level 8 (without pattern analysis)
        const compressed_size_l8 = try lz4hc.compressHC(src, compressed, 8);
        const ratio_l8 = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(compressed_size_l8));

        try testing.expect(compressed_size_l9 > 0);
        try testing.expect(compressed_size_l9 < src.len);

        // Verify decompression
        const decompressed = try allocator.alloc(u8, src.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size_l9], decompressed);
        try testing.expectEqual(src.len, decompressed_size);
        try testing.expectEqualSlices(u8, src, decompressed[0..decompressed_size]);

        std.debug.print("\n  {s} pattern: L8={} bytes ({d:.1}x), L9={} bytes ({d:.1}x)", .{
            t.name,
            compressed_size_l8,
            ratio_l8,
            compressed_size_l9,
            ratio_l9,
        });
    }

    std.debug.print("\nPASS\n", .{});
}

// Test HC compression with LZ4F frame format
fn testHCWithFrameFormat(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: HC with LZ4F frame format... ", .{});

    const lz4f = @import("lz4f.zig");

    const text =
        \\The quick brown fox jumps over the lazy dog.
        \\The quick brown fox jumps over the lazy dog.
        \\Repeated text should compress well with HC.
        \\Repeated text should compress well with HC.
    ;

    // Test different compression levels
    const levels = [_]i32{ 0, 2, 9 };

    for (levels) |level| {
        const prefs = lz4f.Preferences{
            .compressionLevel = level,
            .frameInfo = .{
                .blockSizeID = .max64KB,
                .contentChecksumFlag = .enabled,
            },
        };

        const compressed = try allocator.alloc(u8, lz4f.compressFrameBound(text.len, prefs));
        defer allocator.free(compressed);

        const compressed_size = try lz4f.compressFrame(allocator, text, compressed, prefs);
        const ratio = @as(f64, @floatFromInt(text.len)) / @as(f64, @floatFromInt(compressed_size));

        try testing.expect(compressed_size > 0);
        try testing.expect(compressed_size < text.len + 100); // Should compress well

        // Decompress and verify
        const decompressed = try allocator.alloc(u8, text.len * 2);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4f.decompressFrame(allocator, compressed[0..compressed_size], decompressed);
        try testing.expectEqual(text.len, decompressed_size);
        try testing.expectEqualSlices(u8, text, decompressed[0..decompressed_size]);

        std.debug.print("\n  Level {}: {} -> {} bytes (ratio: {d:.2}x)", .{ level, text.len, compressed_size, ratio });
    }

    std.debug.print("\nPASS\n", .{});
}

fn testOptimalParser(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Optimal parser (levels 10-12)... ", .{});

    // Create data with overlapping matches - optimal parser should find better sequences
    var data = try allocator.alloc(u8, 500);
    defer allocator.free(data);

    // Create a pattern with multiple match opportunities
    // "ABCDABCDABCDXYZXYZXYZPQRPQRPQR..."
    var pos: usize = 0;
    while (pos < data.len) {
        const patterns = [_][]const u8{ "ABCD", "XYZ", "PQR", "123", "abc" };
        for (patterns) |pattern| {
            for (pattern) |byte| {
                if (pos >= data.len) break;
                data[pos] = byte;
                pos += 1;
            }
            for (pattern) |byte| {
                if (pos >= data.len) break;
                data[pos] = byte;
                pos += 1;
            }
            for (pattern) |byte| {
                if (pos >= data.len) break;
                data[pos] = byte;
                pos += 1;
            }
        }
    }

    const compressed9 = try allocator.alloc(u8, lz4hc.compressBound(data.len));
    defer allocator.free(compressed9);
    const compressed10 = try allocator.alloc(u8, lz4hc.compressBound(data.len));
    defer allocator.free(compressed10);
    const compressed11 = try allocator.alloc(u8, lz4hc.compressBound(data.len));
    defer allocator.free(compressed11);
    const compressed12 = try allocator.alloc(u8, lz4hc.compressBound(data.len));
    defer allocator.free(compressed12);

    // Compress with level 9 (hash chain) as baseline
    const size9 = try lz4hc.compressHC(data, compressed9, 9);

    // Compress with levels 10-12 (optimal parser)
    const size10 = try lz4hc.compressHC(data, compressed10, 10);
    const size11 = try lz4hc.compressHC(data, compressed11, 11);
    const size12 = try lz4hc.compressHC(data, compressed12, 12);

    // Optimal parser should achieve same or better compression
    try testing.expect(size10 <= size9);
    try testing.expect(size11 <= size10);
    try testing.expect(size12 <= size11);

    // Test round-trip decompression for all levels
    const decompressed = try allocator.alloc(u8, data.len);
    defer allocator.free(decompressed);

    const decompressed_size10 = try lz4.decompressSafe(compressed10[0..size10], decompressed);
    try testing.expectEqual(data.len, decompressed_size10);
    try testing.expectEqualSlices(u8, data, decompressed[0..decompressed_size10]);

    const decompressed_size11 = try lz4.decompressSafe(compressed11[0..size11], decompressed);
    try testing.expectEqual(data.len, decompressed_size11);
    try testing.expectEqualSlices(u8, data, decompressed[0..decompressed_size11]);

    const decompressed_size12 = try lz4.decompressSafe(compressed12[0..size12], decompressed);
    try testing.expectEqual(data.len, decompressed_size12);
    try testing.expectEqualSlices(u8, data, decompressed[0..decompressed_size12]);

    const ratio9 = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(size9));
    const ratio10 = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(size10));
    const ratio11 = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(size11));
    const ratio12 = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(size12));

    std.debug.print("\n  Level 9 (HC):   {} -> {} bytes (ratio: {d:.2}x)", .{ data.len, size9, ratio9 });
    std.debug.print("\n  Level 10 (OPT): {} -> {} bytes (ratio: {d:.2}x)", .{ data.len, size10, ratio10 });
    std.debug.print("\n  Level 11 (OPT): {} -> {} bytes (ratio: {d:.2}x)", .{ data.len, size11, ratio11 });
    std.debug.print("\n  Level 12 (OPT): {} -> {} bytes (ratio: {d:.2}x)", .{ data.len, size12, ratio12 });

    // Test with complex text data
    const complex_text = "The quick brown fox jumps over the lazy dog. " ++
        "The quick brown fox jumps over the lazy dog. " ++
        "Pack my box with five dozen liquor jugs. " ++
        "Pack my box with five dozen liquor jugs. " ++
        "How vexingly quick daft zebras jump! " ++
        "How vexingly quick daft zebras jump! ";

    const text_compressed9 = try allocator.alloc(u8, lz4hc.compressBound(complex_text.len));
    defer allocator.free(text_compressed9);
    const text_compressed12 = try allocator.alloc(u8, lz4hc.compressBound(complex_text.len));
    defer allocator.free(text_compressed12);

    const text_size9 = try lz4hc.compressHC(complex_text, text_compressed9, 9);
    const text_size12 = try lz4hc.compressHC(complex_text, text_compressed12, 12);

    // Verify decompression
    const text_decompressed = try allocator.alloc(u8, complex_text.len);
    defer allocator.free(text_decompressed);

    const text_decompressed_size = try lz4.decompressSafe(text_compressed12[0..text_size12], text_decompressed);
    try testing.expectEqual(complex_text.len, text_decompressed_size);
    try testing.expectEqualSlices(u8, complex_text, text_decompressed[0..text_decompressed_size]);

    const text_ratio9 = @as(f64, @floatFromInt(complex_text.len)) / @as(f64, @floatFromInt(text_size9));
    const text_ratio12 = @as(f64, @floatFromInt(complex_text.len)) / @as(f64, @floatFromInt(text_size12));

    std.debug.print("\n  Text L9:  {} -> {} bytes (ratio: {d:.2}x)", .{ complex_text.len, text_size9, text_ratio9 });
    std.debug.print("\n  Text L12: {} -> {} bytes (ratio: {d:.2}x)", .{ complex_text.len, text_size12, text_ratio12 });

    std.debug.print("\nPASS\n", .{});
}
