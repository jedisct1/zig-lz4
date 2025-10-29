// Test suite for dictionary decompression
const std = @import("std");
const lz4 = @import("lz4.zig");

test "dictionary decompression - stateless" {
    const allocator = std.testing.allocator;

    // Prepare dictionary (some common text)
    const dict = "The quick brown fox jumps over the lazy dog. ";

    // Original data that references the dictionary
    const original = "The quick brown fox";

    // Compress with dictionary using streaming
    var stream = lz4.Stream.init();
    _ = stream.loadDict(dict);

    const maxCompressed = lz4.compressBound(original.len);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try stream.compressFastContinue(original, compressed, 1);

    // Decompress with dictionary (stateless function)
    const decompressed = try allocator.alloc(u8, original.len);
    defer allocator.free(decompressed);

    const decompressedSize = try lz4.decompressSafeUsingDict(
        compressed[0..compressedSize],
        decompressed,
        dict,
    );

    try std.testing.expectEqual(original.len, decompressedSize);
    try std.testing.expectEqualStrings(original, decompressed[0..decompressedSize]);
}

test "dictionary decompression - streaming" {
    const allocator = std.testing.allocator;

    // Prepare dictionary
    const dict = "Common prefix data that will be referenced. ";

    // Compress multiple blocks with dictionary
    var streamEnc = lz4.Stream.init();
    _ = streamEnc.loadDict(dict);

    const block1 = "Common prefix";
    const block2 = "data that";

    const maxCompressed = lz4.compressBound(100);
    const compressed1 = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed1);
    const compressed2 = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed2);

    const compSize1 = try streamEnc.compressFastContinue(block1, compressed1, 1);
    const compSize2 = try streamEnc.compressFastContinue(block2, compressed2, 1);

    // Decompress using streaming decoder
    var streamDec = lz4.StreamDecode.init();
    streamDec.setStreamDecode(dict);

    const decompressed1 = try allocator.alloc(u8, block1.len);
    defer allocator.free(decompressed1);
    const decompressed2 = try allocator.alloc(u8, block2.len);
    defer allocator.free(decompressed2);

    const decompSize1 = try streamDec.decompressSafeContinue(compressed1[0..compSize1], decompressed1);
    const decompSize2 = try streamDec.decompressSafeContinue(compressed2[0..compSize2], decompressed2);

    try std.testing.expectEqual(block1.len, decompSize1);
    try std.testing.expectEqual(block2.len, decompSize2);
    try std.testing.expectEqualStrings(block1, decompressed1[0..decompSize1]);
    try std.testing.expectEqualStrings(block2, decompressed2[0..decompSize2]);
}

test "compressDestSize - fits exactly" {
    const allocator = std.testing.allocator;

    const original = "AAAAAAAAAA" ** 20; // 200 bytes

    // Destination smaller than full compressed size
    const dstSize = 50;
    const dst = try allocator.alloc(u8, dstSize);
    defer allocator.free(dst);

    var srcSize: usize = original.len;
    const compressedSize = try lz4.compressDestSize(original, dst, &srcSize);

    // Should compress some portion of input
    try std.testing.expect(srcSize > 0);
    try std.testing.expect(srcSize <= original.len);
    try std.testing.expect(compressedSize <= dstSize);

    // Verify decompression works
    const decompressed = try allocator.alloc(u8, srcSize);
    defer allocator.free(decompressed);

    const decompSize = try lz4.decompressSafe(dst[0..compressedSize], decompressed);
    try std.testing.expectEqual(srcSize, decompSize);
    try std.testing.expectEqualStrings(original[0..srcSize], decompressed[0..decompSize]);
}

test "partial decompression" {
    const allocator = std.testing.allocator;

    const original = "Hello, World! This is a longer test string for partial decompression.";

    const maxCompressed = lz4.compressBound(original.len);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try lz4.compressDefault(original, compressed);

    // Decompress only first 20 bytes
    const targetSize = 20;
    const decompressed = try allocator.alloc(u8, original.len);
    defer allocator.free(decompressed);

    const decompSize = try lz4.decompressSafePartial(
        compressed[0..compressedSize],
        decompressed,
        targetSize,
    );

    try std.testing.expect(decompSize <= targetSize);
    try std.testing.expectEqualStrings(original[0..decompSize], decompressed[0..decompSize]);
}
