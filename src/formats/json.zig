const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");

const testing = std.testing;

pub fn indexJson(
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
        const structural_indexes = (structural | atom_starts) & outside_string;

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

fn scalarIndexJson(
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
            if (isStructuralByte(byte)) {
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
    var expected = try scalarIndexJson(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var actual = try indexJson(testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
}

test "indexJson matches scalar structural indexes" {
    // The scalar implementation defines the byte-exact Stage 1 contract.
    const cases = [_][]const u8{
        "",
        "{}",
        "{\"id\":-12,\"ok\":true,\"none\":null,\"bad\":false}",
        "{\"text\":\"{ [ ] } : , - 012 tfn\",\"value\":0}",
        "[\"escaped quote: \\\" and slash: \\\\\",0]",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJson emits one start per atom" {
    const input = "true false 123 -45";
    const expected = [_]u32{ 0, 5, 11, 15 };

    var index = try indexJson(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJson handles short backslash runs crossing a chunk" {
    var input: [72]u8 = @splat(' ');
    for (0..8) |run_length| {
        input = @splat(' ');
        input[0] = '[';
        input[1] = '"';
        const run_start = 64 - run_length;
        for (run_start..64) |index| {
            input[index] = '\\';
        }
        input[64] = '"';
        if (run_length % 2 == 0) {
            input[65] = '1';
            input[66] = ']';
        } else {
            input[65] = '"';
            input[66] = '1';
            input[67] = ']';
        }
        try expectMatchesScalar(&input);
    }
}

test "indexJson preserves quote and backslash state across chunks" {
    // Both odd and even trailing runs exercise the state carried through byte 64.
    var odd_run_input: [130]u8 = @splat('x');
    odd_run_input[0] = '[';
    odd_run_input[1] = '"';
    odd_run_input[63] = '\\';
    odd_run_input[64] = '"';
    odd_run_input[100] = '"';
    odd_run_input[129] = ']';
    try expectMatchesScalar(&odd_run_input);

    var even_run_input: [67]u8 = @splat('x');
    even_run_input[0] = '[';
    even_run_input[1] = '"';
    even_run_input[62] = '\\';
    even_run_input[63] = '\\';
    even_run_input[64] = '"';
    even_run_input[65] = '1';
    even_run_input[66] = ']';
    try expectMatchesScalar(&even_run_input);
}

test "indexJson ignores padded bytes at final chunk boundaries" {
    // These lengths cover both sides of a full 64-byte SIMD window.
    var input_63: [63]u8 = @splat(' ');
    input_63[62] = 'n';
    try expectMatchesScalar(&input_63);

    var input_64: [64]u8 = @splat(' ');
    input_64[63] = 'n';
    try expectMatchesScalar(&input_64);

    var input_65: [65]u8 = @splat(' ');
    input_65[64] = 'n';
    try expectMatchesScalar(&input_65);
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}
