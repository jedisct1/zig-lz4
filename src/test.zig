const std = @import("std");
const lz4 = @import("lz4.zig");

fn fail(stdout: *std.Io.Writer, name: []const u8, reason: []const u8) error{ TestFailed, WriteFailed } {
    stdout.print("{s}... FAIL ({s})\n", .{ name, reason }) catch return error.WriteFailed;
    stdout.flush() catch return error.WriteFailed;
    return error.TestFailed;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("LZ4 Zig Implementation - Test Suite\n\n", .{});

    // Test 0: Minimal input
    {
        const name = "Test 0: Minimal input";
        const original = "AAAA";

        const max_compressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != original.len) return fail(stdout, name, "size mismatch");
        if (!std.mem.eql(u8, original, decompressed)) return fail(stdout, name, "content mismatch");

        try stdout.print("{s}... PASS\n", .{name});
    }

    // Test 1: Simple string compression and decompression
    {
        const name = "Test 1: Simple string";
        const original = "Hello, World! This is a test of the LZ4 compression algorithm.";

        const max_compressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);
        if (compressed_size == 0) return fail(stdout, name, "compression returned 0 bytes");

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != original.len) return fail(stdout, name, "size mismatch");
        if (!std.mem.eql(u8, original, decompressed)) return fail(stdout, name, "content mismatch");

        try stdout.print("{s}... PASS\n", .{name});
    }

    // Test 2: Repeated pattern (should compress well)
    {
        const name = "Test 2: Repeated pattern";
        const original = &@as([160]u8, @splat('A'));

        const max_compressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != original.len) return fail(stdout, name, "size mismatch");
        if (!std.mem.eql(u8, original, decompressed)) return fail(stdout, name, "content mismatch");

        try stdout.print("{s}... PASS\n", .{name});
    }

    // Test 3: Empty input
    {
        const name = "Test 3: Empty input";
        const original = "";

        const max_compressed = lz4.compressBound(1);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);

        const decompressed = try allocator.alloc(u8, 1);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != 0) return fail(stdout, name, "expected 0 bytes");

        try stdout.print("{s}... PASS\n", .{name});
    }

    // Test 4: Small input (no matches)
    {
        const name = "Test 4: Small input";
        const original = "ABC";

        const max_compressed = lz4.compressBound(original.len);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);

        const decompressed = try allocator.alloc(u8, original.len);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != original.len) return fail(stdout, name, "size mismatch");
        if (!std.mem.eql(u8, original, decompressed)) return fail(stdout, name, "content mismatch");

        try stdout.print("{s}... PASS\n", .{name});
    }

    // Test 5: Large buffer with patterns
    {
        const name = "Test 5: Large buffer";
        const size: usize = 10000;
        const original = try allocator.alloc(u8, size);
        defer allocator.free(original);

        for (original, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }

        const max_compressed = lz4.compressBound(size);
        const compressed = try allocator.alloc(u8, max_compressed);
        defer allocator.free(compressed);

        const compressed_size = try lz4.compressDefault(original, compressed);

        const decompressed = try allocator.alloc(u8, size);
        defer allocator.free(decompressed);

        const decompressed_size = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);

        if (decompressed_size != size) return fail(stdout, name, "size mismatch");
        if (!std.mem.eql(u8, original, decompressed)) return fail(stdout, name, "content mismatch");

        try stdout.print("{s}... PASS\n", .{name});
    }

    try stdout.print("\nAll tests passed!\n", .{});
    try stdout.flush();
}
