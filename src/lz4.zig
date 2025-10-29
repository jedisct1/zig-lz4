// LZ4 - Fast LZ compression algorithm
// Zig implementation
// Based on the C reference implementation by Yann Collet

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;

// ===== Constants =====

pub const MINMATCH = 4;
pub const WILDCOPYLENGTH = 8;
pub const LASTLITERALS = 5;
pub const MFLIMIT = 12;
pub const MATCH_SAFEGUARD_DISTANCE = (2 * WILDCOPYLENGTH) - MINMATCH;

pub const ML_BITS = 4;
pub const ML_MASK = (1 << ML_BITS) - 1; // 15
pub const RUN_BITS = 8 - ML_BITS;
pub const RUN_MASK = (1 << RUN_BITS) - 1; // 15

pub const LZ4_MAX_INPUT_SIZE = 0x7E000000; // 2,113,929,216 bytes
pub const LZ4_DISTANCE_ABSOLUTE_MAX = 65535;
pub const LZ4_DISTANCE_MAX = 65535;

pub const LZ4_MEMORY_USAGE_MIN = 10;
pub const LZ4_MEMORY_USAGE_DEFAULT = 14;
pub const LZ4_MEMORY_USAGE_MAX = 20;
pub const LZ4_MEMORY_USAGE = 14; // 2^14 = 16KB hash table
pub const LZ4_HASHLOG = LZ4_MEMORY_USAGE - 2;
pub const LZ4_HASHTABLESIZE = 1 << LZ4_MEMORY_USAGE;
pub const LZ4_HASH_SIZE_U32 = 1 << (LZ4_MEMORY_USAGE - 2);

pub const ACCELERATION_DEFAULT = 1;
pub const ACCELERATION_MAX = 65537;

pub const HASH_UNIT = 4; // bytes to hash

pub const LZ4_STREAM_MINSIZE = (1 << LZ4_MEMORY_USAGE) + 32;
pub const LZ4_STREAMDECODE_MINSIZE = 32;

// Golden ratio constant for hashing
const HASH_MULTIPLIER: u32 = 2654435761;

// ===== Error types =====

pub const Error = error{
    OutputTooSmall,
    InputTooLarge,
    CorruptedData,
    DecompressionFailed,
    InvalidState,
    AllocationFailed,
};

// ===== Helper functions =====

/// Read a little-endian u16 from a byte slice
inline fn readU16LE(ptr: [*]const u8) u16 {
    return std.mem.readInt(u16, ptr[0..2], .little);
}

/// Read a little-endian u32 from a byte slice
inline fn readU32LE(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// Write a little-endian u16 to a byte slice
inline fn writeU16LE(ptr: [*]u8, value: u16) void {
    std.mem.writeInt(u16, ptr[0..2], value, .little);
}

/// Compute hash of 4-byte sequence
inline fn hash4(sequence: u32) u32 {
    return (sequence *% HASH_MULTIPLIER) >> ((MINMATCH * 8) - LZ4_HASHLOG);
}

/// Calculate the maximum compressed size for a given input size
pub fn compressBound(inputSize: usize) usize {
    if (inputSize > LZ4_MAX_INPUT_SIZE) return 0;
    return inputSize + (inputSize / 255) + 16;
}

// ===== Decompression =====

/// Generic decompression function supporting dictionaries and partial decompression
/// This is the core decompression engine used by all public decompression functions
fn decompressGeneric(
    src: []const u8,
    dst: []u8,
    targetOutputSize: usize, // For partial decompression; use dst.len for full
    lowPrefixPtr: ?[*]const u8, // Points to prefix start (for streaming); null for standalone
    dictStart: ?[]const u8, // External dictionary; null if no dictionary
) Error!usize {
    // Empty input is valid - decompress to empty output
    if (src.len == 0) return 0;
    if (dst.len == 0) return 0;
    if (targetOutputSize > dst.len) return error.OutputTooSmall;

    const dstPtr = dst.ptr;
    const lowPrefix = lowPrefixPtr orelse dstPtr;
    const dictEnd: ?[*]const u8 = if (dictStart) |dict| dict.ptr + dict.len else null;
    const dictSize: usize = if (dictStart) |dict| dict.len else 0;

    var ip: usize = 0; // input position
    var op: usize = 0; // output position
    const iend = src.len;
    const oend = targetOutputSize;

    while (true) {
        // Check if we have room for at least a token
        if (ip >= iend) break;

        // Read token
        const token = src[ip];
        ip += 1;

        // Decode literal length
        var literalLength: usize = token >> ML_BITS;

        // If literal length == 15, read additional bytes
        if (literalLength == RUN_MASK) {
            while (true) {
                if (ip >= iend) return error.CorruptedData;
                const s = src[ip];
                ip += 1;
                literalLength += s;
                if (s != 255) break;
            }
        }

        // Copy literals
        if (literalLength > 0) {
            // Check bounds
            if (ip + literalLength > iend) return error.CorruptedData;
            if (op + literalLength > oend) return error.OutputTooSmall;

            // Copy literal bytes
            @memcpy(dst[op..][0..literalLength], src[ip..][0..literalLength]);
            ip += literalLength;
            op += literalLength;
        }

        // Check if we're done (last sequence may have no match)
        if (ip >= iend) break;

        // Read offset (2 bytes, little-endian)
        if (ip + 2 > iend) return error.CorruptedData;
        const offset = readU16LE(src[ip..].ptr);
        ip += 2;

        // Offset must be > 0
        if (offset == 0) return error.CorruptedData;

        // Decode match length
        var matchLength: usize = token & ML_MASK;

        // If match length == 15, read additional bytes
        if (matchLength == ML_MASK) {
            while (true) {
                if (ip >= iend) return error.CorruptedData;
                const s = src[ip];
                ip += 1;
                matchLength += s;
                if (s != 255) break;
            }
        }

        // Actual match length includes MINMATCH
        matchLength += MINMATCH;

        // Check output bounds
        if (op + matchLength > oend) return error.OutputTooSmall;

        // Calculate match position
        const currentPtr = dstPtr + op;
        const matchPtr = currentPtr - offset;

        // Check if match references external dictionary
        if (@intFromPtr(matchPtr) < @intFromPtr(lowPrefix)) {
            // Match starts in external dictionary
            if (dictEnd == null) {
                // No dictionary available but match requires it
                return error.CorruptedData;
            }

            // Validate offset doesn't go beyond dictionary
            const prefixOffset = @intFromPtr(currentPtr) - @intFromPtr(lowPrefix);
            if (offset > prefixOffset + dictSize) {
                return error.CorruptedData;
            }

            // Calculate how far back into dictionary we need to go
            const lowPrefixOffset = @intFromPtr(lowPrefix) - @intFromPtr(matchPtr);
            const dictMatchPtr = dictEnd.? - lowPrefixOffset;

            // Check if match fits entirely within external dictionary
            if (matchLength <= lowPrefixOffset) {
                // Match entirely in dictionary - just copy
                @memcpy(dst[op..][0..matchLength], dictMatchPtr[0..matchLength]);
                op += matchLength;
            } else {
                // Match spans both external dictionary and current block
                const copySize = lowPrefixOffset;
                const restSize = matchLength - copySize;

                // Copy dictionary part
                @memcpy(dst[op..][0..copySize], dictMatchPtr[0..copySize]);
                op += copySize;

                // Copy rest from current block (starting at lowPrefix)
                const restStart = @intFromPtr(lowPrefix) - @intFromPtr(dstPtr);

                // Check for overlap (RLE pattern)
                if (restSize > op - restStart) {
                    // Overlapping copy - byte by byte
                    var i: usize = 0;
                    while (i < restSize) : (i += 1) {
                        dst[op + i] = dst[restStart + i];
                    }
                    op += restSize;
                } else {
                    // Non-overlapping
                    @memcpy(dst[op..][0..restSize], dst[restStart..][0..restSize]);
                    op += restSize;
                }
            }
        } else {
            // Match within current block
            if (offset > op) return error.CorruptedData;
            const matchPos = op - offset;

            // Handle overlapping copies (RLE-style)
            if (offset < matchLength) {
                // Overlapping copy - must be done byte by byte
                var i: usize = 0;
                while (i < matchLength) : (i += 1) {
                    dst[op + i] = dst[matchPos + i];
                }
                op += matchLength;
            } else {
                // Non-overlapping - can use memcpy
                @memcpy(dst[op..][0..matchLength], dst[matchPos..][0..matchLength]);
                op += matchLength;
            }
        }
    }

    return op;
}

/// Decompress LZ4 data safely with bounds checking
/// src: compressed data
/// dst: destination buffer (must be pre-allocated)
/// Returns: number of bytes written to dst, or error
pub fn decompressSafe(src: []const u8, dst: []u8) Error!usize {
    return decompressGeneric(src, dst, dst.len, null, null);
}

// ===== Compression =====

pub const HashTable = struct {
    table: [LZ4_HASH_SIZE_U32]u32,

    pub fn init() HashTable {
        return .{ .table = [_]u32{0} ** LZ4_HASH_SIZE_U32 };
    }

    fn get(self: *const HashTable, hash: u32) u32 {
        return self.table[hash];
    }

    fn put(self: *HashTable, hash: u32, pos: u32) void {
        self.table[hash] = pos;
    }
};

/// Compress data using LZ4 with default settings (acceleration = 1)
/// src: source data to compress
/// dst: destination buffer (must be at least compressBound(src.len) bytes)
/// Returns: number of bytes written to dst, or error
pub fn compressDefault(src: []const u8, dst: []u8) Error!usize {
    return compressFast(src, dst, ACCELERATION_DEFAULT);
}

/// Compress data using LZ4 with specified acceleration
/// src: source data to compress
/// dst: destination buffer (must be at least compressBound(src.len) bytes)
/// acceleration: speed vs compression ratio (higher = faster, less compression)
/// Returns: number of bytes written to dst, or error
pub fn compressFast(src: []const u8, dst: []u8, acceleration: u32) Error!usize {
    const srcSize = src.len;

    // Check input size
    if (srcSize > LZ4_MAX_INPUT_SIZE) return error.InputTooLarge;

    // Empty input
    if (srcSize == 0) return 0;

    // Input too small - just store as literals
    if (srcSize < MFLIMIT + 1) {
        return compressAsLiterals(src, dst);
    }

    // Initialize hash table
    var hashTable = HashTable.init();

    var ip: usize = 0;
    var op: usize = 0;
    var anchor: usize = 0; // Start of current literal run

    const mflimitPlusOne = srcSize - MFLIMIT;
    const matchLimit = srcSize - LASTLITERALS;

    // First byte
    ip += 1;

    // Main compression loop
    while (ip < mflimitPlusOne) {
        const accel = std.math.clamp(acceleration, 1, ACCELERATION_MAX);
        var step: usize = accel;
        var searchMatchNb: usize = accel;

        // Find a match
        var match: usize = undefined;
        var forwardIp = ip;

        while (true) {
            ip = forwardIp;
            forwardIp += step;
            step = searchMatchNb >> 6; // Adaptive step
            searchMatchNb += 1;

            if (forwardIp > mflimitPlusOne) {
                // No more matches possible - encode remaining as literals
                return finishCompression(src, dst, anchor, op);
            }

            // Hash current position
            const h = hash4(readU32LE(src[ip..].ptr));
            match = hashTable.get(h);

            // CRITICAL: Must check BEFORE putting, to avoid matching ourselves
            const is_valid_match = match > 0 and
                match < ip and // FIXED: was >= should be <
                match + LZ4_DISTANCE_ABSOLUTE_MAX >= ip and
                readU32LE(src[match..].ptr) == readU32LE(src[ip..].ptr);

            hashTable.put(h, @intCast(ip));

            if (is_valid_match) {
                break;
            }
        }

        // Found a match - encode literal run + match

        // Calculate literal length
        const literalLength = ip - anchor;

        // Write token position (we'll fill it in after we know match length)
        const tokenPos = op;
        op += 1;
        if (op >= dst.len) return error.OutputTooSmall;

        // Write literals
        if (literalLength >= RUN_MASK) {
            // Extended literal length
            dst[tokenPos] = RUN_MASK << ML_BITS;
            var len = literalLength - RUN_MASK;

            while (len >= 255) {
                if (op >= dst.len) return error.OutputTooSmall;
                dst[op] = 255;
                op += 1;
                len -= 255;
            }

            if (op >= dst.len) return error.OutputTooSmall;
            dst[op] = @intCast(len);
            op += 1;
        } else {
            dst[tokenPos] = @as(u8, @intCast(literalLength)) << ML_BITS;
        }

        // Copy literal bytes
        if (op + literalLength > dst.len) return error.OutputTooSmall;
        if (literalLength > 0) {
            @memcpy(dst[op..][0..literalLength], src[anchor..][0..literalLength]);
            op += literalLength;
        }

        // Write offset
        const offset: u16 = @intCast(ip - match);
        if (op + 2 > dst.len) return error.OutputTooSmall;
        writeU16LE(dst[op..].ptr, offset);
        op += 2;

        // Find match length
        ip += MINMATCH;
        match += MINMATCH;
        var matchLength: usize = 0;

        while (ip < matchLimit) {
            if (src[ip] == src[match]) {
                ip += 1;
                match += 1;
                matchLength += 1;
            } else {
                break;
            }
        }

        // Write match length to token
        if (matchLength >= ML_MASK) {
            dst[tokenPos] |= ML_MASK;
            var len = matchLength - ML_MASK;

            while (len >= 255) {
                if (op >= dst.len) return error.OutputTooSmall;
                dst[op] = 255;
                op += 1;
                len -= 255;
            }

            if (op >= dst.len) return error.OutputTooSmall;
            dst[op] = @intCast(len);
            op += 1;
        } else {
            dst[tokenPos] |= @intCast(matchLength);
        }

        // Update anchor
        anchor = ip;

        // Hash next position
        if (ip < mflimitPlusOne) {
            const h = hash4(readU32LE(src[ip..].ptr));
            hashTable.put(h, @intCast(ip));
            ip += 1;
        }
    }

    // Encode remaining literals
    return finishCompression(src, dst, anchor, op);
}

fn compressAsLiterals(src: []const u8, dst: []u8) Error!usize {
    const literalLength = src.len;
    var op: usize = 0;

    // Token
    if (dst.len < 1) return error.OutputTooSmall;

    if (literalLength >= RUN_MASK) {
        dst[op] = RUN_MASK << ML_BITS;
        op += 1;
        var len = literalLength - RUN_MASK;

        while (len >= 255) {
            if (op >= dst.len) return error.OutputTooSmall;
            dst[op] = 255;
            op += 1;
            len -= 255;
        }

        if (op >= dst.len) return error.OutputTooSmall;
        dst[op] = @intCast(len);
        op += 1;
    } else {
        dst[op] = @as(u8, @intCast(literalLength)) << ML_BITS;
        op += 1;
    }

    // Copy literals
    if (op + literalLength > dst.len) return error.OutputTooSmall;
    @memcpy(dst[op..][0..literalLength], src);
    op += literalLength;

    return op;
}

fn finishCompression(src: []const u8, dst: []u8, anchor: usize, op: usize) Error!usize {
    const literalLength = src.len - anchor;
    var outPos = op;

    if (literalLength == 0) return outPos;

    // Token
    if (outPos >= dst.len) return error.OutputTooSmall;

    if (literalLength >= RUN_MASK) {
        dst[outPos] = RUN_MASK << ML_BITS;
        outPos += 1;
        var len = literalLength - RUN_MASK;

        while (len >= 255) {
            if (outPos >= dst.len) return error.OutputTooSmall;
            dst[outPos] = 255;
            outPos += 1;
            len -= 255;
        }

        if (outPos >= dst.len) return error.OutputTooSmall;
        dst[outPos] = @intCast(len);
        outPos += 1;
    } else {
        dst[outPos] = @as(u8, @intCast(literalLength)) << ML_BITS;
        outPos += 1;
    }

    // Copy literals
    if (outPos + literalLength > dst.len) return error.OutputTooSmall;
    @memcpy(dst[outPos..][0..literalLength], src[anchor..][0..literalLength]);
    outPos += literalLength;

    return outPos;
}

// ===== Advanced Block Functions =====

/// Get size needed for compression state buffer
pub fn sizeofState() usize {
    return @sizeOf(HashTable);
}

/// Compress with external state buffer (avoids internal allocation)
/// state: pre-allocated buffer of at least sizeofState() bytes
/// Returns: compressed size or error
pub fn compressFastExtState(state: []align(@alignOf(HashTable)) u8, src: []const u8, dst: []u8, acceleration: u32) Error!usize {
    if (state.len < sizeofState()) return error.InvalidState;

    const srcSize = src.len;
    if (srcSize > LZ4_MAX_INPUT_SIZE) return error.InputTooLarge;
    if (srcSize == 0) return 0;
    if (srcSize < MFLIMIT + 1) {
        return compressAsLiterals(src, dst);
    }

    // Cast state buffer to HashTable
    const hashTable: *HashTable = @ptrCast(@alignCast(state.ptr));
    hashTable.* = HashTable.init();

    return compressFastWithHashTable(src, dst, acceleration, hashTable);
}

/// Compress to fit target destination size
/// srcSizePtr: in/out parameter - input size on entry, consumed bytes on return
/// Returns: compressed size or error
pub fn compressDestSize(src: []const u8, dst: []u8, srcSizePtr: *usize) Error!usize {
    const maxSrcSize = srcSizePtr.*;
    if (maxSrcSize == 0) {
        srcSizePtr.* = 0;
        return 0;
    }

    // If destination is large enough for full compression, just compress normally
    const maxCompressed = compressBound(maxSrcSize);
    if (dst.len >= maxCompressed) {
        const result = try compressDefault(src[0..maxSrcSize], dst);
        srcSizePtr.* = maxSrcSize;
        return result;
    }

    // Binary search to find the largest input size that fits in dst
    var low: usize = 1;
    var high: usize = maxSrcSize;
    var bestSize: usize = 0;
    var bestCompressedSize: usize = 0;

    // First, try a quick estimate: assume roughly 1:1 compression ratio
    if (dst.len <= maxSrcSize) {
        const estimate = @min(dst.len, maxSrcSize);
        if (compressDefault(src[0..estimate], dst)) |size| {
            if (size <= dst.len) {
                bestSize = estimate;
                bestCompressedSize = size;
                low = estimate + 1; // Try larger sizes
            } else {
                high = estimate - 1; // Too large, try smaller
            }
        } else |_| {
            high = estimate - 1;
        }
    }

    // Binary search for optimal size
    while (low <= high) {
        const mid = low + (high - low) / 2;
        if (mid == 0 or mid > maxSrcSize) break;

        // Try compressing this amount
        if (compressDefault(src[0..mid], dst)) |size| {
            if (size <= dst.len) {
                // Fits! Try larger
                bestSize = mid;
                bestCompressedSize = size;
                if (mid == maxSrcSize) break; // Can't go larger
                low = mid + 1;
            } else {
                // Too large, try smaller
                high = mid - 1;
            }
        } else |_| {
            // Compression failed, try smaller
            high = mid - 1;
        }

        // Safety check: prevent infinite loop
        if (low > maxSrcSize) break;
    }

    srcSizePtr.* = bestSize;
    return bestCompressedSize;
}

/// Decompress only the first targetOutputSize bytes
pub fn decompressSafePartial(src: []const u8, dst: []u8, targetOutputSize: usize) Error!usize {
    return decompressGeneric(src, dst, targetOutputSize, null, null);
}

// Helper function to compress with a given hash table
fn compressFastWithHashTable(src: []const u8, dst: []u8, acceleration: u32, hashTable: *HashTable) Error!usize {
    const srcSize = src.len;
    var ip: usize = 0;
    var op: usize = 0;
    var anchor: usize = 0;

    const mflimitPlusOne = srcSize - MFLIMIT;
    const matchLimit = srcSize - LASTLITERALS;

    ip += 1;

    while (ip < mflimitPlusOne) {
        const accel = std.math.clamp(acceleration, 1, ACCELERATION_MAX);
        var step: usize = accel;
        var searchMatchNb: usize = accel;

        var match: usize = undefined;
        var forwardIp = ip;

        while (true) {
            ip = forwardIp;
            forwardIp += step;
            step = searchMatchNb >> 6;
            searchMatchNb += 1;

            if (forwardIp > mflimitPlusOne) {
                return finishCompression(src, dst, anchor, op);
            }

            const h = hash4(readU32LE(src[ip..].ptr));
            match = hashTable.get(h);

            const is_valid_match = match > 0 and
                match < ip and
                match + LZ4_DISTANCE_ABSOLUTE_MAX >= ip and
                readU32LE(src[match..].ptr) == readU32LE(src[ip..].ptr);

            hashTable.put(h, @intCast(ip));

            if (is_valid_match) {
                break;
            }
        }

        const literalLength = ip - anchor;
        const tokenPos = op;
        op += 1;
        if (op >= dst.len) return error.OutputTooSmall;

        if (literalLength >= RUN_MASK) {
            dst[tokenPos] = RUN_MASK << ML_BITS;
            var len = literalLength - RUN_MASK;
            while (len >= 255) {
                if (op >= dst.len) return error.OutputTooSmall;
                dst[op] = 255;
                op += 1;
                len -= 255;
            }
            if (op >= dst.len) return error.OutputTooSmall;
            dst[op] = @intCast(len);
            op += 1;
        } else {
            dst[tokenPos] = @as(u8, @intCast(literalLength)) << ML_BITS;
        }

        if (op + literalLength > dst.len) return error.OutputTooSmall;
        if (literalLength > 0) {
            @memcpy(dst[op..][0..literalLength], src[anchor..][0..literalLength]);
            op += literalLength;
        }

        const offset: u16 = @intCast(ip - match);
        if (op + 2 > dst.len) return error.OutputTooSmall;
        writeU16LE(dst[op..].ptr, offset);
        op += 2;

        ip += MINMATCH;
        match += MINMATCH;
        var matchLength: usize = 0;

        while (ip < matchLimit) {
            if (src[ip] == src[match]) {
                ip += 1;
                match += 1;
                matchLength += 1;
            } else {
                break;
            }
        }

        if (matchLength >= ML_MASK) {
            dst[tokenPos] |= ML_MASK;
            var len = matchLength - ML_MASK;
            while (len >= 255) {
                if (op >= dst.len) return error.OutputTooSmall;
                dst[op] = 255;
                op += 1;
                len -= 255;
            }
            if (op >= dst.len) return error.OutputTooSmall;
            dst[op] = @intCast(len);
            op += 1;
        } else {
            dst[tokenPos] |= @intCast(matchLength);
        }

        anchor = ip;

        if (ip < mflimitPlusOne) {
            const h = hash4(readU32LE(src[ip..].ptr));
            hashTable.put(h, @intCast(ip));
            ip += 1;
        }
    }

    return finishCompression(src, dst, anchor, op);
}

// ===== Streaming Compression =====

const TableType = enum(u32) {
    byU32 = 1,
    byU16 = 2,
    byPtr = 3,
};

/// LZ4 streaming compression context
pub const Stream = struct {
    hashTable: [LZ4_HASH_SIZE_U32]u32,
    dictionary: ?[]const u8,
    dictCtx: ?*const Stream,
    currentOffset: u32,
    tableType: TableType,
    dictSize: u32,
    allocator: ?Allocator,

    /// Create a new streaming compression context
    pub fn create(allocator: Allocator) Error!*Stream {
        const stream = allocator.create(Stream) catch return error.AllocationFailed;
        stream.* = init();
        stream.allocator = allocator;
        return stream;
    }

    /// Free a streaming compression context
    pub fn destroy(self: *Stream) void {
        if (self.allocator) |alloc| {
            alloc.destroy(self);
        }
    }

    /// Initialize a stream (for stack-allocated streams)
    pub fn init() Stream {
        return .{
            .hashTable = [_]u32{0} ** LZ4_HASH_SIZE_U32,
            .dictionary = null,
            .dictCtx = null,
            .currentOffset = 0,
            .tableType = .byU32,
            .dictSize = 0,
            .allocator = null,
        };
    }

    /// Reset stream for new compression
    pub fn resetFast(self: *Stream) void {
        @memset(&self.hashTable, 0);
        self.dictionary = null;
        self.dictCtx = null;
        self.currentOffset = 0;
        self.dictSize = 0;
    }

    /// Load dictionary into stream
    pub fn loadDict(self: *Stream, dict: []const u8) usize {
        self.resetFast();

        if (dict.len == 0) return 0;

        // Only keep last 64KB
        const dictSize = @min(dict.len, 64 * 1024);
        const dictStart = dict.len - dictSize;
        self.dictionary = dict[dictStart..];
        self.dictSize = @intCast(dictSize);

        // Hash the dictionary
        if (dictSize >= MINMATCH) {
            var i: usize = 0;
            while (i < dictSize - MINMATCH) : (i += 1) {
                const h = hash4(readU32LE(dict[dictStart + i ..].ptr));
                self.hashTable[h] = @intCast(i);
            }
        }

        return dictSize;
    }

    /// Compress next block in stream
    pub fn compressFastContinue(self: *Stream, src: []const u8, dst: []u8, acceleration: u32) Error!usize {
        if (src.len > LZ4_MAX_INPUT_SIZE) return error.InputTooLarge;
        if (src.len == 0) return 0;
        if (src.len < MFLIMIT + 1) {
            return compressAsLiterals(src, dst);
        }

        // Use the stream's hash table
        var hashTable = HashTable{ .table = self.hashTable };
        const result = try compressFastWithHashTable(src, dst, acceleration, &hashTable);
        self.hashTable = hashTable.table;
        self.currentOffset +|= @intCast(src.len);

        return result;
    }

    /// Save dictionary to safe buffer
    pub fn saveDict(self: *Stream, safeBuffer: []u8, maxDictSize: usize) usize {
        if (maxDictSize == 0) return 0;
        if (self.dictionary == null) return 0;

        const dict = self.dictionary.?;
        const dictSize = @min(@min(dict.len, maxDictSize), 64 * 1024);

        if (dictSize > safeBuffer.len) {
            const copySize = @min(dictSize, safeBuffer.len);
            @memcpy(safeBuffer[0..copySize], dict[dict.len - copySize ..]);
            return copySize;
        }

        @memcpy(safeBuffer[0..dictSize], dict[dict.len - dictSize ..]);
        return dictSize;
    }
};

/// Create streaming compression context (convenience wrapper)
pub fn createStream(allocator: Allocator) Error!*Stream {
    return Stream.create(allocator);
}

/// Free streaming compression context (convenience wrapper)
pub fn freeStream(stream: *Stream) void {
    stream.destroy();
}

// ===== Streaming Decompression =====

/// LZ4 streaming decompression context
pub const StreamDecode = struct {
    externalDict: ?[]const u8,
    prefixEnd: ?[]const u8,
    extDictSize: usize,
    prefixSize: usize,
    allocator: ?Allocator,

    /// Create new streaming decompression context
    pub fn create(allocator: Allocator) Error!*StreamDecode {
        const stream = allocator.create(StreamDecode) catch return error.AllocationFailed;
        stream.* = init();
        stream.allocator = allocator;
        return stream;
    }

    /// Free streaming decompression context
    pub fn destroy(self: *StreamDecode) void {
        if (self.allocator) |alloc| {
            alloc.destroy(self);
        }
    }

    /// Initialize a decode stream
    pub fn init() StreamDecode {
        return .{
            .externalDict = null,
            .prefixEnd = null,
            .extDictSize = 0,
            .prefixSize = 0,
            .allocator = null,
        };
    }

    /// Set dictionary for decompression
    pub fn setStreamDecode(self: *StreamDecode, dict: ?[]const u8) void {
        self.externalDict = dict;
        self.prefixEnd = null;
        self.extDictSize = if (dict) |d| d.len else 0;
        self.prefixSize = 0;
    }

    /// Decompress next block in stream
    pub fn decompressSafeContinue(self: *StreamDecode, src: []const u8, dst: []u8) Error!usize {
        // On first call (no prefix), decompress normally
        if (self.prefixSize == 0 and self.extDictSize == 0) {
            const result = try decompressSafe(src, dst);
            // Update prefix for next call
            self.prefixEnd = dst[0..result];
            self.prefixSize = result;
            return result;
        }

        // Determine lowPrefix pointer based on context
        const lowPrefix: [*]const u8 = if (self.prefixEnd) |prefix|
            prefix.ptr
        else
            dst.ptr;

        // Use external dictionary if present
        const dict: ?[]const u8 = if (self.extDictSize > 0) self.externalDict else null;

        const result = try decompressGeneric(src, dst, dst.len, lowPrefix, dict);

        // Update prefix for next call
        self.prefixEnd = dst[0..result];
        self.prefixSize = result;
        self.externalDict = null; // Dictionary only used once
        self.extDictSize = 0;

        return result;
    }
};

/// Create streaming decompression context (convenience wrapper)
pub fn createStreamDecode(allocator: Allocator) Error!*StreamDecode {
    return StreamDecode.create(allocator);
}

/// Free streaming decompression context (convenience wrapper)
pub fn freeStreamDecode(stream: *StreamDecode) void {
    stream.destroy();
}

/// Calculate decoder ring buffer size
pub fn decoderRingBufferSize(maxBlockSize: usize) usize {
    if (maxBlockSize == 0) return 0;
    return 65536 + 14 + maxBlockSize;
}

/// Decompress using dictionary (stateless)
pub fn decompressSafeUsingDict(src: []const u8, dst: []u8, dict: []const u8) Error!usize {
    // Decompress with dictionary support
    // The dictionary is treated as data that precedes the current block
    return decompressGeneric(src, dst, dst.len, dst.ptr, dict);
}

/// Partial decompress using dictionary (stateless)
pub fn decompressSafePartialUsingDict(src: []const u8, dst: []u8, targetOutputSize: usize, dict: []const u8) Error!usize {
    // Partial decompression with dictionary support
    return decompressGeneric(src, dst, targetOutputSize, dst.ptr, dict);
}
