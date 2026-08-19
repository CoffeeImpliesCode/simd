const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");

const testing = std.testing;

pub fn indexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    var windows = simd.windows(u8, 64, input, 0);
    var base_offset: usize = 0;
    var prev_in_string = false;
    var prev_ends_in_backslash = false;
    var prev_backslash_run_odd = false;
    var prev_atom_candidate = false;

    while (base_offset < input.len) {
        const chunk = windows.next().?;
        const valid_count = @min(input.len - base_offset, 64);
        const valid_mask = validByteMask(valid_count);

        const backslashes = simd.matchByte(64, chunk, '\\') & valid_mask;
        const backslash_result = simd.computeBackslashRuns64(
            backslashes,
            prev_ends_in_backslash,
        );
        var odd_backslash_ends = backslash_result.odd_length_ends & valid_mask;
        if (prev_ends_in_backslash) {
            if ((backslashes & 1) == 0) {
                if (prev_backslash_run_odd) {
                    odd_backslash_ends |= 1;
                } else {
                    odd_backslash_ends &= ~@as(u64, 1);
                }
            } else if (prev_backslash_run_odd) {
                odd_backslash_ends ^= leadingRunEndMask(backslashes, valid_count);
            }
        }

        const quotes = simd.matchByte(64, chunk, '"') & valid_mask;
        const unescaped_quotes = quotes & ~odd_backslash_ends;
        const inside_without_closing = simd.prefixXor(u64, unescaped_quotes) ^
            if (prev_in_string) ~@as(u64, 0) else 0;
        const string_mask = inside_without_closing | unescaped_quotes;
        const outside_string = ~string_mask & valid_mask;

        const structural = simd.matchAny4(64, chunk, '{', '}', '[', ']') |
            simd.matchAny2(64, chunk, ':', ',');
        const atom_candidates = simd.matchRange(64, chunk, '0', '9') |
            simd.matchAny4(64, chunk, '-', 't', 'f', 'n');
        const atom_starts = atom_candidates &
            ~((atom_candidates << 1) | if (prev_atom_candidate) @as(u64, 1) else 0);
        const record_boundaries = simd.matchByte(64, chunk, '\n');
        const structural_indexes = (structural | atom_starts | record_boundaries) & outside_string;

        indexes.count += simd.extractBitIndexes(
            structural_indexes,
            base_offset,
            indexes.indexes[indexes.count..],
        );

        prev_in_string = (inside_without_closing & (@as(u64, 1) << 63)) != 0;
        prev_ends_in_backslash = valid_count == 64 and
            (backslashes & (@as(u64, 1) << 63)) != 0;
        prev_backslash_run_odd = trailingBackslashRunOdd(
            chunk,
            valid_count,
            prev_backslash_run_odd,
        );
        prev_atom_candidate = valid_count != 0 and
            (atom_candidates & (@as(u64, 1) << @as(u6, @intCast(valid_count - 1)))) != 0 and
            (outside_string & (@as(u64, 1) << @as(u6, @intCast(valid_count - 1)))) != 0;
        base_offset += 64;
    }

    return indexes;
}

fn validByteMask(valid_count: usize) u64 {
    if (valid_count == 64) return ~@as(u64, 0);
    if (valid_count == 0) return 0;
    return (@as(u64, 1) << @as(u6, @intCast(valid_count))) - 1;
}

fn leadingRunEndMask(backslashes: u64, valid_count: usize) u64 {
    const non_backslashes = ~backslashes | ~validByteMask(valid_count);
    if (non_backslashes == 0) return 0;
    const run_length = @ctz(non_backslashes);
    if (run_length >= valid_count) return 0;
    return @as(u64, 1) << @as(u6, @intCast(run_length));
}

fn trailingBackslashRunOdd(
    chunk: simd.Vec(64, u8),
    valid_count: usize,
    prev_run_odd: bool,
) bool {
    if (valid_count == 0) return false;
    const bytes: [64]u8 = chunk;
    var run_length: usize = 0;
    var index = valid_count;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == prev_run_odd;
    return run_length % 2 != 0;
}

fn scalarIndexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var prev_atom_candidate = false;
    for (input, 0..) |byte, index| {
        if (byte == '"' and backslash_run_length % 2 == 0) {
            in_string = !in_string;
        }

        if (!in_string) {
            if (isStructuralByte(byte) or byte == '\n') {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            } else if (isAtomByte(byte) and !prev_atom_candidate) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
        }

        prev_atom_candidate = !in_string and isAtomByte(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    return result;
}

fn isStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomByte(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectMatchesScalar(input: []const u8) !void {
    var expected = try scalarIndexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJsonl(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
}

test "indexJsonl indexes each unquoted record boundary" {
    const input = "{\"a\":1}\n{\"b\":2}\n";
    const expected = [_]u32{ 0, 4, 5, 6, 7, 8, 12, 13, 14, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonl ignores newlines inside strings" {
    try expectMatchesScalar("{\"text\":\"first\nsecond\"}\n{\"n\":null}\n");
}

test "indexJsonl matches scalar reference across SIMD chunks" {
    var input: [132]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[63] = '\\';
    input[64] = '"';
    input[92] = '"';
    input[93] = ']';
    input[94] = '\n';
    input[95] = '{';
    input[96] = '"';
    input[97] = 'n';
    input[98] = '"';
    input[99] = ':';
    input[100] = '0';
    input[101] = '}';
    input[102] = '\n';
    try expectMatchesScalar(&input);
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}
