//! Native Zig byte primitives, structural indexes and parsing over caller-owned input.
//!
//! Zig 0.17.0 is the development compiler. Import this root through the registered
//! `simd` module: add `dependency.module("simd")` to the consumer's import table.
//! `simd`, `stage1`, `stage2`, `json_value`, `ondemand`, `stream` and `debug` expose
//! the core contracts; `formats` selects each format without changing its dialect.
//! The short root aliases name the same declarations, not independent implementations.
//!
//! For eager JSON, build a tape with `formats.json.buildJsonTape`, immediately defer
//! `document.deinit(allocator)`, then call `document.root(input)` with the exact original
//! immutable source. Tapes own allocations; source bytes remain the caller's.
//! Resident readers require live, address-stable owners and one traversal focus.
//! Streaming produces indexes, not source-safe streaming Stage 2 documents.
//! Semantic CommonMark and extended YAML are separate opt-in contracts and do not stream.
//! This library opens no files and provides no C ABI; see README.md for package routes.

const std = @import("std");
const testing = std.testing;

pub const simd = @import("core/simd.zig");
pub const stage1 = @import("core/stage1.zig");
pub const stage2 = @import("core/stage2.zig");
pub const json_value = @import("core/json_value.zig");
pub const ondemand = @import("core/ondemand.zig");
pub const stream = @import("core/stream.zig");
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
pub const computeBackslashRuns = simd.computeBackslashRuns;

const json_format = @import("formats/json.zig");
const jsonl_format = @import("formats/jsonl.zig");
const jsonc_format = @import("formats/jsonc.zig");
const json5_format = @import("formats/json5.zig");
const markdown_format = @import("formats/markdown.zig");
const commonmark_format = @import("formats/commonmark.zig");
const xml_format = @import("formats/xml.zig");
const yaml_format = @import("formats/yaml.zig");
const yaml_extended_format = @import("formats/yaml_extended.zig");

pub const StructuralIndex = stage1.StructuralIndex;

/// Format-specific indexing, tape and resident APIs, plus separate semantic profiles.
pub const formats = struct {
    pub const json = json_format;
    pub const jsonl = jsonl_format;
    pub const jsonc = jsonc_format;
    pub const json5 = json5_format;
    pub const markdown = markdown_format;
    pub const commonmark = commonmark_format;
    pub const xml = xml_format;
    pub const yaml = yaml_format;
    pub const yaml_extended = yaml_extended_format;
};

test "refAllDecls" {
    testing.refAllDecls(@This());
    testing.refAllDecls(formats);
}
