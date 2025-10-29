// Test suite for LZ4 HC Streaming API
// Tests streaming compression with dictionary continuation

const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

/// Test basic streaming compression and decompression
fn testBasicStreaming(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 1: Basic streaming compression\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const input = "Hello, World! This is a test of LZ4 HC streaming compression.";
    var compressed: [256]u8 = undefined;
    var decompressed: [256]u8 = undefined;

    // Compress with streaming API
    const compressedSize = try stream.compressContinue(input, &compressed);
    std.debug.print("  Input: {d} bytes\n", .{input.len});
    std.debug.print("  Compressed: {d} bytes\n", .{compressedSize});

    // Decompress
    const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], &decompressed);
    std.debug.print("  Decompressed: {d} bytes\n", .{decompressedSize});

    // Verify
    if (decompressedSize != input.len) {
        std.debug.print("  ERROR: Size mismatch! Expected {d}, got {d}\n", .{ input.len, decompressedSize });
        return error.TestFailed;
    }

    if (!std.mem.eql(u8, input, decompressed[0..decompressedSize])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Basic streaming test passed\n\n", .{});
}

/// Test compressing multiple contiguous blocks
fn testMultipleBlocks(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 2: Multiple contiguous blocks\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Allocate contiguous buffer
    const bufferSize = 1024;
    var buffer = try allocator.alloc(u8, bufferSize);
    defer allocator.free(buffer);

    // Fill buffer with patterns
    for (buffer, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    var compressed: [2048]u8 = undefined;
    var decompressed: [2048]u8 = undefined;
    var compressedOffset: usize = 0;
    var decompressedOffset: usize = 0;

    // Compress in 256-byte blocks
    const blockSize = 256;
    var i: usize = 0;
    while (i < bufferSize) : (i += blockSize) {
        const block = buffer[i .. i + blockSize];
        const size = try stream.compressContinue(block, compressed[compressedOffset..]);
        std.debug.print("  Block {d}: {d} → {d} bytes\n", .{ i / blockSize, blockSize, size });
        compressedOffset += size;

        // Decompress each block
        const decSize = try lz4.decompressSafe(compressed[compressedOffset - size .. compressedOffset], decompressed[decompressedOffset..]);
        decompressedOffset += decSize;
    }

    std.debug.print("  Total: {d} → {d} bytes\n", .{ bufferSize, compressedOffset });

    // Verify
    if (!std.mem.eql(u8, buffer, decompressed[0..decompressedOffset])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Multiple blocks test passed\n\n", .{});
}

/// Test compressing non-contiguous blocks (external dictionary)
fn testNonContiguousBlocks(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 3: Non-contiguous blocks\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Create separate buffers for each block
    const block1 = "The quick brown fox jumps over the lazy dog. ";
    const block2 = "The quick brown fox jumps over the lazy cat. "; // Similar to block1
    const block3 = "The quick brown fox jumps over the lazy bird. "; // Similar to block1 and block2

    var compressed: [512]u8 = undefined;
    var compressedOffset: usize = 0;

    // Compress block 1
    const size1 = try stream.compressContinue(block1, compressed[compressedOffset..]);
    std.debug.print("  Block 1: {d} → {d} bytes\n", .{ block1.len, size1 });
    compressedOffset += size1;

    // Compress block 2 (non-contiguous, will use external dict)
    const size2 = try stream.compressContinue(block2, compressed[compressedOffset..]);
    std.debug.print("  Block 2: {d} → {d} bytes (with dict)\n", .{ block2.len, size2 });
    compressedOffset += size2;

    // Compress block 3 (non-contiguous, will use external dict)
    const size3 = try stream.compressContinue(block3, compressed[compressedOffset..]);
    std.debug.print("  Block 3: {d} → {d} bytes (with dict)\n", .{ block3.len, size3 });
    compressedOffset += size3;

    // Decompress all blocks
    var decompressed: [512]u8 = undefined;
    var offset: usize = 0;

    const dec1 = try lz4.decompressSafe(compressed[0..size1], decompressed[offset..]);
    offset += dec1;

    const dec2 = try lz4.decompressSafe(compressed[size1 .. size1 + size2], decompressed[offset..]);
    offset += dec2;

    const dec3 = try lz4.decompressSafe(compressed[size1 + size2 .. compressedOffset], decompressed[offset..]);
    offset += dec3;

    // Verify
    const expected = block1 ++ block2 ++ block3;
    if (!std.mem.eql(u8, expected, decompressed[0..offset])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Non-contiguous blocks test passed\n\n", .{});
}

/// Test ring buffer pattern (similar to streamingHC_ringBuffer.c)
fn testRingBuffer(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 4: Ring buffer streaming\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    const messageMaxBytes = 256;
    const ringBufferBytes = 1024 * 2;

    var ringBuffer = try allocator.alloc(u8, ringBufferBytes);
    defer allocator.free(ringBuffer);

    // Generate test data
    var testData: [1024 * 4]u8 = undefined;
    for (&testData, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    var compressed: [8192]u8 = undefined;
    var decompressed: [8192]u8 = undefined;
    var compressedOffset: usize = 0;
    var decompressedOffset: usize = 0;
    var ringOffset: usize = 0;

    // Compress in chunks using ring buffer
    var srcOffset: usize = 0;
    while (srcOffset < testData.len) {
        const chunkSize = @min(messageMaxBytes, testData.len - srcOffset);
        const chunk = testData[srcOffset .. srcOffset + chunkSize];

        // Copy to ring buffer
        @memcpy(ringBuffer[ringOffset .. ringOffset + chunkSize], chunk);

        // Compress from ring buffer
        const size = try stream.compressContinue(
            ringBuffer[ringOffset .. ringOffset + chunkSize],
            compressed[compressedOffset..],
        );
        compressedOffset += size;

        // Decompress
        const decSize = try lz4.decompressSafe(compressed[compressedOffset - size .. compressedOffset], decompressed[decompressedOffset..]);
        decompressedOffset += decSize;

        ringOffset += chunkSize;

        // Wrap around ring buffer
        if (ringOffset >= ringBufferBytes - messageMaxBytes) {
            ringOffset = 0;
        }

        srcOffset += chunkSize;
    }

    std.debug.print("  Input: {d} bytes\n", .{testData.len});
    std.debug.print("  Compressed: {d} bytes\n", .{compressedOffset});
    std.debug.print("  Ratio: {d:.2}x\n", .{@as(f64, @floatFromInt(testData.len)) / @as(f64, @floatFromInt(compressedOffset))});

    // Verify
    if (!std.mem.eql(u8, &testData, decompressed[0..decompressedOffset])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Ring buffer test passed\n\n", .{});
}

/// Test loading external dictionary
fn testLoadDict(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 5: Load dictionary\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Create a dictionary with common patterns
    const dictionary = "The quick brown fox jumps over the lazy dog. " ** 10;

    // Load dictionary
    const dictSize = try stream.loadDict(dictionary);
    std.debug.print("  Loaded dictionary: {d} bytes\n", .{dictSize});

    // Compress data that uses dictionary patterns
    const input = "The quick brown fox jumps over the lazy cat. The quick brown fox jumps over the lazy bird.";
    var compressed: [256]u8 = undefined;
    var decompressed: [256]u8 = undefined;

    const compressedSize = try stream.compressContinue(input, &compressed);
    std.debug.print("  Input: {d} bytes\n", .{input.len});
    std.debug.print("  Compressed: {d} bytes (with dict)\n", .{compressedSize});

    // Decompress (note: decompression doesn't need the dictionary for this test)
    const decompressedSize = try lz4.decompressSafe(compressed[0..compressedSize], &decompressed);

    // Verify
    if (!std.mem.eql(u8, input, decompressed[0..decompressedSize])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Load dictionary test passed\n\n", .{});
}

/// Test saving dictionary
fn testSaveDict(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 6: Save dictionary\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Compress some data
    const input1 = "The quick brown fox jumps over the lazy dog. " ** 5;
    var compressed1: [512]u8 = undefined;
    _ = try stream.compressContinue(input1, &compressed1);

    // Save dictionary
    var savedDict: [64 * 1024]u8 = undefined;
    const dictSize = stream.saveDict(&savedDict);
    std.debug.print("  Saved dictionary: {d} bytes\n", .{dictSize});

    // Create new stream and load saved dictionary
    const stream2 = try lz4hc.StreamHC.create(allocator);
    defer stream2.destroy();

    _ = try stream2.loadDict(savedDict[0..dictSize]);

    // Compress similar data with loaded dictionary
    const input2 = "The quick brown fox jumps over the lazy cat.";
    var compressed2: [256]u8 = undefined;
    var decompressed2: [256]u8 = undefined;

    const compressedSize = try stream2.compressContinue(input2, &compressed2);
    std.debug.print("  Compressed with saved dict: {d} → {d} bytes\n", .{ input2.len, compressedSize });

    // Decompress
    const decompressedSize = try lz4.decompressSafe(compressed2[0..compressedSize], &decompressed2);

    // Verify
    if (!std.mem.eql(u8, input2, decompressed2[0..decompressedSize])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Save dictionary test passed\n\n", .{});
}

/// Test resetting stream
fn testResetStream(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 7: Reset stream\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Compress some data
    const input1 = "First batch of data to compress.";
    var compressed1: [128]u8 = undefined;
    const size1 = try stream.compressContinue(input1, &compressed1);
    std.debug.print("  First compression: {d} → {d} bytes\n", .{ input1.len, size1 });

    // Reset stream
    stream.reset(9);
    std.debug.print("  Stream reset\n", .{});

    // Compress new data (should not use previous data as dictionary)
    const input2 = "Second batch of data to compress.";
    var compressed2: [128]u8 = undefined;
    const size2 = try stream.compressContinue(input2, &compressed2);
    std.debug.print("  Second compression: {d} → {d} bytes\n", .{ input2.len, size2 });

    // Decompress both
    var decompressed1: [128]u8 = undefined;
    var decompressed2: [128]u8 = undefined;

    const dec1 = try lz4.decompressSafe(compressed1[0..size1], &decompressed1);
    const dec2 = try lz4.decompressSafe(compressed2[0..size2], &decompressed2);

    // Verify
    if (!std.mem.eql(u8, input1, decompressed1[0..dec1])) {
        std.debug.print("  ERROR: First data mismatch!\n", .{});
        return error.TestFailed;
    }

    if (!std.mem.eql(u8, input2, decompressed2[0..dec2])) {
        std.debug.print("  ERROR: Second data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Reset stream test passed\n\n", .{});
}

/// Test large streaming compression
fn testLargeStream(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 8: Large streaming compression\n", .{});

    const stream = try lz4hc.StreamHC.create(allocator);
    defer stream.destroy();

    // Create large buffer
    const totalSize = 1024 * 1024; // 1 MB
    var buffer = try allocator.alloc(u8, totalSize);
    defer allocator.free(buffer);

    // Fill with repetitive pattern
    for (buffer, 0..) |*byte, i| {
        byte.* = @truncate((i / 256) % 256);
    }

    var compressed = try allocator.alloc(u8, lz4hc.compressBound(totalSize));
    defer allocator.free(compressed);

    var decompressed = try allocator.alloc(u8, totalSize);
    defer allocator.free(decompressed);

    var compressedOffset: usize = 0;
    var decompressedOffset: usize = 0;

    // Compress in 64KB blocks
    const blockSize = 64 * 1024;
    var blocksCompressed: usize = 0;
    var i: usize = 0;
    while (i < totalSize) : (i += blockSize) {
        const end = @min(i + blockSize, totalSize);
        const block = buffer[i..end];
        const size = try stream.compressContinue(block, compressed[compressedOffset..]);
        compressedOffset += size;

        // Decompress
        const decSize = try lz4.decompressSafe(compressed[compressedOffset - size .. compressedOffset], decompressed[decompressedOffset..]);
        decompressedOffset += decSize;

        blocksCompressed += 1;
    }

    std.debug.print("  Input: {d} bytes in {d} blocks\n", .{ totalSize, blocksCompressed });
    std.debug.print("  Compressed: {d} bytes\n", .{compressedOffset});
    std.debug.print("  Ratio: {d:.2}x\n", .{@as(f64, @floatFromInt(totalSize)) / @as(f64, @floatFromInt(compressedOffset))});

    // Verify
    if (!std.mem.eql(u8, buffer, decompressed[0..decompressedOffset])) {
        std.debug.print("  ERROR: Data mismatch!\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Large stream test passed\n\n", .{});
}
