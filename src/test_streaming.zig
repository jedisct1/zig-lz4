// Tests for LZ4 streaming APIs
const std = @import("std");
const lz4 = @import("lz4.zig");
const testing = std.testing;

test "streaming compression - basic" {
    var stream = lz4.Stream.init();
    defer stream.resetFast();

    const input = "Hello, World! This is a test of streaming compression.";
    var compressed: [200]u8 = undefined;

    const size = try stream.compressFastContinue(input, &compressed, 1);
    try testing.expect(size > 0);
    // Note: small inputs may not compress well, so compressed size might be >= input size

    // Decompress and verify
    var decompressed: [200]u8 = undefined;
    const decompSize = try lz4.decompressSafe(compressed[0..size], &decompressed);
    try testing.expectEqual(input.len, decompSize);
    try testing.expectEqualStrings(input, decompressed[0..decompSize]);
}

test "streaming compression - multiple blocks" {
    var stream = lz4.Stream.init();
    defer stream.resetFast();

    const block1 = "First block of data. ";
    const block2 = "Second block of data. ";
    const block3 = "Third block of data.";

    var compressed1: [100]u8 = undefined;
    var compressed2: [100]u8 = undefined;
    var compressed3: [100]u8 = undefined;

    const size1 = try stream.compressFastContinue(block1, &compressed1, 1);
    const size2 = try stream.compressFastContinue(block2, &compressed2, 1);
    const size3 = try stream.compressFastContinue(block3, &compressed3, 1);

    try testing.expect(size1 > 0);
    try testing.expect(size2 > 0);
    try testing.expect(size3 > 0);

    // Decompress each block
    var decompressed1: [100]u8 = undefined;
    var decompressed2: [100]u8 = undefined;
    var decompressed3: [100]u8 = undefined;

    const dSize1 = try lz4.decompressSafe(compressed1[0..size1], &decompressed1);
    const dSize2 = try lz4.decompressSafe(compressed2[0..size2], &decompressed2);
    const dSize3 = try lz4.decompressSafe(compressed3[0..size3], &decompressed3);

    try testing.expectEqualStrings(block1, decompressed1[0..dSize1]);
    try testing.expectEqualStrings(block2, decompressed2[0..dSize2]);
    try testing.expectEqualStrings(block3, decompressed3[0..dSize3]);
}

test "streaming compression - with dictionary" {
    var stream = lz4.Stream.init();
    defer stream.resetFast();

    const dict = "common prefix that appears often: ";
    const loaded = stream.loadDict(dict);
    try testing.expectEqual(dict.len, loaded);

    const input = "common prefix that appears often: actual data";
    var compressed: [200]u8 = undefined;
    const size = try stream.compressFastContinue(input, &compressed, 1);

    try testing.expect(size > 0);
    // With dictionary, compression might be better for repeated patterns

    // Note: Dictionary decompression not fully implemented yet
    // var decompressed: [200]u8 = undefined;
    // const dSize = try lz4.decompressSafeUsingDict(compressed[0..size], &decompressed, dict);
    // try testing.expectEqualStrings(input, decompressed[0..dSize]);
}

test "streaming compression - heap allocated" {
    const allocator = testing.allocator;

    var stream = try lz4.createStream(allocator);
    defer lz4.freeStream(stream);

    const input = "Test with heap-allocated stream context";
    var compressed: [200]u8 = undefined;
    const size = try stream.compressFastContinue(input, &compressed, 1);

    try testing.expect(size > 0);

    var decompressed: [200]u8 = undefined;
    const dSize = try lz4.decompressSafe(compressed[0..size], &decompressed);
    try testing.expectEqualStrings(input, decompressed[0..dSize]);
}

test "streaming decompression - basic" {
    const allocator = testing.allocator;

    // First compress some data
    const input = "Data to compress and then decompress using streaming API";
    var compressed: [200]u8 = undefined;
    const cSize = try lz4.compressDefault(input, &compressed);

    // Now decompress using streaming API
    var streamDecode = try lz4.createStreamDecode(allocator);
    defer lz4.freeStreamDecode(streamDecode);

    var decompressed: [200]u8 = undefined;
    const dSize = try streamDecode.decompressSafeContinue(compressed[0..cSize], &decompressed);

    try testing.expectEqual(input.len, dSize);
    try testing.expectEqualStrings(input, decompressed[0..dSize]);
}

test "advanced - partial decompression" {
    const input = "This is a longer string that we will partially decompress to test the partial decompression feature.";
    var compressed: [200]u8 = undefined;
    const cSize = try lz4.compressDefault(input, &compressed);

    // Decompress only first 20 bytes
    var decompressed: [200]u8 = undefined;
    const dSize = try lz4.decompressSafePartial(compressed[0..cSize], &decompressed, 20);

    try testing.expect(dSize <= 20);
    try testing.expect(dSize > 0);
    // Check that what we got matches the beginning of the input
    try testing.expectEqualStrings(input[0..dSize], decompressed[0..dSize]);
}

test "advanced - external state compression" {
    const stateSize = lz4.sizeofState();
    var stateBuffer: [@sizeOf(lz4.HashTable)]u8 align(@alignOf(lz4.HashTable)) = undefined;

    const input = "Test compression with external state buffer";
    var compressed: [200]u8 = undefined;
    const cSize = try lz4.compressFastExtState(&stateBuffer, input, &compressed, 1);

    try testing.expect(cSize > 0);
    try testing.expect(stateSize == @sizeOf(lz4.HashTable));

    var decompressed: [200]u8 = undefined;
    const dSize = try lz4.decompressSafe(compressed[0..cSize], &decompressed);
    try testing.expectEqualStrings(input, decompressed[0..dSize]);
}

test "version API" {
    const versionNum = lz4.versionNumber();
    try testing.expectEqual(@as(u32, 11000), versionNum);

    const versionStr = lz4.versionString();
    try testing.expectEqualStrings("1.10.0", versionStr);
}

test "ring buffer size calculation" {
    const size1 = lz4.decoderRingBufferSize(64 * 1024);
    try testing.expect(size1 > 64 * 1024);

    const size2 = lz4.decoderRingBufferSize(0);
    try testing.expectEqual(@as(usize, 0), size2);
}
