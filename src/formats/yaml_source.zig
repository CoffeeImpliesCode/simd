const std = @import("std");
const simd = @import("../core/simd.zig");

pub fn failureOffset(input: []const u8) error{InputTooLarge}!?usize {
    return failureOffsetImpl(simd.default_vector_len, input);
}

pub fn failureOffsetImpl(
    comptime vlen: usize,
    input: []const u8,
) error{InputTooLarge}!?usize {
    comptime {
        if (vlen < 4) {
            @compileError("YAML validation vector width must be at least four bytes");
        }
    }
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var index: usize = 0;
    if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) index = 3;

    const printable_mask = simd.exactMask(
        simd.Mask(vlen),
        std.math.maxInt(simd.Mask(vlen)),
    );
    while (index < input.len) {
        while (input.len - index >= vlen) {
            const bytes: simd.Vec(u8, vlen) = input[index..][0..vlen].*;
            const printable = simd.exactMask(
                simd.Mask(vlen),
                simd.matchRange(vlen, bytes, 0x20, 0x7e),
            );
            if (printable != printable_mask) break;
            index += vlen;
        }
        if (index >= input.len) break;

        const scalar_end = index + @min(vlen, input.len - index);
        while (index < scalar_end) {
            const width = yamlCharacterWidth(input, index) orelse return index;
            index += width;
        }
    }
    return null;
}

pub fn failureOffsetScalarFrom(
    input: []const u8,
    start: usize,
) error{InputTooLarge}!?usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var index = start;
    if (start == 0 and std.mem.startsWith(u8, input, "\xef\xbb\xbf")) index = 3;
    while (index < input.len) {
        const width = yamlCharacterWidth(input, index) orelse return index;
        index += width;
    }
    return null;
}

fn yamlCharacterWidth(input: []const u8, index: usize) ?usize {
    const first = input[index];
    if (first == 0xef and index != 0 and index + 2 < input.len and
        input[index + 1] == 0xbb and input[index + 2] == 0xbf)
    {
        return null;
    }
    if (first < 0x20 and first != '\n' and first != '\r' and first != '\t') return null;
    if (first == 0x7f) return null;
    if (first < 0x80) return 1;

    if (first == 0xc2) {
        if (index + 1 >= input.len or !isContinuation(input[index + 1])) return null;
        const second = input[index + 1];
        if (second == 0x85 or second >= 0xa0) return 2;
        return null;
    }
    if (first >= 0xc3 and first <= 0xdf) {
        if (index + 1 >= input.len or !isContinuation(input[index + 1])) return null;
        return 2;
    }
    if (first == 0xe0) {
        if (index + 2 >= input.len or input[index + 1] < 0xa0 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first >= 0xe1 and first <= 0xec or first == 0xee) {
        if (index + 2 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xed) {
        if (index + 2 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x9f or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xef) {
        if (index + 2 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2])) return null;
        if (input[index + 1] == 0xbf and input[index + 2] >= 0xbe) return null;
        return 3;
    }
    if (first == 0xf0) {
        if (index + 3 >= input.len or input[index + 1] < 0x90 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first >= 0xf1 and first <= 0xf3) {
        if (index + 3 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first == 0xf4) {
        if (index + 3 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x8f or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    return null;
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}
