# zig-lz4

A pure Zig implementation of LZ4 compression. This is a complete port of the C reference implementation by Yann Collet, rewritten in safe Zig.

## What is LZ4?

LZ4 is a fast lossless compression algorithm focused on speed. It's widely used in systems where you need compression but can't afford the CPU overhead of heavier algorithms like gzip or zstd.

## Features

This library implements the full LZ4 spec:

- Block compression - The basic LZ4 algorithm for compressing individual blocks
- HC mode - High compression variant that trades speed for better compression ratios
- Frame format - The standard LZ4 frame format with checksums and metadata
- Streaming - Compress and decompress data incrementally
- Dictionaries - Use external dictionaries for better compression of small blocks

All code is pure Zig with no C dependencies. The implementation follows the same algorithms as the reference C library and passes compatibility tests with the standard `lz4` tool.

## Requirements

- Zig 0.15.1 or newer

## Usage

Add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .lz4 = .{
        .url = "https://github.com/jedisct1/zig-lz4/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const lz4 = b.dependency("lz4", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("lz4", lz4.module("lz4"));
```

### Basic compression

```zig
const lz4 = @import("lz4");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = "Hello, World!";

    // Allocate buffer for compressed data
    const max_size = lz4.compressBound(input.len);
    const compressed = try allocator.alloc(u8, max_size);
    defer allocator.free(compressed);

    // Compress
    const compressed_size = try lz4.compressDefault(input, compressed);

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    _ = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
}
```

### HC (high compression) mode

```zig
const lz4 = @import("lz4");

// Use higher compression level (2-12)
const compressed_size = try lz4.compressHC(
    input,
    compressed,
    lz4.LZ4HC_CLEVEL_DEFAULT, // level 9
);
```

### Frame format

The frame format adds checksums and is what the `lz4` command-line tool uses:

```zig
const lz4 = @import("lz4");

// Compression context
var cctx = try lz4.lz4f.createCompressionContext(allocator);
defer lz4.lz4f.freeCompressionContext(cctx);

// Write frame header
var prefs = lz4.lz4f.Preferences.init();
const header_size = try lz4.lz4f.compressBegin(
    cctx,
    output_buffer,
    &prefs,
);

// Compress data
const compressed_size = try lz4.lz4f.compressUpdate(
    cctx,
    output_buffer[header_size..],
    input_data,
    null,
);

// Finish frame
const end_size = try lz4.lz4f.compressEnd(
    cctx,
    output_buffer[header_size + compressed_size..],
    null,
);
```

## Building and testing

```bash
# Run tests
zig build test

# Run specific test suites
zig build test-lz4hc
zig build test-lz4f
zig build test-compat

# Build the library
zig build
```

The test suite includes compatibility tests against the reference `lz4` implementation to verify the output is byte-for-byte identical.

## Compatibility

This implementation is designed to be wire-compatible with the reference LZ4 library. Files compressed with this library can be decompressed by the standard `lz4` tool and vice versa.
