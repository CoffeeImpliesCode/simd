//! Shared vocabulary for the semantic benchmark measurement.
//!
//! Three modules meet here: the CommonMark slice, the YAML extended slice, and
//! the protocol decoder in `semantic_benchmark_report.zig`. This file owns the
//! names they all agree on and the single checksum encoding they all use. It
//! imports nothing but `std`, so a data-only fixture table, a decoder, and a
//! parser consumer can share it without pulling in `simd_lib` or any
//! CPU-dependent module.
//!
//! Nothing here ranks, compares libraries, or claims streaming. A `Stage` names
//! what one measured iteration consumed after a fresh parse and before the
//! document is destroyed, and `Result.outcome` is an observation: exactly
//! `accepted`, or the name of the error the real call returned.
//!
//! The legacy `bench.zig` domain is untouched by this file. The two domains
//! coexist: seven formats x five workloads x six stages over there, the
//! declared fixture list here.

const std = @import("std");

/// The two separately identified parsers under measurement. Each is reported
/// under its own name; neither is folded into the other's rows.
pub const Format = enum {
    commonmark,
    yaml_extended,
};

/// One measured input family. The nine `cm_` workloads are CommonMark 0.31.2
/// documents: four accepted families, one raw HTML family, and four resource
/// families that must exercise a real configured limit. The fifteen `yaml_`
/// workloads are the `yaml-extended-e2b-1.2.2` profile: seven accepted
/// families, five rejection families, and three resource families.
///
/// The name is a stable public label. It appears in every report row and in
/// every archived manifest, so renaming one is a contract change and surfaces
/// as a decode failure rather than a silently smaller run.
pub const Workload = enum {
    cm_blocks,
    cm_inline,
    cm_links,
    cm_unicode,
    cm_raw_html,
    cm_input_limit,
    cm_node_limit,
    cm_delimiter_limit,
    cm_work_limit,
    yaml_literal_clip,
    yaml_literal_strip,
    yaml_literal_keep,
    yaml_folded,
    yaml_single_multiline,
    yaml_double_multiline,
    yaml_compact_mapping,
    yaml_unterminated_quote,
    yaml_malformed_block,
    yaml_alias,
    yaml_tag,
    yaml_multiple_documents,
    yaml_cooked_limit,
    yaml_scalar_line_limit,
    yaml_depth_limit,
};

/// What one measured iteration consumes, on top of a fresh parse of the
/// fixture source and including the destruction of that parse.
///
/// - `parse`: parse consumption only. It is deliberately small and is labeled
///   as such in the report; it is not a semantic claim.
/// - `traverse`: the complete semantics of the parsed document, hashed in
///   full. CommonMark hashes a complete preorder traversal; YAML hashes every
///   logical container, key, and value together with complete cooked scalar
///   bytes rather than raw marker spans.
/// - `render_html`: a fresh parse plus safe-mode HTML rendering. Only the
///   CommonMark fixtures declare it; the YAML profile has no renderer.
/// - `resource_error`: the configured limit fired. The fixture declares exactly
///   this one stage and its outcome is the observed error name.
/// - `reject`: the document is invalid or unsupported for this profile. The
///   fixture declares exactly this one stage and its outcome is the observed
///   error name.
pub const Stage = enum {
    parse,
    traverse,
    render_html,
    resource_error,
    reject,
};

/// One measured case. `checksum` is the semantic checksum of the named
/// consumption, and `outcome` is what actually happened: `accepted` or
/// `@errorName` of the error the real call returned. It is never an expected
/// value copied into a successful result.
pub const Result = struct {
    checksum: u64,
    outcome: []const u8,
};

/// One measured input: its source bytes, the complete list of stages it is
/// measured on, and its independently authored oracle.
///
/// `stages` is the complete declared stage list in declared order. The report
/// prints exactly these rows for this fixture, in exactly this order, and the
/// decoder refuses a row for any stage that is not declared here. There is no
/// Cartesian product: a stage a fixture does not declare has no row.
///
/// `outcome` is the fixture's oracle. An accepted fixture names
/// `accepted_outcome` and declares `parse`/`traverse`, plus `render_html` for
/// CommonMark. A rejected or resource fixture declares exactly one matching
/// stage and names the exact error it must observe.
pub const Fixture = struct {
    workload: Workload,
    source: []const u8,
    stages: []const Stage,
    outcome: []const u8,
};

/// The one outcome an accepted fixture reports. Every other outcome is an
/// `@errorName` observation.
pub const accepted_outcome: []const u8 = "accepted";

/// FNV-1a64 offset basis.
pub const fnv_offset_basis: u64 = 14695981039346656037;

/// FNV-1a64 prime.
pub const fnv_prime: u64 = 1099511628211;

/// FNV-1a64 over `bytes`: basis `fnv_offset_basis`, then one xor-multiply per
/// byte with `fnv_prime`, wrapping. This is the whole-source hash an input
/// declaration reports.
pub fn checksumBytes(bytes: []const u8) u64 {
    var checksum = fnv_offset_basis;
    for (bytes) |byte| mix(&checksum, byte);
    return checksum;
}

/// Mixes one `u64` into `checksum` as eight little-endian bytes, each with the
/// same FNV step, so a structured semantic traversal has one documented
/// encoding instead of an implicit one.
pub fn mix(checksum: *u64, value: u64) void {
    var remaining = value;
    inline for (0..8) |_| {
        const byte: u64 = @truncate(remaining);
        checksum.* ^= byte;
        checksum.* *%= fnv_prime;
        remaining >>= 8;
    }
}

/// Mixes a byte string into `checksum` behind its byte count.
///
/// Every string goes through this, never through `mix` directly, so the length
/// prefix cannot be forgotten at a call site: `("ab", "c")` and `("a", "bc")`
/// produce different checksums, and a string can never run into the bytes that
/// follow it.
pub fn mixBytes(checksum: *u64, bytes: []const u8) void {
    mix(checksum, @intCast(bytes.len));
    for (bytes) |byte| mix(checksum, byte);
}

const testing = std.testing;

test "checksumBytes is FNV-1a64 over the exact bytes" {
    try testing.expectEqual(fnv_offset_basis, checksumBytes(""));
    try testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), checksumBytes("a"));
}

test "mixBytes prefixes a string with its byte count" {
    var joined: u64 = fnv_offset_basis;
    mixBytes(&joined, "ab");
    mixBytes(&joined, "c");

    var split: u64 = fnv_offset_basis;
    mixBytes(&split, "a");
    mixBytes(&split, "bc");

    try testing.expect(joined != split);
}

test "mix folds a value in as eight little-endian bytes" {
    var mixed: u64 = fnv_offset_basis;
    mix(&mixed, 0x0102030405060708);

    var expected: u64 = fnv_offset_basis;
    const least_significant_byte_first = [_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 };
    for (least_significant_byte_first) |byte| {
        expected ^= @as(u64, byte);
        expected *%= fnv_prime;
    }

    try testing.expectEqual(expected, mixed);
}
