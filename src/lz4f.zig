//! LZ4 frame format implementation.
//! Port of the C reference implementation by Yann Collet.
//! Specification: https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md

const std = @import("std");
const mem = std.mem;
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");

/// LZ4 frame magic number (little endian).
pub const MAGICNUMBER: u32 = 0x184D2204;

/// Skippable frame magic number range.
pub const MAGIC_SKIPPABLE_START: u32 = 0x184D2A50;
pub const MAGIC_SKIPPABLE_MASK: u32 = 0xFFFFFFF0;

/// Frame header size bounds.
pub const HEADER_SIZE_MIN: usize = 7;
pub const HEADER_SIZE_MAX: usize = 19;
pub const MIN_SIZE_TO_KNOW_HEADER_LENGTH: usize = 5;

/// Block header and checksum sizes.
pub const BLOCK_HEADER_SIZE: usize = 4;
pub const BLOCK_CHECKSUM_SIZE: usize = 4;
pub const CONTENT_CHECKSUM_SIZE: usize = 4;
pub const ENDMARK_SIZE: usize = 4;

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

pub const BlockMode = enum(u1) {
    linked = 0,
    independent = 1,
};

pub const ContentChecksum = enum(u1) {
    disabled = 0,
    enabled = 1,
};

pub const BlockChecksum = enum(u1) {
    disabled = 0,
    enabled = 1,
};

pub const FrameType = enum(u1) {
    frame = 0,
    skippableFrame = 1,
};

pub const FrameInfo = struct {
    blockSizeID: BlockSizeID = .default,
    blockMode: BlockMode = .linked,
    contentChecksumFlag: ContentChecksum = .disabled,
    frameType: FrameType = .frame,
    /// 0 means unknown.
    contentSize: u64 = 0,
    /// 0 means no dictionary ID.
    dictID: u32 = 0,
    blockChecksumFlag: BlockChecksum = .disabled,
};

pub const Preferences = struct {
    frameInfo: FrameInfo = .{},
    /// 0 = default (fast mode); values > 0 use HC compression.
    compressionLevel: i32 = 0,
    autoFlush: bool = false,
    favorDecSpeed: bool = false,
};

pub const CompressOptions = struct {
    stableSrc: bool = false,
};

pub const DecompressOptions = struct {
    stableDst: bool = false,
    skipChecksums: bool = false,
};

/// Header checksum: second byte of the xxHash32 of the descriptor.
fn headerChecksum(data: []const u8) u8 {
    return @truncate(std.hash.XxHash32.hash(0, data) >> 8);
}

fn mapCompressionError(err: lz4.Error) Error {
    return switch (err) {
        lz4.Error.OutputTooSmall => Error.DstMaxSizeTooSmall,
        else => Error.Generic,
    };
}

fn encodeFLG(info: FrameInfo) u8 {
    var flg: u8 = 0x40; // version 01 in bits 7-6

    if (info.blockMode == .independent) flg |= 0x20;
    if (info.blockChecksumFlag == .enabled) flg |= 0x10;
    if (info.contentSize != 0) flg |= 0x08;
    if (info.contentChecksumFlag == .enabled) flg |= 0x04;
    if (info.dictID != 0) flg |= 0x01;

    return flg;
}

fn decodeFLG(flg: u8) Error!FrameInfo {
    const version = (flg >> 6) & 0x3;
    if (version != 1) return Error.HeaderVersionWrong;

    if ((flg & 0x02) != 0) return Error.ReservedFlagSet;

    return .{
        .blockMode = if ((flg & 0x20) != 0) .independent else .linked,
        .blockChecksumFlag = if ((flg & 0x10) != 0) .enabled else .disabled,
        .contentChecksumFlag = if ((flg & 0x04) != 0) .enabled else .disabled,
    };
}

fn encodeBD(block_size_id: BlockSizeID) u8 {
    const size_value: u8 = switch (block_size_id) {
        .default, .max64KB => 4,
        .max256KB => 5,
        .max1MB => 6,
        .max4MB => 7,
    };
    return size_value << 4;
}

fn decodeBD(bd: u8) Error!BlockSizeID {
    // Bit 7 and bits 3-0 are reserved.
    if ((bd & 0x8F) != 0) return Error.ReservedFlagSet;

    return switch ((bd >> 4) & 0x7) {
        0, 4 => .max64KB,
        5 => .max256KB,
        6 => .max1MB,
        7 => .max4MB,
        else => Error.MaxBlockSizeInvalid,
    };
}

/// Maximum compressed size for frame compression of `src_size` bytes.
pub fn compressFrameBound(src_size: usize, prefs: ?Preferences) usize {
    const preferences = prefs orelse Preferences{};
    const block_size = preferences.frameInfo.blockSizeID.toBlockSize() catch 65536;

    const num_blocks = (src_size + block_size - 1) / block_size;
    var per_block = BLOCK_HEADER_SIZE + lz4.compressBound(block_size);
    if (preferences.frameInfo.blockChecksumFlag == .enabled) {
        per_block += BLOCK_CHECKSUM_SIZE;
    }

    var result = HEADER_SIZE_MAX + num_blocks * per_block + ENDMARK_SIZE;
    if (preferences.frameInfo.contentChecksumFlag == .enabled) {
        result += CONTENT_CHECKSUM_SIZE;
    }

    return result;
}

fn writeFrameHeader(dst: []u8, prefs: Preferences) Error!usize {
    if (dst.len < HEADER_SIZE_MIN) return Error.DstMaxSizeTooSmall;

    var pos: usize = 0;

    mem.writeInt(u32, dst[pos..][0..4], MAGICNUMBER, .little);
    pos += 4;

    dst[pos] = encodeFLG(prefs.frameInfo);
    pos += 1;

    dst[pos] = encodeBD(prefs.frameInfo.blockSizeID);
    pos += 1;

    const descriptor_start = 4; // after the magic number

    if (prefs.frameInfo.contentSize != 0) {
        if (dst.len < pos + 8) return Error.DstMaxSizeTooSmall;
        mem.writeInt(u64, dst[pos..][0..8], prefs.frameInfo.contentSize, .little);
        pos += 8;
    }

    if (prefs.frameInfo.dictID != 0) {
        if (dst.len < pos + 4) return Error.DstMaxSizeTooSmall;
        mem.writeInt(u32, dst[pos..][0..4], prefs.frameInfo.dictID, .little);
        pos += 4;
    }

    dst[pos] = headerChecksum(dst[descriptor_start..pos]);
    pos += 1;

    return pos;
}

/// Compress a complete frame in one shot.
/// Returns the number of bytes written to `dst`.
pub fn compressFrame(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    prefs: ?Preferences,
) Error!usize {
    _ = allocator; // kept for API consistency
    const preferences = prefs orelse Preferences{};

    if (dst.len < compressFrameBound(src.len, preferences)) {
        return Error.DstMaxSizeTooSmall;
    }

    var dst_pos = try writeFrameHeader(dst, preferences);

    const block_size = try preferences.frameInfo.blockSizeID.toBlockSize();

    var content_checksum = std.hash.XxHash32.init(0);

    var src_pos: usize = 0;
    while (src_pos < src.len) {
        const block_len = @min(block_size, src.len - src_pos);
        const src_block = src[src_pos..][0..block_len];

        if (preferences.frameInfo.contentChecksumFlag == .enabled) {
            content_checksum.update(src_block);
        }

        const block_start = dst_pos + BLOCK_HEADER_SIZE;
        const dst_block = dst[block_start..];

        const compressed_size = if (preferences.compressionLevel > 0)
            lz4hc.compressHC(src_block, dst_block, preferences.compressionLevel) catch |err|
                return mapCompressionError(err)
        else
            lz4.compressFast(src_block, dst_block, 1) catch |err|
                return mapCompressionError(err);

        // Store the block uncompressed when compression does not help.
        const store_uncompressed = compressed_size >= block_len;
        const actual_size = if (store_uncompressed) block_len else compressed_size;

        var block_header: u32 = @intCast(actual_size);
        if (store_uncompressed) {
            block_header |= 0x80000000;
            @memcpy(dst[block_start..][0..block_len], src_block);
        }
        mem.writeInt(u32, dst[dst_pos..][0..4], block_header, .little);
        dst_pos = block_start + actual_size;

        if (preferences.frameInfo.blockChecksumFlag == .enabled) {
            const checksum = std.hash.XxHash32.hash(0, dst[block_start..][0..actual_size]);
            mem.writeInt(u32, dst[dst_pos..][0..4], checksum, .little);
            dst_pos += BLOCK_CHECKSUM_SIZE;
        }

        src_pos += block_len;
    }

    // End mark.
    mem.writeInt(u32, dst[dst_pos..][0..4], 0, .little);
    dst_pos += ENDMARK_SIZE;

    if (preferences.frameInfo.contentChecksumFlag == .enabled) {
        mem.writeInt(u32, dst[dst_pos..][0..4], content_checksum.final(), .little);
        dst_pos += CONTENT_CHECKSUM_SIZE;
    }

    return dst_pos;
}

/// Size of the frame header at the start of `src`.
pub fn headerSize(src: []const u8) Error!usize {
    if (src.len < MIN_SIZE_TO_KNOW_HEADER_LENGTH) {
        return Error.FrameHeaderIncomplete;
    }

    const magic = mem.readInt(u32, src[0..4], .little);
    if (magic != MAGICNUMBER) {
        if ((magic & MAGIC_SKIPPABLE_MASK) == MAGIC_SKIPPABLE_START) {
            return 8; // skippable frame header
        }
        return Error.FrameTypeUnknown;
    }

    const flg = src[4];
    var size: usize = HEADER_SIZE_MIN;
    if ((flg & 0x08) != 0) size += 8; // content size
    if ((flg & 0x01) != 0) size += 4; // dictionary ID

    return size;
}

fn parseFrameHeader(src: []const u8) Error!struct { info: FrameInfo, size: usize } {
    if (src.len < HEADER_SIZE_MIN) return Error.FrameHeaderIncomplete;

    const magic = mem.readInt(u32, src[0..4], .little);
    if (magic != MAGICNUMBER) return Error.FrameTypeUnknown;

    var pos: usize = 4;

    const flg = src[pos];
    var info = try decodeFLG(flg);
    pos += 1;

    info.blockSizeID = try decodeBD(src[pos]);
    pos += 1;

    const descriptor_start = 4; // after the magic number

    if ((flg & 0x08) != 0) {
        if (src.len < pos + 8) return Error.FrameHeaderIncomplete;
        info.contentSize = mem.readInt(u64, src[pos..][0..8], .little);
        pos += 8;
    }

    if ((flg & 0x01) != 0) {
        if (src.len < pos + 4) return Error.FrameHeaderIncomplete;
        info.dictID = mem.readInt(u32, src[pos..][0..4], .little);
        pos += 4;
    }

    if (src.len < pos + 1) return Error.FrameHeaderIncomplete;
    if (src[pos] != headerChecksum(src[descriptor_start..pos])) {
        return Error.HeaderChecksumInvalid;
    }
    pos += 1;

    return .{ .info = info, .size = pos };
}

/// Decompress a complete frame.
/// Returns the number of bytes written to `dst`.
pub fn decompressFrame(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
) Error!usize {
    const header = try parseFrameHeader(src);
    const frame_info = header.info;
    var src_pos = header.size;
    var dst_pos: usize = 0;

    const block_size = try frame_info.blockSizeID.toBlockSize();

    const block_buffer = try allocator.alloc(u8, block_size);
    defer allocator.free(block_buffer);

    var content_checksum = std.hash.XxHash32.init(0);

    while (src_pos < src.len) {
        if (src_pos + BLOCK_HEADER_SIZE > src.len) return Error.FrameSizeWrong;

        const block_header = mem.readInt(u32, src[src_pos..][0..4], .little);
        src_pos += BLOCK_HEADER_SIZE;

        // End mark.
        if (block_header == 0) break;

        const is_uncompressed = (block_header & 0x80000000) != 0;
        const block_data_size = block_header & 0x7FFFFFFF;

        if (src_pos + block_data_size > src.len) return Error.FrameSizeWrong;

        const block_data = src[src_pos..][0..block_data_size];
        src_pos += block_data_size;

        if (frame_info.blockChecksumFlag == .enabled) {
            if (src_pos + BLOCK_CHECKSUM_SIZE > src.len) return Error.FrameSizeWrong;
            const stored_checksum = mem.readInt(u32, src[src_pos..][0..4], .little);
            if (stored_checksum != std.hash.XxHash32.hash(0, block_data)) {
                return Error.BlockChecksumInvalid;
            }
            src_pos += BLOCK_CHECKSUM_SIZE;
        }

        const decompressed_size = if (is_uncompressed) blk: {
            if (dst_pos + block_data_size > dst.len) return Error.DstMaxSizeTooSmall;
            @memcpy(dst[dst_pos..][0..block_data_size], block_data);
            break :blk block_data_size;
        } else lz4.decompressSafe(block_data, dst[dst_pos..]) catch {
            return Error.DecompressionFailed;
        };

        if (frame_info.contentChecksumFlag == .enabled) {
            content_checksum.update(dst[dst_pos..][0..decompressed_size]);
        }

        dst_pos += decompressed_size;
    }

    if (frame_info.contentChecksumFlag == .enabled) {
        if (src_pos + CONTENT_CHECKSUM_SIZE > src.len) return Error.FrameSizeWrong;
        const stored_checksum = mem.readInt(u32, src[src_pos..][0..4], .little);
        if (stored_checksum != content_checksum.final()) {
            return Error.ContentChecksumInvalid;
        }
        src_pos += CONTENT_CHECKSUM_SIZE;
    }

    return dst_pos;
}

inline fn repeatString(comptime n: usize, comptime str: []const u8) []const u8 {
    const buf: [n][str.len]u8 = @splat(str[0..str.len].*);
    return @ptrCast(&buf);
}

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

    const header_len = try writeFrameHeader(&buf, prefs);
    try testing.expect(header_len >= HEADER_SIZE_MIN);
    try testing.expect(header_len <= HEADER_SIZE_MAX);

    const magic = mem.readInt(u32, buf[0..4], .little);
    try testing.expectEqual(MAGICNUMBER, magic);

    const parsed = try parseFrameHeader(buf[0..header_len]);
    try testing.expectEqual(prefs.frameInfo.blockSizeID, parsed.info.blockSizeID);
    try testing.expectEqual(prefs.frameInfo.blockMode, parsed.info.blockMode);
    try testing.expectEqual(prefs.frameInfo.contentChecksumFlag, parsed.info.contentChecksumFlag);
    try testing.expectEqual(prefs.frameInfo.contentSize, parsed.info.contentSize);
    try testing.expectEqual(header_len, parsed.size);
}

test "LZ4F compress/decompress frame" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = repeatString(10, "Hello, World! This is a test of LZ4 frame compression. ");

    const max_compressed = compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try compressFrame(allocator, input, compressed, null);
    try testing.expect(compressed_size > 0);
    try testing.expect(compressed_size <= max_compressed);

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressed_size = try decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqual(input.len, decompressed_size);
    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);
}

test "LZ4F empty input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "";

    const max_compressed = compressFrameBound(input.len, null);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try compressFrame(allocator, input, compressed, null);
    try testing.expect(compressed_size > 0);

    const decompressed = try allocator.alloc(u8, 1024);
    defer allocator.free(decompressed);

    const decompressed_size = try decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqual(@as(usize, 0), decompressed_size);
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

    const max_compressed = compressFrameBound(input.len, prefs);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);

    const compressed_size = try compressFrame(allocator, input, compressed, prefs);

    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    const decompressed_size = try decompressFrame(
        allocator,
        compressed[0..compressed_size],
        decompressed,
    );

    try testing.expectEqualSlices(u8, input, decompressed[0..decompressed_size]);
}
