//! Tests for the LZ4 streaming APIs.
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
    // Small inputs may not compress well, so the compressed size might be >= input size.

    var decompressed: [200]u8 = undefined;
    const decomp_size = try lz4.decompressSafe(compressed[0..size], &decompressed);
    try testing.expectEqual(input.len, decomp_size);
    try testing.expectEqualStrings(input, decompressed[0..decomp_size]);
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

    var decompressed1: [100]u8 = undefined;
    var decompressed2: [100]u8 = undefined;
    var decompressed3: [100]u8 = undefined;

    const d_size1 = try lz4.decompressSafe(compressed1[0..size1], &decompressed1);
    const d_size2 = try lz4.decompressSafe(compressed2[0..size2], &decompressed2);
    const d_size3 = try lz4.decompressSafe(compressed3[0..size3], &decompressed3);

    try testing.expectEqualStrings(block1, decompressed1[0..d_size1]);
    try testing.expectEqualStrings(block2, decompressed2[0..d_size2]);
    try testing.expectEqualStrings(block3, decompressed3[0..d_size3]);
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

    var decompressed: [200]u8 = undefined;
    const d_size = try lz4.decompressSafeUsingDict(compressed[0..size], &decompressed, dict);
    try testing.expectEqualStrings(input, decompressed[0..d_size]);
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
    const d_size = try lz4.decompressSafe(compressed[0..size], &decompressed);
    try testing.expectEqualStrings(input, decompressed[0..d_size]);
}

test "streaming decompression - basic" {
    const allocator = testing.allocator;

    const input = "Data to compress and then decompress using streaming API";
    var compressed: [200]u8 = undefined;
    const c_size = try lz4.compressDefault(input, &compressed);

    var stream_decode = try lz4.createStreamDecode(allocator);
    defer lz4.freeStreamDecode(stream_decode);

    var decompressed: [200]u8 = undefined;
    const d_size = try stream_decode.decompressSafeContinue(compressed[0..c_size], &decompressed);

    try testing.expectEqual(input.len, d_size);
    try testing.expectEqualStrings(input, decompressed[0..d_size]);
}

test "advanced - partial decompression" {
    const input = "This is a longer string that we will partially decompress to test the partial decompression feature.";
    var compressed: [200]u8 = undefined;
    const c_size = try lz4.compressDefault(input, &compressed);

    var decompressed: [200]u8 = undefined;
    const d_size = try lz4.decompressSafePartial(compressed[0..c_size], &decompressed, 20);

    try testing.expect(d_size <= 20);
    try testing.expect(d_size > 0);
    try testing.expectEqualStrings(input[0..d_size], decompressed[0..d_size]);
}

test "advanced - external state compression" {
    const state_size = lz4.sizeofState();
    var state_buffer: [@sizeOf(lz4.HashTable)]u8 align(@alignOf(lz4.HashTable)) = undefined;

    const input = "Test compression with external state buffer";
    var compressed: [200]u8 = undefined;
    const c_size = try lz4.compressFastExtState(&state_buffer, input, &compressed, 1);

    try testing.expect(c_size > 0);
    try testing.expect(state_size == @sizeOf(lz4.HashTable));

    var decompressed: [200]u8 = undefined;
    const d_size = try lz4.decompressSafe(compressed[0..c_size], &decompressed);
    try testing.expectEqualStrings(input, decompressed[0..d_size]);
}

test "version API" {
    const version_num = lz4.versionNumber();
    try testing.expectEqual(@as(u32, 11000), version_num);

    const version_str = lz4.versionString();
    try testing.expectEqualStrings("1.10.0", version_str);
}

test "ring buffer size calculation" {
    const size1 = lz4.decoderRingBufferSize(64 * 1024);
    try testing.expect(size1 > 64 * 1024);

    const size2 = lz4.decoderRingBufferSize(0);
    try testing.expectEqual(@as(usize, 0), size2);
}
