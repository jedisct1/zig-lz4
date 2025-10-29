//! Simple test for LZ4 HC + Frame format integration

const std = @import("std");
const lz4f = @import("lz4f.zig");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\nLZ4F + HC Integration Test\n", .{});
    std.debug.print("===========================\n\n", .{});

    // Test 1: Basic HC compression
    std.debug.print("Test 1: Basic HC compression\n", .{});

    const input = "Hello, World! " ** 10;

    const prefs_hc = lz4f.Preferences{ .compressionLevel = 9 };
    const maxCompressed = lz4f.compressFrameBound(input.len, prefs_hc);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const size_hc = try lz4f.compressFrame(allocator, input, compressed, prefs_hc);
    std.debug.print("  Compressed: {} bytes\n", .{size_hc});

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const desize_hc = try lz4f.decompressFrame(
        allocator,
        compressed[0..size_hc],
        decompressed,
    );

    if (desize_hc != input.len) {
        std.debug.print("  ✗ FAIL: Size mismatch\n", .{});
        return error.TestFailed;
    }

    if (!std.mem.eql(u8, input, decompressed[0..desize_hc])) {
        std.debug.print("  ✗ FAIL: Data mismatch\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ PASS\n\n", .{});

    std.debug.print("✓ All tests passed!\n\n", .{});
}
