const std = @import("std");
const testing = std.testing;

pub const simd = @import("core/simd.zig");
pub const stage1 = @import("core/stage1.zig");
pub const debug = @import("core/debug.zig");

pub const default_vector_len = simd.default_vector_len;
pub const Vec = simd.Vec;
pub const Mask = simd.Mask;
pub const ChunkIterator = simd.ChunkIterator;
pub const windows = simd.windows;
pub const prefixXor = simd.prefixXor;
pub const matchByte = simd.matchByte;
pub const matchAny2 = simd.matchAny2;
pub const matchAny4 = simd.matchAny4;
pub const matchRange = simd.matchRange;
pub const extractBitIndexes = simd.extractBitIndexes;
pub const computeBackslashRuns64 = simd.computeBackslashRuns64;

pub const StructuralIndex = stage1.StructuralIndex;

pub const formats = struct {
    pub const json = @import("formats/json.zig");
    pub const jsonl = @import("formats/jsonl.zig");
    pub const jsonc = @import("formats/jsonc.zig");
    pub const json5 = @import("formats/json5.zig");
    pub const markdown = @import("formats/markdown.zig");
    pub const xml = @import("formats/xml.zig");
};

test "refAllDecls" {
    testing.refAllDecls(@This());
    testing.refAllDecls(formats);
}
