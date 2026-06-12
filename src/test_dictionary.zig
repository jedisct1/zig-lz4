//! Tests for dictionary decompression.
const std = @import("std");
const lz4 = @import("lz4.zig");
const testing = std.testing;

test "dictionary decompression - stateless" {
    const allocator = testing.allocator;

    const dict = "The quick brown fox jumps over the lazy dog. ";
    const original = "The quick brown fox";

    var stream = lz4.Stream.init();
    _ = stream.loadDict(dict);

    const max_compressed = lz4.compressBound(original.len);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try stream.compressFastContinue(original, compressed, 1);

    const decompressed = try allocator.alloc(u8, original.len);
    defer allocator.free(decompressed);

    const decompressed_size = try lz4.decompressSafeUsingDict(
        compressed[0..compressed_size],
        decompressed,
        dict,
    );

    try testing.expectEqual(original.len, decompressed_size);
    try testing.expectEqualStrings(original, decompressed[0..decompressed_size]);
}

test "dictionary decompression - streaming" {
    const allocator = testing.allocator;

    const dict = "Common prefix data that will be referenced. ";

    var stream_enc = lz4.Stream.init();
    _ = stream_enc.loadDict(dict);

    const block1 = "Common prefix";
    const block2 = "data that";

    const max_compressed = lz4.compressBound(100);
    const compressed1 = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed1);
    const compressed2 = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed2);

    const comp_size1 = try stream_enc.compressFastContinue(block1, compressed1, 1);
    const comp_size2 = try stream_enc.compressFastContinue(block2, compressed2, 1);

    var stream_dec = lz4.StreamDecode.init();
    stream_dec.setStreamDecode(dict);

    const decompressed1 = try allocator.alloc(u8, block1.len);
    defer allocator.free(decompressed1);
    const decompressed2 = try allocator.alloc(u8, block2.len);
    defer allocator.free(decompressed2);

    const decomp_size1 = try stream_dec.decompressSafeContinue(compressed1[0..comp_size1], decompressed1);
    const decomp_size2 = try stream_dec.decompressSafeContinue(compressed2[0..comp_size2], decompressed2);

    try testing.expectEqual(block1.len, decomp_size1);
    try testing.expectEqual(block2.len, decomp_size2);
    try testing.expectEqualStrings(block1, decompressed1[0..decomp_size1]);
    try testing.expectEqualStrings(block2, decompressed2[0..decomp_size2]);
}

test "compressDestSize - fits exactly" {
    const allocator = testing.allocator;

    const original = &@as([200]u8, @splat('A'));

    // Destination is smaller than the full compressed size.
    const dst_size = 50;
    const dst = try allocator.alloc(u8, dst_size);
    defer allocator.free(dst);

    var src_size: usize = original.len;
    const compressed_size = try lz4.compressDestSize(original, dst, &src_size);

    try testing.expect(src_size > 0);
    try testing.expect(src_size <= original.len);
    try testing.expect(compressed_size <= dst_size);

    const decompressed = try allocator.alloc(u8, src_size);
    defer allocator.free(decompressed);

    const decomp_size = try lz4.decompressSafe(dst[0..compressed_size], decompressed);
    try testing.expectEqual(src_size, decomp_size);
    try testing.expectEqualStrings(original[0..src_size], decompressed[0..decomp_size]);
}

test "partial decompression" {
    const allocator = testing.allocator;

    const original = "Hello, World! This is a longer test string for partial decompression.";

    const max_compressed = lz4.compressBound(original.len);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try lz4.compressDefault(original, compressed);

    const target_size = 20;
    const decompressed = try allocator.alloc(u8, original.len);
    defer allocator.free(decompressed);

    const decomp_size = try lz4.decompressSafePartial(
        compressed[0..compressed_size],
        decompressed,
        target_size,
    );

    try testing.expect(decomp_size <= target_size);
    try testing.expectEqualStrings(original[0..decomp_size], decompressed[0..decomp_size]);
}
