// LZ4 HC - High Compression Mode of LZ4
// Zig implementation
// Based on the C reference implementation by Yann Collet
// Copyright (c) Yann Collet. All rights reserved. (BSD 2-Clause License)

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;
const lz4 = @import("lz4.zig");

// ===== Constants =====

// Re-export constants from lz4.zig
pub const MINMATCH = lz4.MINMATCH;
pub const WILDCOPYLENGTH = lz4.WILDCOPYLENGTH;
pub const LASTLITERALS = lz4.LASTLITERALS;
pub const MFLIMIT = lz4.MFLIMIT;
pub const ML_BITS = lz4.ML_BITS;
pub const ML_MASK = lz4.ML_MASK;
pub const RUN_BITS = lz4.RUN_BITS;
pub const RUN_MASK = lz4.RUN_MASK;
pub const LZ4_MAX_INPUT_SIZE = lz4.LZ4_MAX_INPUT_SIZE;
pub const LZ4_DISTANCE_MAX = lz4.LZ4_DISTANCE_MAX;
pub const LZ4_DISTANCE_ABSOLUTE_MAX = lz4.LZ4_DISTANCE_ABSOLUTE_MAX;

// HC-specific constants
pub const LZ4HC_CLEVEL_MIN = 2;
pub const LZ4HC_CLEVEL_DEFAULT = 9;
pub const LZ4HC_CLEVEL_OPT_MIN = 10;
pub const LZ4HC_CLEVEL_MAX = 12;

pub const LZ4HC_DICTIONARY_LOGSIZE = 16;
pub const LZ4HC_MAXD = 1 << LZ4HC_DICTIONARY_LOGSIZE; // 65536
pub const LZ4HC_MAXD_MASK = LZ4HC_MAXD - 1;

pub const LZ4HC_HASH_LOG = 15;
pub const LZ4HC_HASHTABLESIZE = 1 << LZ4HC_HASH_LOG; // 32768
pub const LZ4HC_HASH_MASK = LZ4HC_HASHTABLESIZE - 1;

pub const OPTIMAL_ML = (ML_MASK - 1) + MINMATCH;
pub const LZ4_OPT_NUM = 1 << 12; // 4096

// LZ4MID constants
pub const LZ4MID_HASHLOG = LZ4HC_HASH_LOG - 1; // 14
pub const LZ4MID_HASHTABLESIZE = 1 << LZ4MID_HASHLOG; // 16384
pub const LZ4MID_HASHSIZE = 8; // bytes to hash for LZ4MID

// Golden ratio constant for hashing
const HASH_MULTIPLIER: u32 = 2654435761;
const HASH_MULTIPLIER_64: u64 = 58295818150454627;

// ===== Error types =====

pub const Error = lz4.Error;

// ===== Compression Strategy =====

pub const Strategy = enum {
    lz4mid, // Level 2: dual hash tables, 2 attempts
    lz4hc, // Levels 3-9: hash chains, 4-256 attempts
    lz4opt, // Levels 10-12: optimal parser, 96-16384 attempts
};

pub const CompressionParams = struct {
    strat: Strategy,
    nbSearches: i32,
    targetLength: u32,
};

// Compression level table
const clevelTable = [_]CompressionParams{
    .{ .strat = .lz4mid, .nbSearches = 2, .targetLength = 16 }, // 0, unused
    .{ .strat = .lz4mid, .nbSearches = 2, .targetLength = 16 }, // 1, unused
    .{ .strat = .lz4mid, .nbSearches = 2, .targetLength = 16 }, // 2
    .{ .strat = .lz4hc, .nbSearches = 4, .targetLength = 16 }, // 3
    .{ .strat = .lz4hc, .nbSearches = 8, .targetLength = 16 }, // 4
    .{ .strat = .lz4hc, .nbSearches = 16, .targetLength = 16 }, // 5
    .{ .strat = .lz4hc, .nbSearches = 32, .targetLength = 16 }, // 6
    .{ .strat = .lz4hc, .nbSearches = 64, .targetLength = 16 }, // 7
    .{ .strat = .lz4hc, .nbSearches = 128, .targetLength = 16 }, // 8
    .{ .strat = .lz4hc, .nbSearches = 256, .targetLength = 16 }, // 9
    .{ .strat = .lz4opt, .nbSearches = 96, .targetLength = 64 }, // 10 (CLEVEL_OPT_MIN)
    .{ .strat = .lz4opt, .nbSearches = 512, .targetLength = 128 }, // 11
    .{ .strat = .lz4opt, .nbSearches = 16384, .targetLength = LZ4_OPT_NUM }, // 12 (CLEVEL_MAX)
};

inline fn getCLevelParams(cLevel: i32) CompressionParams {
    var level = cLevel;
    if (level < 1) {
        level = LZ4HC_CLEVEL_DEFAULT;
    }
    if (level > LZ4HC_CLEVEL_MAX) {
        level = LZ4HC_CLEVEL_MAX;
    }
    return clevelTable[@intCast(level)];
}

// ===== Helper functions =====

/// Read a little-endian u16 from a byte slice
inline fn readU16LE(ptr: [*]const u8) u16 {
    return std.mem.readInt(u16, ptr[0..2], .little);
}

/// Read a little-endian u32 from a byte slice
inline fn readU32LE(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// Read a little-endian u64 from a byte slice
inline fn readU64LE(ptr: [*]const u8) u64 {
    return std.mem.readInt(u64, ptr[0..8], .little);
}

/// Write a little-endian u16 to a byte slice
inline fn writeU16LE(ptr: [*]u8, value: u16) void {
    std.mem.writeInt(u16, ptr[0..2], value, .little);
}

/// Write a little-endian u32 to a byte slice
inline fn writeU32LE(ptr: [*]u8, value: u32) void {
    std.mem.writeInt(u32, ptr[0..4], value, .little);
}

// ===== Hashing Functions =====

/// Compute hash of 4-byte sequence for HC
inline fn hashHC(sequence: u32) u32 {
    return (sequence *% HASH_MULTIPLIER) >> ((MINMATCH * 8) - LZ4HC_HASH_LOG);
}

/// Hash pointer for HC
inline fn hashPtr(ptr: [*]const u8) u32 {
    return hashHC(readU32LE(ptr));
}

/// Hash 4-byte sequence for LZ4MID
inline fn hashMid4(sequence: u32) u32 {
    return (sequence *% HASH_MULTIPLIER) >> (32 - LZ4MID_HASHLOG);
}

/// Hash pointer for LZ4MID (4 bytes)
inline fn hashMid4Ptr(ptr: [*]const u8) u32 {
    return hashMid4(readU32LE(ptr));
}

/// Hash 7-byte sequence for LZ4MID (hashes lower 56 bits)
inline fn hashMid7(sequence: u64) u32 {
    const masked = (sequence << (64 - 56));
    return @truncate((masked *% HASH_MULTIPLIER_64) >> (64 - LZ4MID_HASHLOG));
}

/// Hash pointer for LZ4MID (8 bytes)
inline fn hashMid8Ptr(ptr: [*]const u8) u32 {
    return hashMid7(readU64LE(ptr));
}

// ===== Pattern Analysis Functions =====

/// Rotate a 32-bit pattern by a given number of bytes
inline fn rotatePattern(rotate: usize, pattern: u32) u32 {
    const bitsToRotate = (rotate & 3) << 3; // (rotate & (sizeof(u32) - 1)) << 3
    if (bitsToRotate == 0) return pattern;
    return std.math.rotl(u32, pattern, @intCast(bitsToRotate));
}

/// Count how many times a pattern repeats forward
/// pattern must be a sample of repetitive pattern of length 1, 2, or 4 bytes
inline fn countPattern(ip: [*]const u8, iEnd: [*]const u8, pattern32: u32) usize {
    const iStart = ip;
    var ptr = ip;

    // Expand pattern to 64-bit for faster comparison on 64-bit platforms
    const pattern64: u64 = @as(u64, pattern32) | (@as(u64, pattern32) << 32);

    // Fast 8-byte comparisons
    while (@intFromPtr(ptr) + 7 < @intFromPtr(iEnd)) {
        const diff = readU64LE(ptr) ^ pattern64;
        if (diff == 0) {
            ptr += 8;
        } else {
            // Count matching bytes
            const nbCommon = @ctz(diff) >> 3;
            return @intFromPtr(ptr) + nbCommon - @intFromPtr(iStart);
        }
    }

    // Check remaining bytes one at a time
    var patternByte = pattern32;
    while (@intFromPtr(ptr) < @intFromPtr(iEnd)) {
        if (ptr[0] != @as(u8, @truncate(patternByte))) break;
        ptr += 1;
        patternByte >>= 8;
        if (patternByte == 0) patternByte = pattern32; // Wrap around pattern
    }

    return @intFromPtr(ptr) - @intFromPtr(iStart);
}

/// Count how many times a pattern repeats backward
inline fn reverseCountPattern(ip: [*]const u8, iLow: [*]const u8, pattern: u32) usize {
    const iStart = ip;
    var ptr = ip;

    // Fast 4-byte comparisons
    while (@intFromPtr(ptr) >= @intFromPtr(iLow) + 4) {
        if (readU32LE(ptr - 4) != pattern) break;
        ptr -= 4;
    }

    // Check remaining bytes
    const patternBytes = @as([*]const u8, @ptrCast(&pattern));
    var byteIdx: usize = 3;
    while (@intFromPtr(ptr) > @intFromPtr(iLow)) {
        if ((ptr - 1)[0] != patternBytes[byteIdx]) break;
        ptr -= 1;
        if (byteIdx == 0) byteIdx = 3 else byteIdx -= 1;
    }

    return @intFromPtr(iStart) - @intFromPtr(ptr);
}

/// Check if a pattern is repetitive (1, 2, or 4 byte repeat)
inline fn isRepetitivePattern(pattern: u32) bool {
    // Check if lower 16 bits == upper 16 bits AND lowest byte repeats
    return ((pattern & 0xFFFF) == (pattern >> 16)) and ((pattern & 0xFF) == (pattern >> 24));
}

// ===== Count Functions =====

/// Count the number of matching bytes between two sequences
/// Returns the number of matching bytes
inline fn lz4Count(pIn: [*]const u8, pMatch: [*]const u8, pInLimit: [*]const u8) usize {
    var ip = pIn;
    var match = pMatch;
    const iLimit = pInLimit;

    var counted: usize = 0;

    // Fast 8-byte comparisons on 64-bit platforms
    while (@intFromPtr(ip) + 8 <= @intFromPtr(iLimit)) {
        const diff = readU64LE(ip) ^ readU64LE(match);
        if (diff == 0) {
            ip += 8;
            match += 8;
            counted += 8;
        } else {
            // Count trailing zeros to find first mismatch
            const nbCommon = @ctz(diff) >> 3;
            return counted + nbCommon;
        }
    }

    // Check remaining bytes
    while (@intFromPtr(ip) < @intFromPtr(iLimit)) {
        if (ip[0] != match[0]) break;
        ip += 1;
        match += 1;
        counted += 1;
    }

    return counted;
}

/// Count backward: return negative value, number of common bytes before ip/match
inline fn countBack(ip: [*]const u8, match: [*]const u8, iMin: [*]const u8, mMin: [*]const u8) i32 {
    var back: i32 = 0;
    const minDist = @min(@intFromPtr(ip) - @intFromPtr(iMin), @intFromPtr(match) - @intFromPtr(mMin));
    const min: i32 = -@as(i32, @intCast(minDist));

    // Fast 4-byte comparison
    while ((back - min) > 3) {
        const ipIdx: usize = @intCast(back - 4);
        const v = readU32LE(@ptrCast(&ip[@as(usize, @bitCast(@as(isize, @intCast(ipIdx))))])) ^
            readU32LE(@ptrCast(&match[@as(usize, @bitCast(@as(isize, @intCast(ipIdx))))]));
        if (v != 0) {
            // Count trailing zeros to find first mismatch
            const nbCommon = @ctz(v) >> 3;
            return back - @as(i32, @intCast(nbCommon));
        }
        back -= 4;
    }

    // Check remainder byte by byte
    while (back > min) {
        const idx: usize = @intCast(back - 1);
        if (ip[@as(usize, @bitCast(@as(isize, @intCast(idx))))] !=
            match[@as(usize, @bitCast(@as(isize, @intCast(idx))))])
        {
            break;
        }
        back -= 1;
    }

    return back;
}

// ===== Sequence Encoding =====

const LimitedOutput = enum {
    notLimited,
    limitedOutput,
};

/// Encode a literal+match sequence into the output buffer
/// Returns: 0 if ok, 1 if output buffer issue detected
fn encodeSequence(
    ip: *[*]const u8,
    op: *[*]u8,
    anchor: *[*]const u8,
    matchLength: i32,
    offset: i32,
    limit: LimitedOutput,
    oend: [*]u8,
) i32 {
    const litLen: usize = @intFromPtr(ip.*) - @intFromPtr(anchor.*);

    // Check output limit
    if (limit == .limitedOutput) {
        const needed = (litLen / 255) + litLen + (2 + 1 + LASTLITERALS);
        if (@intFromPtr(op.*) + needed > @intFromPtr(oend)) {
            return 1;
        }
    }

    // Encode literal length
    var token = op.*;
    op.* += 1;

    if (litLen >= RUN_MASK) {
        var len = litLen - RUN_MASK;
        token[0] = RUN_MASK << ML_BITS;
        while (len >= 255) {
            op.*[0] = 255;
            op.* += 1;
            len -= 255;
        }
        op.*[0] = @truncate(len);
        op.* += 1;
    } else {
        token[0] = @as(u8, @truncate(litLen)) << ML_BITS;
    }

    // Copy literals
    @memcpy(op.*[0..litLen], anchor.*[0..litLen]);
    op.* += litLen;

    // Encode offset
    writeU16LE(op.*, @intCast(offset));
    op.* += 2;

    // Encode match length
    const mlCode: usize = @intCast(matchLength - MINMATCH);
    if (limit == .limitedOutput) {
        if (@intFromPtr(op.*) + (mlCode / 255) + (1 + LASTLITERALS) > @intFromPtr(oend)) {
            return 1;
        }
    }

    if (mlCode >= ML_MASK) {
        token[0] += ML_MASK;
        var remaining = mlCode - ML_MASK;
        while (remaining >= 510) {
            op.*[0] = 255;
            op.*[1] = 255;
            op.* += 2;
            remaining -= 510;
        }
        if (remaining >= 255) {
            op.*[0] = 255;
            op.* += 1;
            remaining -= 255;
        }
        op.*[0] = @truncate(remaining);
        op.* += 1;
    } else {
        token[0] += @truncate(mlCode);
    }

    // Prepare for next loop
    ip.* += @intCast(matchLength);
    anchor.* = ip.*;

    return 0;
}

// ===== Data Structures =====

/// Compression context for LZ4 HC
pub const Context = struct {
    hashTable: [LZ4HC_HASHTABLESIZE]u32,
    chainTable: [LZ4HC_MAXD]u16,
    end: [*]const u8, // next block here to continue on current prefix
    prefixStart: [*]const u8, // Indexes relative to this position
    dictStart: [*]const u8, // alternate reference for extDict
    dictLimit: u32, // below that point, need extDict
    lowLimit: u32, // below that point, no more history
    nextToUpdate: u32, // index from which to continue dictionary update
    compressionLevel: i16,
    favorDecSpeed: i8, // favor decompression speed if this flag set
    dirty: i8, // stream has to be fully reset if this flag is set
    dictCtx: ?*const Context,

    pub fn init() Context {
        return .{
            .hashTable = [_]u32{0} ** LZ4HC_HASHTABLESIZE,
            .chainTable = [_]u16{0} ** LZ4HC_MAXD,
            .end = undefined,
            .prefixStart = undefined,
            .dictStart = undefined,
            .dictLimit = 0,
            .lowLimit = 0,
            .nextToUpdate = 0,
            .compressionLevel = LZ4HC_CLEVEL_DEFAULT,
            .favorDecSpeed = 0,
            .dirty = 0,
            .dictCtx = null,
        };
    }

    pub fn clearTables(self: *Context) void {
        @memset(&self.hashTable, 0);
        @memset(&self.chainTable, 0xFF); // Chain table is initialized to 0xFF
    }

    pub fn initContext(self: *Context, start: [*]const u8) void {
        const bufferSize: usize = @intFromPtr(self.end) - @intFromPtr(self.prefixStart);
        var newStartingOffset: usize = bufferSize + self.dictLimit;

        // Check for overflow and reset if needed
        if (newStartingOffset > 1024 * 1024 * 1024) { // 1 GB
            self.clearTables();
            newStartingOffset = 0;
        }

        newStartingOffset += 64 * 1024; // 64 KB

        self.nextToUpdate = @intCast(newStartingOffset);
        self.prefixStart = start;
        self.end = start;
        self.dictStart = start;
        self.dictLimit = @intCast(newStartingOffset);
        self.lowLimit = @intCast(newStartingOffset);
    }
};

/// Match result structure
pub const Match = struct {
    off: i32, // offset
    len: i32, // length
    back: i32, // backward extension (negative value)
};

/// Optimal match entry for dynamic programming (optimal parser)
const OptimalMatch = struct {
    price: i32, // cost in bytes to reach this position
    off: i32, // match offset (0 for literal)
    mlen: i32, // match length (1 for literal)
    litlen: i32, // total literal length
};

// ===== Cost Calculation Functions (for Optimal Parser) =====

/// Calculate the byte cost of encoding literals
inline fn literalsPrice(litlen: i32) i32 {
    var price: i32 = litlen;
    if (litlen >= @as(i32, RUN_MASK)) {
        price += 1 + @divTrunc(litlen - @as(i32, RUN_MASK), 255);
    }
    return price;
}

/// Calculate the byte cost of a sequence (literals + match)
/// Requires mlen >= MINMATCH
inline fn sequencePrice(litlen: i32, mlen: i32) i32 {
    var price: i32 = 1 + 2; // token + 16-bit offset

    price += literalsPrice(litlen);

    if (mlen >= @as(i32, ML_MASK + MINMATCH)) {
        price += 1 + @divTrunc(mlen - @as(i32, ML_MASK + MINMATCH), 255);
    }

    return price;
}

// ===== Chain Table Management =====

/// Update hash and chain tables up to ip (excluded)
fn insertHC(ctx: *Context, ip: [*]const u8) void {
    const prefixPtr = ctx.prefixStart;
    const prefixIdx = ctx.dictLimit;
    const target: u32 = @intCast((@intFromPtr(ip) - @intFromPtr(prefixPtr)) + prefixIdx);
    var idx = ctx.nextToUpdate;

    while (idx < target) {
        const offset: usize = @intCast(idx - prefixIdx);
        const h = hashPtr(prefixPtr + offset);
        const prevIdx = ctx.hashTable[h];
        // Calculate delta, handling overflow when prevIdx > idx
        const delta: u32 = if (prevIdx > idx) LZ4_DISTANCE_MAX + 1 else idx - prevIdx;
        const deltaClamped: u16 = if (delta > LZ4_DISTANCE_MAX) LZ4_DISTANCE_MAX else @intCast(delta);
        ctx.chainTable[idx & LZ4HC_MAXD_MASK] = deltaClamped;
        ctx.hashTable[h] = idx;
        idx += 1;
    }

    ctx.nextToUpdate = target;
}

/// Insert and find the best match at given position
/// Returns the match with maximum length
fn insertAndFindBestMatch(
    ctx: *Context,
    ip: [*]const u8,
    iLimit: [*]const u8,
    maxNbAttempts: i32,
    patternAnalysis: bool,
) Match {
    // Insert all positions up to ip
    insertHC(ctx, ip);

    // Search for best match
    return insertAndGetWiderMatch(
        ctx,
        ip,
        ip, // iLowLimit = ip (no backward extension)
        iLimit,
        MINMATCH - 1, // longest = MINMATCH - 1
        maxNbAttempts,
        patternAnalysis,
        false, // chainSwap
    );
}

/// Core match finding function with backward extension support
fn insertAndGetWiderMatch(
    ctx: *Context,
    ip: [*]const u8,
    iLowLimit: [*]const u8,
    iHighLimit: [*]const u8,
    longest: i32,
    maxNbAttempts: i32,
    patternAnalysis: bool,
    chainSwap: bool,
) Match {
    _ = chainSwap; // TODO: implement chain swap optimization

    const prefixPtr = ctx.prefixStart;
    const prefixIdx = ctx.dictLimit;
    const ipIndex: u32 = @intCast((@intFromPtr(ip) - @intFromPtr(prefixPtr)) + prefixIdx);
    const withinStartDistance = (ctx.lowLimit + (LZ4_DISTANCE_MAX + 1) > ipIndex);
    const lowestMatchIndex: u32 = if (withinStartDistance) ctx.lowLimit else ipIndex - LZ4_DISTANCE_MAX;
    const dictStart = ctx.dictStart;
    const dictIdx = ctx.lowLimit;
    var nbAttempts = maxNbAttempts;
    const pattern = readU32LE(ip);

    var result = Match{ .off = 0, .len = longest, .back = 0 };

    // Get first match from hash table
    var matchIndex = ctx.hashTable[hashPtr(ip)];

    // Check if hash table entry is valid (matchIndex == 0 means uninitialized)
    if (matchIndex == 0) {
        return result;
    }

    // Search through the chain
    while ((matchIndex > 0) and (nbAttempts > 0)) {
        // Check distance (avoid overflow when matchIndex > ipIndex)
        if (matchIndex > ipIndex or (ipIndex - matchIndex) > LZ4_DISTANCE_MAX) {
            break;
        }

        nbAttempts -= 1;

        if (matchIndex >= lowestMatchIndex) {
            const matchPtr: [*]const u8 = if (matchIndex >= dictIdx)
                prefixPtr + (matchIndex - prefixIdx)
            else
                dictStart + (matchIndex - ctx.lowLimit);

            // Check if first 4 bytes match
            if (readU32LE(matchPtr) == pattern) {
                // Count forward match
                const mlt: i32 = @intCast(MINMATCH + lz4Count(
                    ip + MINMATCH,
                    matchPtr + MINMATCH,
                    iHighLimit,
                ));

                var back: i32 = 0;
                // Count backward if allowed
                if (@intFromPtr(ip) > @intFromPtr(iLowLimit)) {
                    const mMin = if (matchIndex >= dictIdx)
                        prefixPtr
                    else
                        dictStart;
                    back = countBack(ip, matchPtr, iLowLimit, mMin);
                }

                const totalLength = mlt - back;

                // Update best match if this one is longer
                if (totalLength > result.len) {
                    result.len = totalLength;
                    result.off = @intCast(ipIndex - matchIndex);
                    result.back = back;

                    // Early exit if we found a very good match
                    if (totalLength > maxNbAttempts) break;
                }
            }
        }

        // Follow the chain
        const delta = ctx.chainTable[matchIndex & LZ4HC_MAXD_MASK];
        if (delta == 0 or delta > matchIndex) break;
        matchIndex -= delta;
    }

    // Pattern analysis for level 9+
    // Only activated when patternAnalysis == true and we detect a repeated pattern
    if (patternAnalysis and result.len > 0) {
        const delta = ctx.chainTable[matchIndex & LZ4HC_MAXD_MASK];
        // distNextMatch == 1 indicates possible repeated pattern
        if (delta == 1) {
            // Check if pattern is repetitive
            if (isRepetitivePattern(pattern)) {
                // Count pattern length at source
                const srcPatternLength = countPattern(ip + 4, iHighLimit, pattern) + 4;

                // Try to find better match position by looking at pattern candidate
                const matchCandidateIdx = matchIndex - 1;
                if (matchCandidateIdx >= lowestMatchIndex and matchCandidateIdx >= dictIdx) {
                    const matchPtr: [*]const u8 = if (matchCandidateIdx >= dictIdx)
                        prefixPtr + (matchCandidateIdx - prefixIdx)
                    else
                        dictStart + (matchCandidateIdx - ctx.lowLimit);

                    // Verify pattern matches
                    if (readU32LE(matchPtr) == pattern) {
                        // Count pattern forward from match
                        const forwardPatternLength = countPattern(matchPtr + 4, iHighLimit, pattern) + 4;

                        // Count pattern backward from match
                        const lowestMatchPtr = if (matchCandidateIdx >= dictIdx) prefixPtr else dictStart;
                        const backLength = reverseCountPattern(matchPtr, lowestMatchPtr, pattern);

                        // Limit backLength to not go before lowestMatchIndex
                        const limitedBackLength = matchCandidateIdx - @max(matchCandidateIdx - @as(u32, @intCast(backLength)), lowestMatchIndex);
                        const currentSegmentLength = limitedBackLength + forwardPatternLength;

                        // Choose optimal match position
                        var newMatchIndex = matchCandidateIdx;
                        const maxML: i32 = @intCast(@min(currentSegmentLength, srcPatternLength));

                        if (currentSegmentLength >= srcPatternLength and forwardPatternLength <= srcPatternLength) {
                            // Position at end of pattern
                            newMatchIndex = matchCandidateIdx + @as(u32, @intCast(forwardPatternLength)) - @as(u32, @intCast(srcPatternLength));
                        } else {
                            // Position at beginning of pattern
                            newMatchIndex = matchCandidateIdx - @as(u32, @intCast(limitedBackLength));
                        }

                        // Update result if this match is better
                        if (maxML > result.len and (ipIndex - newMatchIndex) <= LZ4_DISTANCE_MAX) {
                            result.len = maxML;
                            result.off = @intCast(ipIndex - newMatchIndex);
                            result.back = 0; // No backward extension for pattern matches
                        }
                    }
                }
            }
        }
    }

    return result;
}

// ===== LZ4MID Compression =====

/// LZ4MID compression using dual hash tables (4-byte and 8-byte)
/// This is the level 2 algorithm - very fast with only 2 hash lookups
fn compressMID(
    ctx: *Context,
    src: []const u8,
    dst: []u8,
) Error!usize {
    const inputSize = src.len;

    // Set up pointers
    var ip: [*]const u8 = src.ptr;
    var anchor: [*]const u8 = ip;
    const iend: [*]const u8 = ip + inputSize;
    const mflimit: [*]const u8 = iend - MFLIMIT;
    const matchlimit: [*]const u8 = iend - LASTLITERALS;
    const ilimit: [*]const u8 = iend - LZ4MID_HASHSIZE;

    var op: [*]u8 = dst.ptr;
    const oend: [*]u8 = op + dst.len;

    // Check minimum input size
    if (inputSize < MFLIMIT + 1) {
        return try encodeLiterals(src, dst);
    }

    // Initialize context
    ctx.nextToUpdate = 0;
    ctx.prefixStart = src.ptr;
    ctx.end = src.ptr + src.len;
    ctx.dictStart = src.ptr;
    ctx.dictLimit = 0;
    ctx.lowLimit = 0;

    // Split hash table into 4-byte and 8-byte sections
    // hash4Table = ctx.hashTable[0..LZ4MID_HASHTABLESIZE]
    // hash8Table = ctx.hashTable[LZ4MID_HASHTABLESIZE..(2*LZ4MID_HASHTABLESIZE)]
    const hash4Table = ctx.hashTable[0..LZ4MID_HASHTABLESIZE];
    const hash8Table = ctx.hashTable[LZ4MID_HASHTABLESIZE .. 2 * LZ4MID_HASHTABLESIZE];

    // Clear tables
    @memset(hash4Table, 0);
    @memset(hash8Table, 0);

    const prefixPtr = ctx.prefixStart;
    const prefixIdx = ctx.dictLimit;
    const ilimitIdx: u32 = @intCast((@intFromPtr(ilimit) - @intFromPtr(prefixPtr)) + prefixIdx);

    // Main compression loop
    while (@intFromPtr(ip) <= @intFromPtr(mflimit)) {
        const ipIndex: u32 = @intCast((@intFromPtr(ip) - @intFromPtr(prefixPtr)) + prefixIdx);
        var matchLength: u32 = 0;
        var matchDistance: u32 = 0;

        // Search long match (8-byte hash)
        {
            const h8 = hashMid8Ptr(ip);
            const pos8 = hash8Table[h8];
            hash8Table[h8] = ipIndex; // Update table

            if (pos8 > 0 and ipIndex - pos8 <= LZ4_DISTANCE_MAX) {
                // Match candidate found
                if (pos8 >= prefixIdx) {
                    const matchPtr = prefixPtr + (pos8 - prefixIdx);
                    if (@intFromPtr(matchPtr) < @intFromPtr(ip)) {
                        const mlt = lz4Count(ip, matchPtr, matchlimit);
                        if (mlt >= MINMATCH) {
                            matchLength = @intCast(mlt);
                            matchDistance = ipIndex - pos8;
                            // Found good long match, encode it
                            // Catch back - extend match backward (disabled for now)
                            // while (@intFromPtr(ip) > @intFromPtr(anchor) and
                            //     matchDistance < (@intFromPtr(ip) - @intFromPtr(prefixPtr)))
                            // {
                            //     const matchPos = ip - matchDistance - 1;
                            //     if (@intFromPtr(matchPos) < @intFromPtr(prefixPtr)) break;
                            //     if ((ip - 1)[0] != matchPos[0]) break;
                            //     ip -= 1;
                            //     matchLength += 1;
                            // }
                            // Use original ipIndex (no backward extension)
                            const finalIpIndex: u32 = ipIndex;
                            // Fill tables with beginning of match
                            if (@intFromPtr(ip) + 1 <= @intFromPtr(ilimit)) {
                                hash8Table[hashMid8Ptr(ip + 1)] = finalIpIndex + 1;
                            }
                            if (@intFromPtr(ip) + 2 <= @intFromPtr(ilimit)) {
                                hash8Table[hashMid8Ptr(ip + 2)] = finalIpIndex + 2;
                            }
                            if (@intFromPtr(ip) + 1 <= @intFromPtr(ilimit)) {
                                hash4Table[hashMid4Ptr(ip + 1)] = finalIpIndex + 1;
                            }
                            // Encode sequence
                            const encodeResult = encodeSequence(
                                &ip,
                                &op,
                                &anchor,
                                @intCast(matchLength),
                                @intCast(matchDistance),
                                .limitedOutput,
                                oend,
                            );
                            if (encodeResult != 0) {
                                return Error.OutputTooSmall;
                            }
                            // Fill table with end of match
                            const endMatchIdx: u32 = @intCast((@intFromPtr(ip) - @intFromPtr(prefixPtr)) + prefixIdx);
                            const pos_m2 = endMatchIdx - 2;
                            if (pos_m2 < ilimitIdx) {
                                if (@intFromPtr(ip) - @intFromPtr(prefixPtr) > 5) {
                                    const ip5: [*]const u8 = ip - 5;
                                    if (@intFromPtr(ip5) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip5)] = endMatchIdx - 5;
                                    }
                                }
                                if (@intFromPtr(ip) >= 3) {
                                    const ip3 = ip - 3;
                                    if (@intFromPtr(ip3) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip3)] = endMatchIdx - 3;
                                    }
                                }
                                if (@intFromPtr(ip) >= 2) {
                                    const ip2 = ip - 2;
                                    if (@intFromPtr(ip2) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip2)] = endMatchIdx - 2;
                                        hash4Table[hashMid4Ptr(ip2)] = endMatchIdx - 2;
                                    }
                                }
                                if (@intFromPtr(ip) >= 1) {
                                    const ip1 = ip - 1;
                                    if (@intFromPtr(ip1) <= @intFromPtr(ilimit)) {
                                        hash4Table[hashMid4Ptr(ip1)] = endMatchIdx - 1;
                                    }
                                }
                            }
                            continue;
                        }
                    }
                }
            }
        }

        // Search short match (4-byte hash)
        {
            const h4 = hashMid4Ptr(ip);
            const pos4 = hash4Table[h4];
            hash4Table[h4] = ipIndex; // Update table

            if (pos4 > 0 and ipIndex - pos4 <= LZ4_DISTANCE_MAX) {
                // Match candidate found
                if (pos4 >= prefixIdx) {
                    const matchPtr = prefixPtr + (pos4 - prefixIdx);
                    if (@intFromPtr(matchPtr) < @intFromPtr(ip)) {
                        matchLength = @intCast(lz4Count(ip, matchPtr, matchlimit));
                        if (matchLength >= MINMATCH) {
                            matchDistance = ipIndex - pos4;

                            // Short match found, check ip+1 for longer match
                            if (@intFromPtr(ip) < @intFromPtr(mflimit)) {
                                const h8_next = hashMid8Ptr(ip + 1);
                                const pos8_next = hash8Table[h8_next];
                                const m2Distance = ipIndex + 1 - pos8_next;

                                if (m2Distance <= LZ4_DISTANCE_MAX and pos8_next >= prefixIdx and pos8_next > 0) {
                                    const m2Ptr = prefixPtr + (pos8_next - prefixIdx);
                                    if (@intFromPtr(m2Ptr) < @intFromPtr(ip) + 1) {
                                        const ml2 = lz4Count(ip + 1, m2Ptr, matchlimit);
                                        if (ml2 > matchLength) {
                                            hash8Table[h8_next] = ipIndex + 1;
                                            ip += 1;
                                            matchLength = @intCast(ml2);
                                            matchDistance = m2Distance;
                                        }
                                    }
                                }
                            }

                            // Catch back - extend match backward (disabled for now)
                            // while (@intFromPtr(ip) > @intFromPtr(anchor) and
                            //     matchDistance < (@intFromPtr(ip) - @intFromPtr(prefixPtr)))
                            // {
                            //     const matchPos = ip - matchDistance - 1;
                            //     if (@intFromPtr(matchPos) < @intFromPtr(prefixPtr)) break;
                            //     if ((ip - 1)[0] != matchPos[0]) break;
                            //     ip -= 1;
                            //     matchLength += 1;
                            // }

                            // Use original ipIndex (no backward extension)
                            const finalIpIndex4: u32 = ipIndex;
                            // Fill tables with beginning of match
                            if (@intFromPtr(ip) + 1 <= @intFromPtr(ilimit)) {
                                hash8Table[hashMid8Ptr(ip + 1)] = finalIpIndex4 + 1;
                            }
                            if (@intFromPtr(ip) + 2 <= @intFromPtr(ilimit)) {
                                hash8Table[hashMid8Ptr(ip + 2)] = finalIpIndex4 + 2;
                            }
                            if (@intFromPtr(ip) + 1 <= @intFromPtr(ilimit)) {
                                hash4Table[hashMid4Ptr(ip + 1)] = finalIpIndex4 + 1;
                            }

                            // Encode sequence
                            const encodeResult = encodeSequence(
                                &ip,
                                &op,
                                &anchor,
                                @intCast(matchLength),
                                @intCast(matchDistance),
                                .limitedOutput,
                                oend,
                            );
                            if (encodeResult != 0) {
                                return Error.OutputTooSmall;
                            }

                            // Fill table with end of match
                            const endMatchIdx: u32 = @intCast((@intFromPtr(ip) - @intFromPtr(prefixPtr)) + prefixIdx);
                            const pos_m2 = endMatchIdx - 2;
                            if (pos_m2 < ilimitIdx) {
                                if (@intFromPtr(ip) - @intFromPtr(prefixPtr) > 5) {
                                    const ip5: [*]const u8 = ip - 5;
                                    if (@intFromPtr(ip5) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip5)] = endMatchIdx - 5;
                                    }
                                }
                                if (@intFromPtr(ip) >= 3) {
                                    const ip3 = ip - 3;
                                    if (@intFromPtr(ip3) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip3)] = endMatchIdx - 3;
                                    }
                                }
                                if (@intFromPtr(ip) >= 2) {
                                    const ip2 = ip - 2;
                                    if (@intFromPtr(ip2) <= @intFromPtr(ilimit)) {
                                        hash8Table[hashMid8Ptr(ip2)] = endMatchIdx - 2;
                                        hash4Table[hashMid4Ptr(ip2)] = endMatchIdx - 2;
                                    }
                                }
                                if (@intFromPtr(ip) >= 1) {
                                    const ip1 = ip - 1;
                                    if (@intFromPtr(ip1) <= @intFromPtr(ilimit)) {
                                        hash4Table[hashMid4Ptr(ip1)] = endMatchIdx - 1;
                                    }
                                }
                            }
                            continue;
                        }
                    }
                }
            }
        }

        // No match found, skip forward (faster over incompressible data)
        const skipAmount: usize = 1 + ((@intFromPtr(ip) - @intFromPtr(anchor)) >> 9);
        ip += skipAmount;
    }

    // Encode remaining literals
    const finalLiterals: usize = @intFromPtr(iend) - @intFromPtr(anchor);
    if (finalLiterals > 0) {
        if (@intFromPtr(op) + finalLiterals + 1 > @intFromPtr(oend)) {
            return Error.OutputTooSmall;
        }

        // Encode literal-only token
        if (finalLiterals >= RUN_MASK) {
            var len = finalLiterals - RUN_MASK;
            op[0] = RUN_MASK << ML_BITS;
            op += 1;
            while (len >= 255) {
                op[0] = 255;
                op += 1;
                len -= 255;
            }
            op[0] = @truncate(len);
            op += 1;
        } else {
            op[0] = @as(u8, @truncate(finalLiterals)) << ML_BITS;
            op += 1;
        }

        // Copy final literals
        @memcpy(op[0..finalLiterals], anchor[0..finalLiterals]);
        op += finalLiterals;
    }

    return @intFromPtr(op) - @intFromPtr(dst.ptr);
}

// ===== LZ4HC Compression =====

/// Main HC compression function using hash chains
fn compressHashChain(
    ctx: *Context,
    src: []const u8,
    dst: []u8,
    maxNbAttempts: i32,
) Error!usize {
    const inputSize = src.len;
    const patternAnalysis = (maxNbAttempts > 128); // levels 9+

    var ip: [*]const u8 = src.ptr;
    var anchor: [*]const u8 = ip;
    const iend: [*]const u8 = ip + inputSize;
    const mflimit: [*]const u8 = iend - MFLIMIT;
    const matchlimit: [*]const u8 = iend - LASTLITERALS;

    var op: [*]u8 = dst.ptr;
    const oend: [*]u8 = op + dst.len;

    // Check minimum input size
    if (inputSize < MFLIMIT + 1) {
        // Input too small, just copy as literals
        return try encodeLiterals(src, dst);
    }

    // Initialize context
    ctx.nextToUpdate = 0;
    ctx.prefixStart = src.ptr;
    ctx.end = src.ptr + src.len;
    ctx.dictStart = src.ptr;
    ctx.dictLimit = 0;
    ctx.lowLimit = 0;

    // Main compression loop
    while (@intFromPtr(ip) <= @intFromPtr(mflimit)) {
        // Find best match at current position
        const match = insertAndFindBestMatch(ctx, ip, matchlimit, maxNbAttempts, patternAnalysis);

        if (match.len < MINMATCH or match.off == 0) {
            ip += 1;
            continue;
        }

        // Encode the match
        const encodeResult = encodeSequence(
            &ip,
            &op,
            &anchor,
            match.len,
            match.off,
            .limitedOutput,
            oend,
        );

        if (encodeResult != 0) {
            return Error.OutputTooSmall;
        }
    }

    // Encode remaining literals
    const finalLiterals: usize = @intFromPtr(iend) - @intFromPtr(anchor);
    if (finalLiterals > 0) {
        if (@intFromPtr(op) + finalLiterals + 1 > @intFromPtr(oend)) {
            return Error.OutputTooSmall;
        }

        // Encode literal-only token
        if (finalLiterals >= RUN_MASK) {
            var len = finalLiterals - RUN_MASK;
            op[0] = RUN_MASK << ML_BITS;
            op += 1;
            while (len >= 255) {
                op[0] = 255;
                op += 1;
                len -= 255;
            }
            op[0] = @truncate(len);
            op += 1;
        } else {
            op[0] = @as(u8, @truncate(finalLiterals)) << ML_BITS;
            op += 1;
        }

        // Copy final literals
        @memcpy(op[0..finalLiterals], anchor[0..finalLiterals]);
        op += finalLiterals;
    }

    return @intFromPtr(op) - @intFromPtr(dst.ptr);
}

/// Optimal parser compression (levels 10-12)
/// Uses dynamic programming to find the optimal sequence of matches
fn compressOptimal(
    ctx: *Context,
    src: []const u8,
    dst: []u8,
    nbSearches: i32,
    sufficientLen: usize,
) Error!usize {
    const TRAILING_LITERALS = 3;

    // Stack-allocate the optimal array (4096 + 3 entries)
    // This is about 64KB which should be fine for most stacks
    var opt: [LZ4_OPT_NUM + TRAILING_LITERALS]OptimalMatch = undefined;

    const inputSize = src.len;
    var ip: [*]const u8 = src.ptr;
    var anchor: [*]const u8 = ip;
    const iend: [*]const u8 = ip + inputSize;
    const mflimit: [*]const u8 = iend - MFLIMIT;
    const matchlimit: [*]const u8 = iend - LASTLITERALS;

    var op: [*]u8 = dst.ptr;
    const oend: [*]u8 = op + dst.len;

    // Check minimum input size
    if (inputSize < MFLIMIT + 1) {
        return try encodeLiterals(src, dst);
    }

    // Initialize context
    ctx.nextToUpdate = 0;
    ctx.prefixStart = src.ptr;
    ctx.end = src.ptr + src.len;
    ctx.dictStart = src.ptr;
    ctx.dictLimit = 0;
    ctx.lowLimit = 0;

    // Clamp sufficient length
    var sufficient_len = sufficientLen;
    if (sufficient_len >= LZ4_OPT_NUM) {
        sufficient_len = LZ4_OPT_NUM - 1;
    }

    // Main compression loop
    outer: while (@intFromPtr(ip) <= @intFromPtr(mflimit)) {
        const llen: i32 = @intCast(@intFromPtr(ip) - @intFromPtr(anchor));

        // Find first match
        insertHC(ctx, ip);
        const firstMatch = insertAndGetWiderMatch(
            ctx,
            ip,
            ip, // iLowLimit
            matchlimit,
            MINMATCH - 1,
            nbSearches,
            true, // patternAnalysis for optimal
            false, // chainSwap
        );

        if (firstMatch.len == 0) {
            ip += 1;
            continue;
        }

        // If match is good enough, encode immediately
        if (@as(usize, @intCast(firstMatch.len)) > sufficient_len) {
            const encodeResult = encodeSequence(
                &ip,
                &op,
                &anchor,
                firstMatch.len,
                firstMatch.off,
                .limitedOutput,
                oend,
            );
            if (encodeResult != 0) {
                return Error.OutputTooSmall;
            }
            continue;
        }

        // Set prices for first positions (literals)
        var rPos: usize = 0;
        while (rPos < MINMATCH) : (rPos += 1) {
            const cost = literalsPrice(llen + @as(i32, @intCast(rPos)));
            opt[rPos].mlen = 1;
            opt[rPos].off = 0;
            opt[rPos].litlen = llen + @as(i32, @intCast(rPos));
            opt[rPos].price = cost;
        }

        // Set prices using initial match
        const matchML: usize = @intCast(firstMatch.len);
        const offset = firstMatch.off;
        var mlen: usize = MINMATCH;
        while (mlen <= matchML) : (mlen += 1) {
            const cost = sequencePrice(llen, @intCast(mlen));
            opt[mlen].mlen = @intCast(mlen);
            opt[mlen].off = offset;
            opt[mlen].litlen = llen;
            opt[mlen].price = cost;
        }

        var last_match_pos: usize = matchML;

        // Add trailing literals after first match
        var addLit: usize = 1;
        while (addLit <= TRAILING_LITERALS) : (addLit += 1) {
            opt[last_match_pos + addLit].mlen = 1;
            opt[last_match_pos + addLit].off = 0;
            opt[last_match_pos + addLit].litlen = @intCast(addLit);
            opt[last_match_pos + addLit].price = opt[last_match_pos].price + literalsPrice(@intCast(addLit));
        }

        // Check further positions
        var cur: usize = 1;
        while (cur < last_match_pos) : (cur += 1) {
            const curPtr: [*]const u8 = ip + cur;

            if (@intFromPtr(curPtr) > @intFromPtr(mflimit)) break;

            // Skip if next position has same or lower cost
            if (opt[cur + 1].price <= opt[cur].price) continue;

            // Search for matches at this position
            insertHC(ctx, curPtr);
            const newMatch = insertAndGetWiderMatch(
                ctx,
                curPtr,
                curPtr,
                matchlimit,
                MINMATCH - 1,
                nbSearches,
                true, // patternAnalysis
                false, // chainSwap
            );

            if (newMatch.len == 0) continue;

            // If match is too long or good enough, encode immediately
            if ((@as(usize, @intCast(newMatch.len)) > sufficient_len) or
                (newMatch.len + @as(i32, @intCast(cur)) >= @as(i32, LZ4_OPT_NUM)))
            {
                // Backtrack from cur and encode
                const best_mlen = newMatch.len;
                const best_off = newMatch.off;

                // Encode sequences up to cur
                var rp: usize = 0;
                while (rp < cur) {
                    const ml = opt[rp].mlen;
                    const off = opt[rp].off;
                    if (ml == 1) {
                        ip += 1;
                        rp += 1;
                        continue;
                    }
                    rp += @intCast(ml);
                    const encodeResult = encodeSequence(
                        &ip,
                        &op,
                        &anchor,
                        ml,
                        off,
                        .limitedOutput,
                        oend,
                    );
                    if (encodeResult != 0) {
                        return Error.OutputTooSmall;
                    }
                }

                // Encode the new match
                const encodeResult = encodeSequence(
                    &ip,
                    &op,
                    &anchor,
                    best_mlen,
                    best_off,
                    .limitedOutput,
                    oend,
                );
                if (encodeResult != 0) {
                    return Error.OutputTooSmall;
                }

                // Continue to next iteration of main loop
                continue :outer;
            }

            // Set prices with literals before match
            const baseLitlen = opt[cur].litlen;
            var litlen: usize = 1;
            while (litlen < MINMATCH) : (litlen += 1) {
                const price = opt[cur].price - literalsPrice(baseLitlen) + literalsPrice(baseLitlen + @as(i32, @intCast(litlen)));
                const pos = cur + litlen;
                if (price < opt[pos].price) {
                    opt[pos].mlen = 1;
                    opt[pos].off = 0;
                    opt[pos].litlen = baseLitlen + @as(i32, @intCast(litlen));
                    opt[pos].price = price;
                }
            }

            // Set prices using match at position cur
            const newMatchML: usize = @intCast(newMatch.len);
            var ml: usize = MINMATCH;
            while (ml <= newMatchML) : (ml += 1) {
                const pos = cur + ml;
                const newOffset = newMatch.off;
                var price: i32 = undefined;
                var ll: i32 = undefined;

                if (opt[cur].mlen == 1) {
                    ll = opt[cur].litlen;
                    price = if (cur > @as(usize, @intCast(ll)))
                        opt[cur - @as(usize, @intCast(ll))].price
                    else
                        0;
                    price += sequencePrice(ll, @intCast(ml));
                } else {
                    ll = 0;
                    price = opt[cur].price + sequencePrice(0, @intCast(ml));
                }

                if (pos > last_match_pos + TRAILING_LITERALS or price <= opt[pos].price) {
                    if ((ml == newMatchML) and (last_match_pos < pos)) {
                        last_match_pos = pos;
                    }
                    opt[pos].mlen = @intCast(ml);
                    opt[pos].off = newOffset;
                    opt[pos].litlen = ll;
                    opt[pos].price = price;
                }
            }

            // Complete following positions with literals
            addLit = 1;
            while (addLit <= TRAILING_LITERALS) : (addLit += 1) {
                opt[last_match_pos + addLit].mlen = 1;
                opt[last_match_pos + addLit].off = 0;
                opt[last_match_pos + addLit].litlen = @intCast(addLit);
                opt[last_match_pos + addLit].price = opt[last_match_pos].price + literalsPrice(@intCast(addLit));
            }
        }

        // Backtrack to find optimal path
        const best_mlen = opt[last_match_pos].mlen;
        const best_off = opt[last_match_pos].off;
        cur = last_match_pos - @as(usize, @intCast(best_mlen));

        // Reverse traversal to reconstruct path
        var candidate_pos: usize = cur;
        var selected_matchLength = best_mlen;
        var selected_offset = best_off;
        while (true) {
            const next_matchLength = opt[candidate_pos].mlen;
            const next_offset = opt[candidate_pos].off;
            opt[candidate_pos].mlen = selected_matchLength;
            opt[candidate_pos].off = selected_offset;
            selected_matchLength = next_matchLength;
            selected_offset = next_offset;
            if (next_matchLength > @as(i32, @intCast(candidate_pos))) break;
            candidate_pos -= @as(usize, @intCast(next_matchLength));
        }

        // Encode all recorded sequences in order
        rPos = 0;
        while (rPos < last_match_pos) {
            const ml = opt[rPos].mlen;
            const off = opt[rPos].off;
            if (ml == 1) {
                ip += 1;
                rPos += 1;
                continue;
            }
            rPos += @intCast(ml);

            const encodeResult = encodeSequence(
                &ip,
                &op,
                &anchor,
                ml,
                off,
                .limitedOutput,
                oend,
            );
            if (encodeResult != 0) {
                return Error.OutputTooSmall;
            }
        }
    }

    // Encode remaining literals
    const finalLiterals: usize = @intFromPtr(iend) - @intFromPtr(anchor);
    if (finalLiterals > 0) {
        if (@intFromPtr(op) + finalLiterals + 1 > @intFromPtr(oend)) {
            return Error.OutputTooSmall;
        }

        // Encode literal-only token
        if (finalLiterals >= RUN_MASK) {
            var len = finalLiterals - RUN_MASK;
            op[0] = RUN_MASK << ML_BITS;
            op += 1;
            while (len >= 255) {
                op[0] = 255;
                op += 1;
                len -= 255;
            }
            op[0] = @truncate(len);
            op += 1;
        } else {
            op[0] = @as(u8, @truncate(finalLiterals)) << ML_BITS;
            op += 1;
        }

        // Copy final literals
        @memcpy(op[0..finalLiterals], anchor[0..finalLiterals]);
        op += finalLiterals;
    }

    return @intFromPtr(op) - @intFromPtr(dst.ptr);
}

/// Encode input as all literals (used for incompressible data)
fn encodeLiterals(src: []const u8, dst: []u8) Error!usize {
    if (dst.len < src.len + 1 + (src.len / 255)) {
        return Error.OutputTooSmall;
    }

    var op: [*]u8 = dst.ptr;
    const anchor: [*]const u8 = src.ptr;
    const litLen = src.len;

    // Encode literal length
    if (litLen >= RUN_MASK) {
        var len = litLen - RUN_MASK;
        op[0] = RUN_MASK << ML_BITS;
        op += 1;
        while (len >= 255) {
            op[0] = 255;
            op += 1;
            len -= 255;
        }
        op[0] = @truncate(len);
        op += 1;
    } else {
        op[0] = @as(u8, @truncate(litLen)) << ML_BITS;
        op += 1;
    }

    // Copy literals
    @memcpy(op[0..litLen], anchor[0..litLen]);
    op += litLen;

    return @intFromPtr(op) - @intFromPtr(dst.ptr);
}

// ===== Public API =====

/// Calculate maximum size needed for compressed output
pub fn compressBound(inputSize: usize) usize {
    return lz4.compressBound(inputSize);
}

/// Compress with HC mode at specified compression level
/// level: Compression level (2-12), higher = better compression but slower
///   - Level 2: LZ4MID (fastest HC)
///   - Levels 3-9: LZ4HC (progressive search depth)
///   - Levels 10-12: LZ4OPT (optimal parser, slowest but best compression)
/// Returns: number of bytes written to dst, or error
pub fn compressHC(src: []const u8, dst: []u8, compressionLevel: i32) Error!usize {
    // Input validation
    if (src.len > LZ4_MAX_INPUT_SIZE) return Error.InputTooLarge;
    if (src.len == 0) return 0;

    const level = if (compressionLevel < LZ4HC_CLEVEL_MIN) LZ4HC_CLEVEL_DEFAULT else if (compressionLevel > LZ4HC_CLEVEL_MAX) LZ4HC_CLEVEL_MAX else compressionLevel;

    // Allocate compression context on stack
    // Note: This is ~256KB, which is large for stack allocation
    // For production use, consider heap allocation or external state
    var ctx = Context.init();

    return compressHCExtState(&ctx, src, dst, level);
}

/// Compress with HC mode using external state
/// This allows the caller to manage memory allocation
pub fn compressHCExtState(ctx: *Context, src: []const u8, dst: []u8, compressionLevel: i32) Error!usize {
    // Input validation
    if (src.len > LZ4_MAX_INPUT_SIZE) return Error.InputTooLarge;
    if (src.len == 0) return 0;
    if (dst.len == 0) return Error.OutputTooSmall;

    // Normalize compression level
    var level = compressionLevel;
    if (level < 1) level = LZ4HC_CLEVEL_DEFAULT;
    if (level > LZ4HC_CLEVEL_MAX) level = LZ4HC_CLEVEL_MAX;

    // Get compression parameters for this level
    const params = getCLevelParams(level);

    // Store compression level in context
    ctx.compressionLevel = @intCast(level);

    // Route to appropriate compression strategy
    switch (params.strat) {
        .lz4hc => {
            // Levels 3-9: Hash chain based compression
            return try compressHashChain(ctx, src, dst, params.nbSearches);
        },
        .lz4mid => {
            // Level 2: Dual hash tables (fast HC mode)
            return try compressMID(ctx, src, dst);
        },
        .lz4opt => {
            // Levels 10-12: Optimal parser with dynamic programming
            return try compressOptimal(ctx, src, dst, params.nbSearches, params.targetLength);
        },
    }
}

/// Get the size of the compression context
pub fn sizeofStateHC() usize {
    return @sizeOf(Context);
}

// ===== Streaming API Helper Functions =====

/// Insert positions into hash chain, used for dictionary loading
fn insertRange(ctx: *Context, base: [*]const u8, end: [*]const u8) void {
    const iend = end;
    var ip = base;

    while (@intFromPtr(ip) < @intFromPtr(iend)) {
        insertHC(ctx, ip);
        ip += 1;
    }
}

/// Set external dictionary for streaming compression
fn setExternalDict(ctx: *Context, newBlock: [*]const u8) void {
    // Insert remaining dictionary content (for hash chain strategies)
    if (@intFromPtr(ctx.end) >= @intFromPtr(ctx.prefixStart) + 4) {
        const params = getCLevelParams(@intCast(ctx.compressionLevel));
        if (params.strat != .lz4mid) {
            // Insert last 3 positions to ensure continuity
            insertRange(ctx, ctx.end - 3, ctx.end);
        }
    }

    // Only one memory segment for extDict, so any previous extDict is lost
    ctx.lowLimit = ctx.dictLimit;
    ctx.dictStart = ctx.prefixStart;
    ctx.dictLimit += @as(u32, @intCast(@intFromPtr(ctx.end) - @intFromPtr(ctx.prefixStart)));
    ctx.prefixStart = newBlock;
    ctx.end = newBlock;
    ctx.nextToUpdate = ctx.dictLimit; // match referencing will resume from there

    // cannot reference an extDict and a dictCtx at the same time
    ctx.dictCtx = null;
}

/// Initialize context for streaming (similar to LZ4HC_init_internal)
fn initInternal(ctx: *Context, start: [*]const u8) void {
    const bufferSize: usize = @intFromPtr(ctx.end) -% @intFromPtr(ctx.prefixStart);
    var newStartingOffset: usize = bufferSize +% ctx.dictLimit;

    // Check for overflow and reset if needed
    if (newStartingOffset > 1024 * 1024 * 1024) { // 1 GB
        ctx.clearTables();
        newStartingOffset = 0;
    }

    newStartingOffset += 64 * 1024; // 64 KB

    ctx.nextToUpdate = @intCast(newStartingOffset);
    ctx.prefixStart = start;
    ctx.end = start;
    ctx.dictStart = start;
    ctx.dictLimit = @intCast(newStartingOffset);
    ctx.lowLimit = @intCast(newStartingOffset);
}

// ===== Streaming API =====

/// LZ4 HC Streaming Compression Context
/// Allows compressing data in multiple chunks while maintaining compression history
pub const StreamHC = struct {
    ctx: Context,
    allocator: Allocator,
    initialized: bool,

    /// Create a new streaming compression context
    pub fn create(allocator: Allocator) Allocator.Error!*StreamHC {
        const stream = try allocator.create(StreamHC);
        stream.* = StreamHC{
            .ctx = Context.init(),
            .allocator = allocator,
            .initialized = false,
        };
        stream.ctx.compressionLevel = LZ4HC_CLEVEL_DEFAULT;
        return stream;
    }

    /// Destroy streaming context and free memory
    pub fn destroy(self: *StreamHC) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Reset stream state to start fresh compression
    pub fn reset(self: *StreamHC, compressionLevel: i32) void {
        // Clear hash and chain tables
        self.ctx.clearTables();

        // Set compression level
        var level = compressionLevel;
        if (level < 1) level = LZ4HC_CLEVEL_DEFAULT;
        if (level > LZ4HC_CLEVEL_MAX) level = LZ4HC_CLEVEL_MAX;
        self.ctx.compressionLevel = @intCast(level);

        // Reset all pointers and limits
        self.ctx.dictLimit = 0;
        self.ctx.lowLimit = 0;
        self.ctx.nextToUpdate = 0;
        self.ctx.dictCtx = null;
        self.initialized = false;
    }

    /// Compress the next block with shared compression history
    /// This maintains compression state across multiple blocks
    pub fn compressContinue(self: *StreamHC, src: []const u8, dst: []u8) Error!usize {
        // Input validation
        if (src.len > LZ4_MAX_INPUT_SIZE) return Error.InputTooLarge;
        if (src.len == 0) return 0;
        if (dst.len == 0) return Error.OutputTooSmall;

        // Auto-init if this is the first block
        if (!self.initialized) {
            initInternal(&self.ctx, src.ptr);
            self.initialized = true;
        }

        // Check for overflow (context has processed > 2GB)
        const currentOffset = (@intFromPtr(self.ctx.end) -% @intFromPtr(self.ctx.prefixStart)) +% self.ctx.dictLimit;
        if (currentOffset > 2 * 1024 * 1024 * 1024) { // 2 GB
            // Save last 64KB as dictionary and reset
            const dictSize = @min(@intFromPtr(self.ctx.end) - @intFromPtr(self.ctx.prefixStart), 64 * 1024);
            if (dictSize > 0) {
                // Load last 64KB as dictionary
                const dictStart = self.ctx.end - dictSize;
                _ = try self.loadDict(dictStart[0..dictSize]);
            }
        }

        // Check if blocks are contiguous in memory
        if (src.ptr != self.ctx.end) {
            // Blocks are not contiguous - set previous block as external dictionary
            setExternalDict(&self.ctx, src.ptr);
        }

        // Check for overlapping input/dictionary space
        const sourceEnd = src.ptr + src.len;
        const dictBegin = self.ctx.dictStart;
        const dictEnd = self.ctx.dictStart + (self.ctx.dictLimit - self.ctx.lowLimit);

        if (@intFromPtr(sourceEnd) > @intFromPtr(dictBegin) and @intFromPtr(src.ptr) < @intFromPtr(dictEnd)) {
            // Input overlaps with dictionary - adjust dictionary boundaries
            var adjustedSourceEnd = sourceEnd;
            if (@intFromPtr(sourceEnd) > @intFromPtr(dictEnd)) {
                adjustedSourceEnd = dictEnd;
            }

            const overlap: u32 = @intCast(@intFromPtr(adjustedSourceEnd) - @intFromPtr(self.ctx.dictStart));
            self.ctx.lowLimit += overlap;
            self.ctx.dictStart += overlap;

            // Invalidate dictionary if it's too small to be useful
            const minDictSize = 4; // LZ4HC_HASHSIZE equivalent
            if (self.ctx.dictLimit - self.ctx.lowLimit < minDictSize) {
                self.ctx.lowLimit = self.ctx.dictLimit;
                self.ctx.dictStart = self.ctx.prefixStart;
            }
        }

        // Perform compression using stored compression level
        const level = self.ctx.compressionLevel;
        return try compressHCExtState(&self.ctx, src, dst, @intCast(level));
    }

    /// Load external dictionary to improve compression
    /// Dictionary will be used to find matches in subsequent compress operations
    pub fn loadDict(self: *StreamHC, dict: []const u8) Error!usize {
        var dictionary = dict;

        // Limit dictionary size to 64KB
        if (dictionary.len > 64 * 1024) {
            dictionary = dictionary[dictionary.len - 64 * 1024 ..];
        }

        if (dictionary.len == 0) return 0;

        // Get compression level and parameters
        const cLevel = self.ctx.compressionLevel;
        const params = getCLevelParams(@intCast(cLevel));

        // Full reset and re-initialization
        self.reset(@intCast(cLevel));

        // Initialize context with dictionary
        initInternal(&self.ctx, dictionary.ptr);
        self.ctx.end = dictionary.ptr + dictionary.len;

        // Build hash structures for dictionary
        if (params.strat == .lz4mid) {
            // For LZ4MID, fill the dual hash tables
            // This is handled by compressMID internally when needed
        } else {
            // For hash chain strategies, insert the last 3 positions
            if (dictionary.len >= 4) {
                insertRange(&self.ctx, self.ctx.end - 3, self.ctx.end);
            }
        }

        return dictionary.len;
    }

    /// Save dictionary state to continue compression later
    /// This copies the last N bytes of compression history to safeBuffer
    /// Returns the number of bytes saved
    pub fn saveDict(self: *StreamHC, safeBuffer: []u8) usize {
        const prefixSize: usize = @intFromPtr(self.ctx.end) - @intFromPtr(self.ctx.prefixStart);

        // Determine how much dictionary to save
        var dictSize: usize = @min(safeBuffer.len, 64 * 1024);
        if (dictSize < 4) dictSize = 0;
        if (dictSize > prefixSize) dictSize = prefixSize;

        // Copy dictionary data
        if (dictSize > 0) {
            const srcStart = self.ctx.end - dictSize;
            @memcpy(safeBuffer[0..dictSize], srcStart[0..dictSize]);
        }

        // Update context pointers to reference saved dictionary
        const endIndex: u32 = @intCast((@intFromPtr(self.ctx.end) - @intFromPtr(self.ctx.prefixStart)) + self.ctx.dictLimit);

        if (dictSize > 0) {
            self.ctx.end = safeBuffer.ptr + dictSize;
            self.ctx.prefixStart = safeBuffer.ptr;
        } else {
            self.ctx.end = undefined;
            self.ctx.prefixStart = undefined;
        }

        self.ctx.dictLimit = endIndex - @as(u32, @intCast(dictSize));
        self.ctx.lowLimit = endIndex - @as(u32, @intCast(dictSize));
        self.ctx.dictStart = self.ctx.prefixStart;

        if (self.ctx.nextToUpdate < self.ctx.dictLimit) {
            self.ctx.nextToUpdate = self.ctx.dictLimit;
        }

        return dictSize;
    }
};
