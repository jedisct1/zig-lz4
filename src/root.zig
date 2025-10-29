//! LZ4 compression library for Zig
//! This is the main library entry point
pub const lz4 = @import("lz4.zig");
pub const lz4f = @import("lz4f.zig");
pub const lz4hc = @import("lz4hc.zig");

// Re-export error types
pub const Error = lz4.Error;

// Core compression functions
pub const compressDefault = lz4.compressDefault;
pub const compressFast = lz4.compressFast;
pub const compressBound = lz4.compressBound;
pub const compressDestSize = lz4.compressDestSize;

// Core decompression functions
pub const decompressSafe = lz4.decompressSafe;
pub const decompressSafePartial = lz4.decompressSafePartial;
pub const decompressSafeUsingDict = lz4.decompressSafeUsingDict;
pub const decompressSafePartialUsingDict = lz4.decompressSafePartialUsingDict;

// Advanced functions
pub const sizeofState = lz4.sizeofState;
pub const compressFastExtState = lz4.compressFastExtState;
pub const decoderRingBufferSize = lz4.decoderRingBufferSize;

// Streaming compression
pub const Stream = lz4.Stream;
pub const createStream = lz4.createStream;
pub const freeStream = lz4.freeStream;

// Streaming decompression
pub const StreamDecode = lz4.StreamDecode;
pub const createStreamDecode = lz4.createStreamDecode;
pub const freeStreamDecode = lz4.freeStreamDecode;

// Version information
pub const versionNumber = lz4.versionNumber;
pub const versionString = lz4.versionString;
pub const VERSION_MAJOR = lz4.VERSION_MAJOR;
pub const VERSION_MINOR = lz4.VERSION_MINOR;
pub const VERSION_RELEASE = lz4.VERSION_RELEASE;
pub const VERSION_NUMBER = lz4.VERSION_NUMBER;
pub const VERSION_STRING = lz4.VERSION_STRING;

// Constants
pub const MINMATCH = lz4.MINMATCH;
pub const LZ4_MAX_INPUT_SIZE = lz4.LZ4_MAX_INPUT_SIZE;
pub const LZ4_DISTANCE_MAX = lz4.LZ4_DISTANCE_MAX;

// HC compression functions
pub const compressHC = lz4hc.compressHC;
pub const compressHCExtState = lz4hc.compressHCExtState;
pub const sizeofStateHC = lz4hc.sizeofStateHC;
pub const LZ4HC_CLEVEL_MIN = lz4hc.LZ4HC_CLEVEL_MIN;
pub const LZ4HC_CLEVEL_DEFAULT = lz4hc.LZ4HC_CLEVEL_DEFAULT;
pub const LZ4HC_CLEVEL_MAX = lz4hc.LZ4HC_CLEVEL_MAX;
