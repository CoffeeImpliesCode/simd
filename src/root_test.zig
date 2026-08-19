const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const vector_len = 64;

comptime {
    std.debug.assert(lib.default_vector_len == vector_len);
}

fn scalarPrefixXor64(bitmask: u64) u64 {
    var result: u64 = 0;
    var parity: u1 = 0;
    inline for (0..64) |i| {
        const bit = @as(u1, @truncate(bitmask >> i));
        parity ^= bit;
        result |= (@as(u64, parity) << i);
    }
    return result;
}

fn scalarFindDigits64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |byte, index| {
        if (byte >= '0' and byte <= '9') {
            mask |= @as(u64, 1) << @as(u6, @intCast(index));
        }
    }
    return mask;
}

fn scalarFindWhitespace64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
            mask |= @as(u64, 1) << @as(u6, @intCast(index));
        }
    }
    return mask;
}

fn scalarFindStructural64(bytes: [64]u8) u64 {
    var mask: u64 = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '{' or byte == '}' or byte == '[' or byte == ']' or
            byte == ':' or byte == ',')
        {
            mask |= @as(u64, 1) << @as(u6, @intCast(index));
        }
    }
    return mask;
}

test "refAllDecls" {
    testing.refAllDecls(lib);
}

test "prefixXor matches scalar reference across bit patterns" {
    const test_patterns = [_]u64{
        0x0000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA,
        0x0000000000000001,
        0x8000000000000000,
        0x123456789ABCDEF0,
        0x0F0F0F0F0F0F0F0F,
    };

    for (test_patterns) |pattern| {
        const simd_result = lib.prefixXor(u64, pattern);
        const scalar_result = scalarPrefixXor64(pattern);
        try testing.expectEqual(scalar_result, simd_result);
    }
}

test "prefixXor handles every single-bit input" {
    inline for (0..64) |bit_index| {
        const shift: u6 = @intCast(bit_index);
        const bit = @as(u64, 1) << shift;
        const expected = ~@as(u64, 0) << shift;
        try testing.expectEqual(expected, lib.prefixXor(u64, bit));
    }
}

test "SIMD byte matching against scalar oracles" {
    var bytes: [64]u8 = undefined;
    for (0..64) |index| {
        bytes[index] = 'a';
    }
    bytes[5] = '"';
    bytes[12] = '"';
    bytes[20] = '{';
    bytes[21] = '}';
    bytes[30] = ' ';
    bytes[31] = '\n';
    bytes[40] = '7';
    bytes[41] = '9';

    const vector: lib.Vec(vector_len, u8) = bytes;

    const quotes_simd = lib.findQuotes(vector_len, vector);
    try testing.expectEqual((@as(u64, 1) << 5) | (@as(u64, 1) << 12), quotes_simd);

    const whitespace_simd = lib.findWhitespace(vector_len, vector);
    const whitespace_scalar = scalarFindWhitespace64(bytes);
    try testing.expectEqual(whitespace_scalar, whitespace_simd);

    const digits_simd = lib.findDigits(vector_len, vector);
    const digits_scalar = scalarFindDigits64(bytes);
    try testing.expectEqual(digits_scalar, digits_simd);

    const structural_simd = lib.findStructural(vector_len, vector);
    const structural_scalar = scalarFindStructural64(bytes);
    try testing.expectEqual(structural_scalar, structural_simd);
}

test "ChunkIterator with and without padding" {
    const data = "0123456789ABCDEF_extra";
    var unpadded = lib.windows(u8, 16, data, null);
    const first_chunk = unpadded.next();
    try testing.expect(first_chunk != null);
    try testing.expectEqualStrings("0123456789ABCDEF", &@as([16]u8, first_chunk.?));
    try testing.expect(unpadded.next() == null);

    var padded = lib.windows(u8, 16, data, 'x');
    _ = padded.next();
    const tail_chunk = padded.next();
    try testing.expect(tail_chunk != null);
    try testing.expectEqualStrings("_extraxxxxxxxxxx", &@as([16]u8, tail_chunk.?));
    try testing.expect(padded.next() == null);
}

test "ChunkIterator handles empty and exact-length data" {
    var empty = lib.windows(u8, 16, "", 'x');
    try testing.expect(empty.next() == null);

    const exact_data = "0123456789ABCDEF";
    var exact = lib.windows(u8, 16, exact_data, 'x');
    const exact_chunk = exact.next();
    try testing.expect(exact_chunk != null);
    try testing.expectEqualStrings(exact_data, &@as([16]u8, exact_chunk.?));
    try testing.expect(exact.next() == null);
}

test "classifyStrings64 string state transitions" {
    const quote_mask: u64 = (@as(u64, 1) << 4) | (@as(u64, 1) << 10);
    const completed = lib.classifyStrings64(quote_mask, false);
    try testing.expect(!completed.ends_in_string);
    const expected_span: u64 = ((@as(u64, 1) << 11) - 1) ^ ((@as(u64, 1) << 4) - 1);
    try testing.expectEqual(expected_span, completed.mask);

    const opening_quote: u64 = @as(u64, 1) << 60;
    const open = lib.classifyStrings64(opening_quote, false);
    try testing.expect(open.ends_in_string);

    const closing_quote: u64 = @as(u64, 1) << 5;
    const continued = lib.classifyStrings64(closing_quote, true);
    try testing.expect(!continued.ends_in_string);
    const expected_closed: u64 = (@as(u64, 1) << 6) - 1;
    try testing.expectEqual(expected_closed, continued.mask);
}
