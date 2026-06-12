//! Test suite for the LZ4 HC streaming API: streaming compression with
//! dictionary continuation.
const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");
const testing = std.testing;

inline fn repeatString(comptime n: usize, comptime str: []const u8) []const u8 {
    const buf: [n][str.len]u8 = @splat(str[0..str.len].*);
    return @ptrCast(&buf);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    std.debug.print("\n=== LZ4 HC Streaming API Tests ===\n\n", .{});

    try testBasicStreaming(allocator);
    try testMultipleBlocks(allocator);
    try testNonContiguousBlocks(allocator);
    try testRingBuffer(allocator);
    try testLoadDict(allocator);
    try testSaveDict(allocator);
    try testResetStream(allocator);
    try testLargeStream(allocator);

    std.debug.print("\n=== All streaming tests passed! ===\n", .{});
}

fn testBasicStreaming(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 1: Basic streaming compression\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const input = "Hello, World! This is a test of LZ4 HC streaming compression.";
    var compressed: [256]u8 = undefined;
    var decompressed: [256]u8 = undefined;

    const compressed_size = try stream.compressContinue(input, &compressed);
    std.debug.print("  Input: {d} bytes\n", .{input.len});
    std.debug.print("  Compressed: {d} bytes\n", .{compressed_size});

    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], &decompressed);
    std.debug.print("  Decompressed: {d} bytes\n", .{decompressed_size});

    try testing.expectEqual(input.len, decompressed_size);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    std.debug.print("  Basic streaming test passed\n\n", .{});
}

fn testMultipleBlocks(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 2: Multiple contiguous blocks\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const buffer_size = 1024;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    for (buffer, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    var compressed: [2048]u8 = undefined;
    var decompressed: [2048]u8 = undefined;
    var compressed_offset: usize = 0;
    var decompressed_offset: usize = 0;

    const block_size = 256;
    var i: usize = 0;
    while (i < buffer_size) : (i += block_size) {
        const block = buffer[i .. i + block_size];
        const size = try stream.compressContinue(block, compressed[compressed_offset..]);
        std.debug.print("  Block {d}: {d} -> {d} bytes\n", .{ i / block_size, block_size, size });
        compressed_offset += size;

        const dec_size = try lz4.decompressSafe(compressed[compressed_offset - size .. compressed_offset], decompressed[decompressed_offset..]);
        decompressed_offset += dec_size;
    }

    std.debug.print("  Total: {d} -> {d} bytes\n", .{ buffer_size, compressed_offset });

    try testing.expectEqualSlices(u8, buffer, decompressed[0..decompressed_offset]);

    std.debug.print("  Multiple blocks test passed\n\n", .{});
}

fn testNonContiguousBlocks(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 3: Non-contiguous blocks\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const block1 = "The quick brown fox jumps over the lazy dog. ";
    const block2 = "The quick brown fox jumps over the lazy cat. ";
    const block3 = "The quick brown fox jumps over the lazy bird. ";

    var compressed: [512]u8 = undefined;
    var compressed_offset: usize = 0;

    const size1 = try stream.compressContinue(block1, compressed[compressed_offset..]);
    std.debug.print("  Block 1: {d} -> {d} bytes\n", .{ block1.len, size1 });
    compressed_offset += size1;

    const size2 = try stream.compressContinue(block2, compressed[compressed_offset..]);
    std.debug.print("  Block 2: {d} -> {d} bytes (with dict)\n", .{ block2.len, size2 });
    compressed_offset += size2;

    const size3 = try stream.compressContinue(block3, compressed[compressed_offset..]);
    std.debug.print("  Block 3: {d} -> {d} bytes (with dict)\n", .{ block3.len, size3 });
    compressed_offset += size3;

    var decompressed: [512]u8 = undefined;
    var offset: usize = 0;

    const dec1 = try lz4.decompressSafe(compressed[0..size1], decompressed[offset..]);
    offset += dec1;

    const dec2 = try lz4.decompressSafe(compressed[size1 .. size1 + size2], decompressed[offset..]);
    offset += dec2;

    const dec3 = try lz4.decompressSafe(compressed[size1 + size2 .. compressed_offset], decompressed[offset..]);
    offset += dec3;

    const expected = block1 ++ block2 ++ block3;
    try testing.expectEqualSlices(u8, expected, decompressed[0..offset]);

    std.debug.print("  Non-contiguous blocks test passed\n\n", .{});
}

fn testRingBuffer(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 4: Ring buffer streaming\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const message_max_bytes = 256;
    const ring_buffer_bytes = 1024 * 2;

    const ring_buffer = try allocator.alloc(u8, ring_buffer_bytes);
    defer allocator.free(ring_buffer);

    var test_data: [1024 * 4]u8 = undefined;
    for (&test_data, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    var compressed: [8192]u8 = undefined;
    var decompressed: [8192]u8 = undefined;
    var compressed_offset: usize = 0;
    var decompressed_offset: usize = 0;
    var ring_offset: usize = 0;

    var src_offset: usize = 0;
    while (src_offset < test_data.len) {
        const chunk_size = @min(message_max_bytes, test_data.len - src_offset);
        const chunk = test_data[src_offset .. src_offset + chunk_size];

        @memcpy(ring_buffer[ring_offset .. ring_offset + chunk_size], chunk);

        const size = try stream.compressContinue(
            ring_buffer[ring_offset .. ring_offset + chunk_size],
            compressed[compressed_offset..],
        );
        compressed_offset += size;

        const dec_size = try lz4.decompressSafe(compressed[compressed_offset - size .. compressed_offset], decompressed[decompressed_offset..]);
        decompressed_offset += dec_size;

        ring_offset += chunk_size;
        if (ring_offset >= ring_buffer_bytes - message_max_bytes) {
            ring_offset = 0;
        }

        src_offset += chunk_size;
    }

    std.debug.print("  Input: {d} bytes\n", .{test_data.len});
    std.debug.print("  Compressed: {d} bytes\n", .{compressed_offset});
    std.debug.print("  Ratio: {d:.2}x\n", .{@as(f64, @floatFromInt(test_data.len)) / @as(f64, @floatFromInt(compressed_offset))});

    try testing.expectEqualSlices(u8, &test_data, decompressed[0..decompressed_offset]);

    std.debug.print("  Ring buffer test passed\n\n", .{});
}

fn testLoadDict(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 5: Load dictionary\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const dictionary = repeatString(10, "The quick brown fox jumps over the lazy dog. ");

    const dict_size = try stream.loadDict(dictionary);
    std.debug.print("  Loaded dictionary: {d} bytes\n", .{dict_size});

    const input = "The quick brown fox jumps over the lazy cat. The quick brown fox jumps over the lazy bird.";
    var compressed: [256]u8 = undefined;
    var decompressed: [256]u8 = undefined;

    const compressed_size = try stream.compressContinue(input, &compressed);
    std.debug.print("  Input: {d} bytes\n", .{input.len});
    std.debug.print("  Compressed: {d} bytes (with dict)\n", .{compressed_size});

    // Decompression does not need the dictionary for this input.
    const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], &decompressed);

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);

    std.debug.print("  Load dictionary test passed\n\n", .{});
}

fn testSaveDict(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 6: Save dictionary\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const input1 = repeatString(5, "The quick brown fox jumps over the lazy dog. ");

    var compressed1: [512]u8 = undefined;
    _ = try stream.compressContinue(input1, &compressed1);

    var saved_dict: [64 * 1024]u8 = undefined;
    const dict_size = stream.saveDict(&saved_dict);
    std.debug.print("  Saved dictionary: {d} bytes\n", .{dict_size});

    const stream2 = try lz4hc.StreamHC.create(allocator);
    defer stream2.destroy();

    _ = try stream2.loadDict(saved_dict[0..dict_size]);

    const input2 = "The quick brown fox jumps over the lazy cat.";
    var compressed2: [256]u8 = undefined;
    var decompressed2: [256]u8 = undefined;

    const compressed_size = try stream2.compressContinue(input2, &compressed2);
    std.debug.print("  Compressed with saved dict: {d} -> {d} bytes\n", .{ input2.len, compressed_size });

    const decompressed_size = try lz4.decompressSafe(compressed2[0..compressed_size], &decompressed2);

    try testing.expectEqualSlices(u8, input2, decompressed2[0..decompressed_size]);

    std.debug.print("  Save dictionary test passed\n\n", .{});
}

fn testResetStream(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 7: Reset stream\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const input1 = "First batch of data to compress.";
    var compressed1: [128]u8 = undefined;
    const size1 = try stream.compressContinue(input1, &compressed1);
    std.debug.print("  First compression: {d} -> {d} bytes\n", .{ input1.len, size1 });

    stream.reset(9);
    std.debug.print("  Stream reset\n", .{});

    // After reset, compression must not use previous data as dictionary.
    const input2 = "Second batch of data to compress.";
    var compressed2: [128]u8 = undefined;
    const size2 = try stream.compressContinue(input2, &compressed2);
    std.debug.print("  Second compression: {d} -> {d} bytes\n", .{ input2.len, size2 });

    var decompressed1: [128]u8 = undefined;
    var decompressed2: [128]u8 = undefined;

    const dec1 = try lz4.decompressSafe(compressed1[0..size1], &decompressed1);
    const dec2 = try lz4.decompressSafe(compressed2[0..size2], &decompressed2);

    try testing.expectEqualSlices(u8, input1, decompressed1[0..dec1]);
    try testing.expectEqualSlices(u8, input2, decompressed2[0..dec2]);

    std.debug.print("  Reset stream test passed\n\n", .{});
}

fn testLargeStream(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 8: Large streaming compression\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const total_size = 1024 * 1024;
    const buffer = try allocator.alloc(u8, total_size);
    defer allocator.free(buffer);

    for (buffer, 0..) |*byte, i| {
        byte.* = @truncate((i / 256) % 256);
    }

    const compressed = try allocator.alloc(u8, lz4hc.compressBound(total_size));
    defer allocator.free(compressed);

    const decompressed = try allocator.alloc(u8, total_size);
    defer allocator.free(decompressed);

    var compressed_offset: usize = 0;
    var decompressed_offset: usize = 0;

    const block_size = 64 * 1024;
    var blocks_compressed: usize = 0;
    var i: usize = 0;
    while (i < total_size) : (i += block_size) {
        const end = @min(i + block_size, total_size);
        const block = buffer[i..end];
        const size = try stream.compressContinue(block, compressed[compressed_offset..]);
        compressed_offset += size;

        const dec_size = try lz4.decompressSafe(compressed[compressed_offset - size .. compressed_offset], decompressed[decompressed_offset..]);
        decompressed_offset += dec_size;

        blocks_compressed += 1;
    }

    std.debug.print("  Input: {d} bytes in {d} blocks\n", .{ total_size, blocks_compressed });
    std.debug.print("  Compressed: {d} bytes\n", .{compressed_offset});
    std.debug.print("  Ratio: {d:.2}x\n", .{@as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(compressed_offset))});

    try testing.expectEqualSlices(u8, buffer, decompressed[0..decompressed_offset]);

    std.debug.print("  Large stream test passed\n\n", .{});
}
