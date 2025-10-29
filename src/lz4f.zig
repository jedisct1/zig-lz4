//! LZ4 Frame format implementation
//! Port of the C reference implementation by Yann Collet
//! Specification: https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md

const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");

// ===== Constants =====

/// LZ4 Frame magic number (little endian)
pub const MAGICNUMBER: u32 = 0x184D2204;

/// Skippable frame magic number range
pub const MAGIC_SKIPPABLE_START: u32 = 0x184D2A50;
pub const MAGIC_SKIPPABLE_MASK: u32 = 0xFFFFFFF0;

/// Frame header size bounds
pub const HEADER_SIZE_MIN: usize = 7;
pub const HEADER_SIZE_MAX: usize = 19;
pub const MIN_SIZE_TO_KNOW_HEADER_LENGTH: usize = 5;

/// Block header and checksum sizes
pub const BLOCK_HEADER_SIZE: usize = 4;
pub const BLOCK_CHECKSUM_SIZE: usize = 4;
pub const CONTENT_CHECKSUM_SIZE: usize = 4;
pub const ENDMARK_SIZE: usize = 4;

// ===== Error Types =====

pub const Error = error{
    Generic,
    MaxBlockSizeInvalid,
    BlockModeInvalid,
    ParameterInvalid,
    CompressionLevelInvalid,
    HeaderVersionWrong,
    BlockChecksumInvalid,
    ReservedFlagSet,
    AllocationFailed,
    SrcSizeTooLarge,
    DstMaxSizeTooSmall,
    FrameHeaderIncomplete,
    FrameTypeUnknown,
    FrameSizeWrong,
    SrcPtrWrong,
    DecompressionFailed,
    HeaderChecksumInvalid,
    ContentChecksumInvalid,
    FrameDecodingAlreadyStarted,
    CompressionStateUninitialized,
    ParameterNull,
    MaxCode,
    OutOfMemory,
};

pub fn isError(code: usize) bool {
    return code > @as(usize, @bitCast(@as(isize, -65536)));
}

// ===== Types =====

/// Block size ID enum
pub const BlockSizeID = enum(u3) {
    default = 0,
    max64KB = 4,
    max256KB = 5,
    max1MB = 6,
    max4MB = 7,

    pub fn toBlockSize(self: BlockSizeID) Error!usize {
        return switch (self) {
            .default, .max64KB => 64 * 1024,
            .max256KB => 256 * 1024,
            .max1MB => 1024 * 1024,
            .max4MB => 4 * 1024 * 1024,
        };
    }
};

/// Block mode enum
pub const BlockMode = enum(u1) {
    linked = 0,
    independent = 1,
};

/// Content checksum flag
pub const ContentChecksum = enum(u1) {
    disabled = 0,
    enabled = 1,
};

/// Block checksum flag
pub const BlockChecksum = enum(u1) {
    disabled = 0,
    enabled = 1,
};

/// Frame type
pub const FrameType = enum(u1) {
    frame = 0,
    skippableFrame = 1,
};

/// Frame information structure
pub const FrameInfo = struct {
    blockSizeID: BlockSizeID = .default,
    blockMode: BlockMode = .linked,
    contentChecksumFlag: ContentChecksum = .disabled,
    frameType: FrameType = .frame,
    contentSize: u64 = 0, // 0 = unknown
    dictID: u32 = 0, // 0 = no dictID
    blockChecksumFlag: BlockChecksum = .disabled,
};

/// Compression preferences
pub const Preferences = struct {
    frameInfo: FrameInfo = .{},
    compressionLevel: i32 = 0, // 0 = default (fast mode)
    autoFlush: bool = false,
    favorDecSpeed: bool = false,
};

/// Compression options
pub const CompressOptions = struct {
    stableSrc: bool = false,
};

/// Decompression options
pub const DecompressOptions = struct {
    stableDst: bool = false,
    skipChecksums: bool = false,
};

// ===== Frame Descriptor Functions =====

/// Calculate header checksum (second byte of xxh32)
fn headerChecksum(data: []const u8) u8 {
    const hash = std.hash.XxHash32.hash(0, data);
    return @truncate((hash >> 8) & 0xFF);
}

/// Map LZ4 compression errors to frame format errors
fn mapCompressionError(err: lz4.Error) Error {
    return switch (err) {
        lz4.Error.OutputTooSmall => Error.DstMaxSizeTooSmall,
        else => Error.Generic,
    };
}

/// Encode FLG byte
fn encodeFLG(info: FrameInfo) u8 {
    var flg: u8 = 0;

    // Version (bits 7-6) = 01
    flg |= 0x40;

    // Block independence (bit 5)
    if (info.blockMode == .independent) {
        flg |= 0x20;
    }

    // Block checksum (bit 4)
    if (info.blockChecksumFlag == .enabled) {
        flg |= 0x10;
    }

    // Content size (bit 3)
    if (info.contentSize != 0) {
        flg |= 0x08;
    }

    // Content checksum (bit 2)
    if (info.contentChecksumFlag == .enabled) {
        flg |= 0x04;
    }

    // Dictionary ID (bit 0)
    if (info.dictID != 0) {
        flg |= 0x01;
    }

    return flg;
}

/// Decode FLG byte
fn decodeFLG(flg: u8) Error!FrameInfo {
    var info: FrameInfo = .{};

    // Check version (bits 7-6)
    const version = (flg >> 6) & 0x3;
    if (version != 1) {
        return Error.HeaderVersionWrong;
    }

    // Check reserved bit (bit 1)
    if ((flg & 0x02) != 0) {
        return Error.ReservedFlagSet;
    }

    // Block independence (bit 5)
    info.blockMode = if ((flg & 0x20) != 0) .independent else .linked;

    // Block checksum (bit 4)
    info.blockChecksumFlag = if ((flg & 0x10) != 0) .enabled else .disabled;

    // Content size present (bit 3)
    const contentSizeFlag = (flg & 0x08) != 0;

    // Content checksum (bit 2)
    info.contentChecksumFlag = if ((flg & 0x04) != 0) .enabled else .disabled;

    // Dictionary ID (bit 0)
    const dictIDFlag = (flg & 0x01) != 0;

    // Store flags for later parsing
    _ = contentSizeFlag;
    _ = dictIDFlag;

    return info;
}

/// Encode BD byte
fn encodeBD(blockSizeID: BlockSizeID) u8 {
    const sizeValue: u8 = switch (blockSizeID) {
        .default, .max64KB => 4,
        .max256KB => 5,
        .max1MB => 6,
        .max4MB => 7,
    };
    return sizeValue << 4;
}

/// Decode BD byte
fn decodeBD(bd: u8) Error!BlockSizeID {
    // Check reserved bits (bit 7 and bits 3-0)
    if ((bd & 0x8F) != 0) {
        return Error.ReservedFlagSet;
    }

    const blockSizeValue = (bd >> 4) & 0x7;
    return switch (blockSizeValue) {
        0, 4 => .max64KB,
        5 => .max256KB,
        6 => .max1MB,
        7 => .max4MB,
        else => Error.MaxBlockSizeInvalid,
    };
}

/// Write little-endian u32
fn writeU32LE(dst: []u8, value: u32) void {
    std.mem.writeInt(u32, dst[0..4], value, .little);
}

/// Read little-endian u32
fn readU32LE(src: []const u8) u32 {
    return std.mem.readInt(u32, src[0..4], .little);
}

/// Write little-endian u64
fn writeU64LE(dst: []u8, value: u64) void {
    std.mem.writeInt(u64, dst[0..8], value, .little);
}

/// Read little-endian u64
fn readU64LE(src: []const u8) u64 {
    return std.mem.readInt(u64, src[0..8], .little);
}

// ===== Simple Compression API =====

/// Calculate maximum compressed size for frame compression
pub fn compressFrameBound(srcSize: usize, prefs: ?Preferences) usize {
    const preferences = prefs orelse Preferences{};
    const blockSize = preferences.frameInfo.blockSizeID.toBlockSize() catch 65536;

    var result: usize = HEADER_SIZE_MAX;

    // Calculate number of blocks
    const numBlocks = (srcSize + blockSize - 1) / blockSize;

    // Each block: header + worst case compressed + optional checksum
    for (0..numBlocks) |_| {
        result += BLOCK_HEADER_SIZE;
        result += lz4.compressBound(blockSize);
        if (preferences.frameInfo.blockChecksumFlag == .enabled) {
            result += BLOCK_CHECKSUM_SIZE;
        }
    }

    // End mark
    result += ENDMARK_SIZE;

    // Content checksum
    if (preferences.frameInfo.contentChecksumFlag == .enabled) {
        result += CONTENT_CHECKSUM_SIZE;
    }

    return result;
}

/// Encode frame header
fn writeFrameHeader(dst: []u8, prefs: Preferences) Error!usize {
    if (dst.len < HEADER_SIZE_MIN) {
        return Error.DstMaxSizeTooSmall;
    }

    var pos: usize = 0;

    // Write magic number
    writeU32LE(dst[pos..], MAGICNUMBER);
    pos += 4;

    // Write FLG byte
    const flg = encodeFLG(prefs.frameInfo);
    dst[pos] = flg;
    pos += 1;

    // Write BD byte
    const bd = encodeBD(prefs.frameInfo.blockSizeID);
    dst[pos] = bd;
    pos += 1;

    const headerStart = 4; // After magic number

    // Write content size if present
    if (prefs.frameInfo.contentSize != 0) {
        if (dst.len < pos + 8) {
            return Error.DstMaxSizeTooSmall;
        }
        writeU64LE(dst[pos..], prefs.frameInfo.contentSize);
        pos += 8;
    }

    // Write dictionary ID if present
    if (prefs.frameInfo.dictID != 0) {
        if (dst.len < pos + 4) {
            return Error.DstMaxSizeTooSmall;
        }
        writeU32LE(dst[pos..], prefs.frameInfo.dictID);
        pos += 4;
    }

    // Write header checksum
    const hc = headerChecksum(dst[headerStart..pos]);
    dst[pos] = hc;
    pos += 1;

    return pos;
}

/// Compress a complete frame in one shot
pub fn compressFrame(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    prefs: ?Preferences,
) Error!usize {
    const preferences = prefs orelse Preferences{};

    // Verify destination capacity
    const requiredSize = compressFrameBound(src.len, preferences);
    if (dst.len < requiredSize) {
        return Error.DstMaxSizeTooSmall;
    }

    // Write frame header
    var dstPos = try writeFrameHeader(dst, preferences);

    // Get block size
    const blockSize = try preferences.frameInfo.blockSizeID.toBlockSize();

    // Initialize content checksum if enabled
    var contentChecksum = std.hash.XxHash32.init(0);

    // Compress data in blocks
    var srcPos: usize = 0;
    while (srcPos < src.len) {
        const blockLen = @min(blockSize, src.len - srcPos);
        const srcBlock = src[srcPos..][0..blockLen];

        // Update content checksum
        if (preferences.frameInfo.contentChecksumFlag == .enabled) {
            contentChecksum.update(srcBlock);
        }

        // Reserve space for block header
        const blockStart = dstPos + BLOCK_HEADER_SIZE;
        const dstBlock = dst[blockStart..];

        // Compress block (use HC if compressionLevel > 0)
        const compressedSize = if (preferences.compressionLevel > 0)
            lz4hc.compressHC(
                srcBlock,
                dstBlock,
                preferences.compressionLevel,
            ) catch |err| return mapCompressionError(err)
        else
            lz4.compressFast(
                srcBlock,
                dstBlock,
                1,
            ) catch |err| return mapCompressionError(err);

        // Determine if block should be stored uncompressed
        const storeUncompressed = compressedSize >= blockLen;
        const actualSize = if (storeUncompressed) blockLen else compressedSize;

        // Write block header
        var blockHeader: u32 = @intCast(actualSize);
        if (storeUncompressed) {
            blockHeader |= 0x80000000; // Set highest bit for uncompressed

            // Copy uncompressed data
            @memcpy(dst[blockStart..][0..blockLen], srcBlock);
        }
        writeU32LE(dst[dstPos..], blockHeader);
        dstPos = blockStart + actualSize;

        // Write block checksum if enabled
        if (preferences.frameInfo.blockChecksumFlag == .enabled) {
            const blockData = dst[blockStart..][0..actualSize];
            const checksum = std.hash.XxHash32.hash(0, blockData);
            writeU32LE(dst[dstPos..], checksum);
            dstPos += BLOCK_CHECKSUM_SIZE;
        }

        srcPos += blockLen;
    }

    // Write end mark (0x00000000)
    writeU32LE(dst[dstPos..], 0);
    dstPos += ENDMARK_SIZE;

    // Write content checksum if enabled
    if (preferences.frameInfo.contentChecksumFlag == .enabled) {
        const checksum = contentChecksum.final();
        writeU32LE(dst[dstPos..], checksum);
        dstPos += CONTENT_CHECKSUM_SIZE;
    }

    _ = allocator; // Unused for now, but kept for API consistency

    return dstPos;
}

// ===== Simple Decompression API =====

/// Get frame header size
pub fn headerSize(src: []const u8) Error!usize {
    if (src.len < MIN_SIZE_TO_KNOW_HEADER_LENGTH) {
        return Error.FrameHeaderIncomplete;
    }

    // Check magic number
    const magic = readU32LE(src[0..4]);
    if (magic != MAGICNUMBER) {
        // Check if it's a skippable frame
        if ((magic & MAGIC_SKIPPABLE_MASK) == MAGIC_SKIPPABLE_START) {
            return 8; // Skippable frame header is 8 bytes
        }
        return Error.FrameTypeUnknown;
    }

    const flg = src[4];
    var size: usize = 7; // Minimum: magic(4) + FLG(1) + BD(1) + HC(1)

    // Add content size if present (bit 3)
    if ((flg & 0x08) != 0) {
        size += 8;
    }

    // Add dictionary ID if present (bit 0)
    if ((flg & 0x01) != 0) {
        size += 4;
    }

    return size;
}

/// Parse frame header
fn parseFrameHeader(src: []const u8) Error!struct { info: FrameInfo, size: usize } {
    if (src.len < HEADER_SIZE_MIN) {
        return Error.FrameHeaderIncomplete;
    }

    // Check magic number
    const magic = readU32LE(src[0..4]);
    if (magic != MAGICNUMBER) {
        return Error.FrameTypeUnknown;
    }

    var pos: usize = 4;

    // Parse FLG byte
    const flg = src[pos];
    var info = try decodeFLG(flg);
    pos += 1;

    // Parse BD byte
    const bd = src[pos];
    info.blockSizeID = try decodeBD(bd);
    pos += 1;

    const headerStart = 4; // After magic number

    // Parse content size if present
    if ((flg & 0x08) != 0) {
        if (src.len < pos + 8) {
            return Error.FrameHeaderIncomplete;
        }
        info.contentSize = readU64LE(src[pos..]);
        pos += 8;
    }

    // Parse dictionary ID if present
    if ((flg & 0x01) != 0) {
        if (src.len < pos + 4) {
            return Error.FrameHeaderIncomplete;
        }
        info.dictID = readU32LE(src[pos..]);
        pos += 4;
    }

    // Verify header checksum
    if (src.len < pos + 1) {
        return Error.FrameHeaderIncomplete;
    }
    const storedChecksum = src[pos];
    const calculatedChecksum = headerChecksum(src[headerStart..pos]);
    if (storedChecksum != calculatedChecksum) {
        return Error.HeaderChecksumInvalid;
    }
    pos += 1;

    return .{ .info = info, .size = pos };
}

/// Decompress a complete frame
pub fn decompressFrame(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
) Error!usize {
    // Parse frame header
    const header = try parseFrameHeader(src);
    const frameInfo = header.info;
    var srcPos = header.size;
    var dstPos: usize = 0;

    // Get block size
    const blockSize = try frameInfo.blockSizeID.toBlockSize();

    // Allocate temporary buffer for block decompression
    const blockBuffer = try allocator.alloc(u8, blockSize);
    defer allocator.free(blockBuffer);

    // Initialize content checksum if enabled
    var contentChecksum = std.hash.XxHash32.init(0);

    // Decompress blocks
    while (srcPos < src.len) {
        // Read block header
        if (srcPos + BLOCK_HEADER_SIZE > src.len) {
            return Error.FrameSizeWrong;
        }

        const blockHeader = readU32LE(src[srcPos..]);
        srcPos += BLOCK_HEADER_SIZE;

        // Check for end mark
        if (blockHeader == 0) {
            break;
        }

        // Extract block size and uncompressed flag
        const isUncompressed = (blockHeader & 0x80000000) != 0;
        const blockDataSize = blockHeader & 0x7FFFFFFF;

        // Verify block size
        if (srcPos + blockDataSize > src.len) {
            return Error.FrameSizeWrong;
        }

        const blockData = src[srcPos..][0..blockDataSize];
        srcPos += blockDataSize;

        // Verify block checksum if enabled
        if (frameInfo.blockChecksumFlag == .enabled) {
            if (srcPos + BLOCK_CHECKSUM_SIZE > src.len) {
                return Error.FrameSizeWrong;
            }
            const storedChecksum = readU32LE(src[srcPos..]);
            const calculatedChecksum = std.hash.XxHash32.hash(0, blockData);
            if (storedChecksum != calculatedChecksum) {
                return Error.BlockChecksumInvalid;
            }
            srcPos += BLOCK_CHECKSUM_SIZE;
        }

        // Decompress or copy block
        const decompressedSize = if (isUncompressed) blk: {
            if (dstPos + blockDataSize > dst.len) {
                return Error.DstMaxSizeTooSmall;
            }
            @memcpy(dst[dstPos..][0..blockDataSize], blockData);
            break :blk blockDataSize;
        } else blk: {
            const size = lz4.decompressSafe(blockData, dst[dstPos..]) catch {
                return Error.DecompressionFailed;
            };
            break :blk size;
        };

        // Update content checksum
        if (frameInfo.contentChecksumFlag == .enabled) {
            contentChecksum.update(dst[dstPos..][0..decompressedSize]);
        }

        dstPos += decompressedSize;
    }

    // Verify content checksum if enabled
    if (frameInfo.contentChecksumFlag == .enabled) {
        if (srcPos + CONTENT_CHECKSUM_SIZE > src.len) {
            return Error.FrameSizeWrong;
        }
        const storedChecksum = readU32LE(src[srcPos..]);
        const calculatedChecksum = contentChecksum.final();
        if (storedChecksum != calculatedChecksum) {
            return Error.ContentChecksumInvalid;
        }
        srcPos += CONTENT_CHECKSUM_SIZE;
    }

    return dstPos;
}

// ===== Tests =====

test "LZ4F frame header encoding/decoding" {
    const testing = std.testing;

    var buf: [HEADER_SIZE_MAX]u8 = undefined;

    const prefs = Preferences{
        .frameInfo = .{
            .blockSizeID = .max64KB,
            .blockMode = .independent,
            .contentChecksumFlag = .enabled,
            .contentSize = 12345,
        },
    };

    // Encode header
    const headerLen = try writeFrameHeader(&buf, prefs);
    try testing.expect(headerLen >= HEADER_SIZE_MIN);
    try testing.expect(headerLen <= HEADER_SIZE_MAX);

    // Verify magic number
    const magic = readU32LE(buf[0..4]);
    try testing.expectEqual(MAGICNUMBER, magic);

    // Parse header
    const parsed = try parseFrameHeader(buf[0..headerLen]);
    try testing.expectEqual(prefs.frameInfo.blockSizeID, parsed.info.blockSizeID);
    try testing.expectEqual(prefs.frameInfo.blockMode, parsed.info.blockMode);
    try testing.expectEqual(prefs.frameInfo.contentChecksumFlag, parsed.info.contentChecksumFlag);
    try testing.expectEqual(prefs.frameInfo.contentSize, parsed.info.contentSize);
    try testing.expectEqual(headerLen, parsed.size);
}

test "LZ4F compress/decompress frame" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "Hello, World! This is a test of LZ4 frame compression. " ** 10;

    // Compress
    const maxCompressed = compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try compressFrame(allocator, input, compressed, null);
    try testing.expect(compressedSize > 0);
    try testing.expect(compressedSize <= maxCompressed);

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressedSize = try decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressedSize);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);
}

test "LZ4F empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "";

    // Compress
    const maxCompressed = compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try compressFrame(allocator, input, compressed, null);
    try testing.expect(compressedSize > 0);

    // Decompress
    const decompressed = try allocator.alloc(u8, 1024);
    defer allocator.free(decompressed);

    const decompressedSize = try decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqual(@as(usize, 0), decompressedSize);
}

test "LZ4F with content checksum" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "Test data with checksum validation";
    const prefs = Preferences{
        .frameInfo = .{
            .contentChecksumFlag = .enabled,
        },
    };

    // Compress
    const maxCompressed = compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, maxCompressed);
    defer allocator.free(compressed);

    const compressedSize = try compressFrame(allocator, input, compressed, prefs);

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressedSize = try decompressFrame(
        allocator,
        compressed[0..compressedSize],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressedSize]);
}
