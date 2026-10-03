//! Strict JSON string and number decoding into caller-provided storage.
//!
//! `decodeString` turns escaped string content into bytes and `parseNumber`
//! classifies and converts a complete number token. Neither allocates: one
//! writes into a slice the caller supplies, the other returns a value and a
//! borrowed view of the caller's own bytes, so there is nothing to release
//! afterwards. Callers reach this as `json_value` from the package root.
//!
//! The module validates and converts values that are already delimited. It does
//! not find them in a document: locating tokens, structural indexing and tape
//! building live in `stream`, `stage1` and `stage2`.

const std = @import("std");
const simd = @import("simd.zig");

/// Every way `decodeString` can fail.
///
/// All four are decided before the first output byte is written, so no tag
/// leaves a partially decoded buffer behind.
pub const StringDecodeError = error{
    /// A `"` or a byte below `0x20` inside the content, an escape outside the
    /// strict JSON set, or a `\uXXXX` that is not a complete code unit or a
    /// complete surrogate pair.
    InvalidEscape,
    /// The content is not valid UTF-8.
    InvalidUtf8,
    /// The decoded form does not fit in the output slice.
    CapacityExceeded,
    /// `raw` and `output` share bytes, so decoding would overwrite input it
    /// has not read yet.
    OverlappingBuffers,
};

/// The three forms a validated strict JSON number can take.
///
/// Which one `parseNumber` produces follows from the token's shape rather than
/// its magnitude.
pub const NumberValue = union(enum) {
    /// An integral token starting with `-`.
    signed: i64,
    /// An integral token starting with a digit.
    unsigned: u64,
    /// A token carrying a fraction or an exponent, or the spelling `-0`.
    float: f64,
};

/// A validated number together with the exact token it came from.
///
/// `raw` is the caller's own slice, returned by identity rather than copied, so
/// the value borrows whatever memory `raw` pointed at. A copy of the struct is
/// independent of the original and shares that memory.
pub const NumberView = struct {
    /// The token exactly as written, borrowed from the caller's input.
    raw: []const u8,
    /// Its converted value; the variant follows the token's shape.
    value: NumberValue,
};

/// The single failure `parseNumber` reports.
///
/// A grammar violation and a value that does not convert both arrive as
/// `error.InvalidNumber`, so a caller that only needs to know whether the
/// token is usable as written does not have to separate them.
pub const NumberParseError = error{
    InvalidNumber,
};

/// Decodes strict JSON string content into caller-provided storage, without
/// allocating.
///
/// `raw` is the content between the delimiters and stays escaped as written; a
/// `"` or any byte below `0x20` inside it is `error.InvalidEscape`, as is an
/// escape outside the strict set. `\uXXXX` produces one to four UTF-8 bytes,
/// and a surrogate pair must be complete in both halves.
///
/// The checks run in a fixed order, all before any output is written: overlap
/// first, then UTF-8, then the grammar and the required length. So
/// `error.OverlappingBuffers` is reported even when the content is also
/// malformed, and `error.InvalidUtf8` before any escape is examined. On every
/// error `output` keeps the bytes it had.
///
/// `output` must be at least as long as the decoded form, which may be shorter
/// than `raw` because escapes collapse, and no terminator is appended.
/// `error.CapacityExceeded` reports the shortfall; the value needed is exactly
/// the length the successful call returns.
///
/// The result is `output[0..decoded_len]`, so it borrows `output` and is
/// invalidated when the caller writes to or releases it.
pub fn decodeString(raw: []const u8, output: []u8) StringDecodeError![]u8 {
    if (rangesOverlap(raw, output)) return error.OverlappingBuffers;

    switch (simd.validateUtf8(raw)) {
        .valid => {},
        .invalid => return error.InvalidUtf8,
    }

    const decoded_len = try preflightString(raw, output.len);
    try decodeStringUnchecked(raw, output[0..decoded_len]);
    return output[0..decoded_len];
}

/// Validates and converts one complete strict JSON number, without allocating.
///
/// `raw` is the whole token. The grammar is exactly
/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`: no leading `+`, no
/// leading zeros, no leading-dot fraction, and nothing after the number.
/// Anything else is `error.InvalidNumber`, as is a token the conversion cannot
/// represent.
///
/// The shape of the token selects the variant, not its magnitude. A fraction or
/// an exponent converts to `f64`, and so does the spelling `-0`; a value that
/// comes out non-finite is rejected rather than returned. A token that starts
/// with `-` converts to `i64` and one that starts with a digit to `u64`, and a
/// value outside either range is rejected instead of truncated. So
/// `18446744073709551616` is `error.InvalidNumber` rather than a wrapped `0`.
///
/// `NumberView.raw` is `raw` itself, so nothing is copied: the returned value
/// borrows the caller's slice and is invalidated when the caller writes to or
/// releases it.
pub fn parseNumber(raw: []const u8) NumberParseError!NumberView {
    const has_fraction_or_exponent = try validateNumberGrammar(raw);

    if (has_fraction_or_exponent or std.mem.eql(u8, raw, "-0")) {
        const value = std.fmt.parseFloat(f64, raw) catch return error.InvalidNumber;
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        return .{ .raw = raw, .value = .{ .float = value } };
    }

    if (raw[0] == '-') {
        const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidNumber;
        return .{ .raw = raw, .value = .{ .signed = value } };
    }

    const value = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidNumber;
    return .{ .raw = raw, .value = .{ .unsigned = value } };
}

fn rangesOverlap(source: []const u8, destination: []u8) bool {
    if (source.len == 0 or destination.len == 0) return false;

    const source_start = @intFromPtr(source.ptr);
    const destination_start = @intFromPtr(destination.ptr);
    const source_end = rangeEnd(source_start, source.len);
    const destination_end = rangeEnd(destination_start, destination.len);

    return source_start < destination_end and destination_start < source_end;
}

fn rangeEnd(start: usize, length: usize) usize {
    return if (length > std.math.maxInt(usize) - start)
        std.math.maxInt(usize)
    else
        start + length;
}

fn preflightString(raw: []const u8, output_capacity: usize) StringDecodeError!usize {
    var decoded_len: usize = 0;
    var raw_index: usize = 0;
    while (raw_index < raw.len) {
        const byte = raw[raw_index];
        if (byte != '\\') {
            if (byte < 0x20 or byte == '"') return error.InvalidEscape;
            try addDecodedLength(&decoded_len, 1, output_capacity);
            raw_index += 1;
            continue;
        }

        if (raw.len - raw_index < 2) return error.InvalidEscape;
        switch (raw[raw_index + 1]) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                try addDecodedLength(&decoded_len, 1, output_capacity);
                raw_index += 2;
            },
            'u' => {
                const first = try parseCodeUnit(raw, raw_index);
                if (isHighSurrogate(first)) {
                    if (raw.len - raw_index < 12) return error.InvalidEscape;
                    if (raw[raw_index + 6] != '\\' or raw[raw_index + 7] != 'u') {
                        return error.InvalidEscape;
                    }
                    const second = try parseCodeUnitAt(raw, raw_index + 6);
                    if (!isLowSurrogate(second)) return error.InvalidEscape;
                    try addDecodedLength(
                        &decoded_len,
                        encodedLength(combineSurrogates(first, second)),
                        output_capacity,
                    );
                    raw_index += 12;
                } else {
                    if (isLowSurrogate(first)) return error.InvalidEscape;
                    try addDecodedLength(&decoded_len, encodedLength(first), output_capacity);
                    raw_index += 6;
                }
            },
            else => return error.InvalidEscape,
        }
    }
    return decoded_len;
}

fn addDecodedLength(
    decoded_len: *usize,
    addition: usize,
    output_capacity: usize,
) StringDecodeError!void {
    if (decoded_len.* > output_capacity) return error.CapacityExceeded;
    if (addition > output_capacity - decoded_len.*) return error.CapacityExceeded;
    decoded_len.* += addition;
}

fn decodeStringUnchecked(raw: []const u8, output: []u8) StringDecodeError!void {
    var raw_index: usize = 0;
    var output_index: usize = 0;
    while (raw_index < raw.len) {
        const byte = raw[raw_index];
        if (byte != '\\') {
            output[output_index] = byte;
            output_index += 1;
            raw_index += 1;
            continue;
        }

        switch (raw[raw_index + 1]) {
            '"', '\\', '/' => {
                output[output_index] = raw[raw_index + 1];
                output_index += 1;
                raw_index += 2;
            },
            'b' => {
                output[output_index] = 0x08;
                output_index += 1;
                raw_index += 2;
            },
            'f' => {
                output[output_index] = 0x0c;
                output_index += 1;
                raw_index += 2;
            },
            'n' => {
                output[output_index] = '\n';
                output_index += 1;
                raw_index += 2;
            },
            'r' => {
                output[output_index] = '\r';
                output_index += 1;
                raw_index += 2;
            },
            't' => {
                output[output_index] = '\t';
                output_index += 1;
                raw_index += 2;
            },
            'u' => {
                const first = try parseCodeUnit(raw, raw_index);
                const codepoint: u32 = if (isHighSurrogate(first)) blk: {
                    const second = try parseCodeUnitAt(raw, raw_index + 6);
                    break :blk combineSurrogates(first, second);
                } else first;
                const written = encodeCodepoint(codepoint, output[output_index..]);
                output_index += written;
                raw_index += if (isHighSurrogate(first)) 12 else 6;
            },
            else => unreachable,
        }
    }
}

fn parseCodeUnit(raw: []const u8, slash_index: usize) StringDecodeError!u16 {
    return parseCodeUnitAt(raw, slash_index);
}

fn parseCodeUnitAt(raw: []const u8, slash_index: usize) StringDecodeError!u16 {
    if (slash_index > raw.len or raw.len - slash_index < 6) return error.InvalidEscape;
    if (raw[slash_index] != '\\' or raw[slash_index + 1] != 'u') return error.InvalidEscape;

    var value: u16 = 0;
    var digit_index: usize = slash_index + 2;
    var digit_count: usize = 0;
    while (digit_count < 4) : (digit_count += 1) {
        const digit = std.fmt.charToDigit(raw[digit_index], 16) catch return error.InvalidEscape;
        value = (value << 4) | @as(u16, digit);
        digit_index += 1;
    }
    return value;
}

fn isHighSurrogate(code_unit: u16) bool {
    return code_unit >= 0xd800 and code_unit <= 0xdbff;
}

fn isLowSurrogate(code_unit: u16) bool {
    return code_unit >= 0xdc00 and code_unit <= 0xdfff;
}

fn combineSurrogates(high: u16, low: u16) u32 {
    return 0x1_0000 +
        ((@as(u32, high) - 0xd800) << 10) +
        (@as(u32, low) - 0xdc00);
}

fn encodedLength(codepoint: u32) usize {
    if (codepoint <= 0x7f) return 1;
    if (codepoint <= 0x7ff) return 2;
    if (codepoint <= 0xffff) return 3;
    return 4;
}

fn encodeCodepoint(codepoint: u32, output: []u8) usize {
    if (codepoint <= 0x7f) {
        output[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint <= 0x7ff) {
        output[0] = @intCast(0xc0 | (codepoint >> 6));
        output[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    }
    if (codepoint <= 0xffff) {
        output[0] = @intCast(0xe0 | (codepoint >> 12));
        output[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        output[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    }

    output[0] = @intCast(0xf0 | (codepoint >> 18));
    output[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
    output[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
    output[3] = @intCast(0x80 | (codepoint & 0x3f));
    return 4;
}

fn validateNumberGrammar(raw: []const u8) NumberParseError!bool {
    if (raw.len == 0) return error.InvalidNumber;

    var index: usize = 0;
    if (raw[index] == '-') {
        index += 1;
        if (index == raw.len) return error.InvalidNumber;
    }

    if (raw[index] == '0') {
        index += 1;
        if (index < raw.len and isDigit(raw[index])) return error.InvalidNumber;
    } else if (raw[index] >= '1' and raw[index] <= '9') {
        index += 1;
        while (index < raw.len and isDigit(raw[index])) : (index += 1) {}
    } else {
        return error.InvalidNumber;
    }

    var has_fraction_or_exponent = false;
    if (index < raw.len and raw[index] == '.') {
        has_fraction_or_exponent = true;
        index += 1;
        if (index == raw.len or !isDigit(raw[index])) return error.InvalidNumber;
        while (index < raw.len and isDigit(raw[index])) : (index += 1) {}
    }

    if (index < raw.len and (raw[index] == 'e' or raw[index] == 'E')) {
        has_fraction_or_exponent = true;
        index += 1;
        if (index < raw.len and (raw[index] == '+' or raw[index] == '-')) index += 1;
        if (index == raw.len or !isDigit(raw[index])) return error.InvalidNumber;
        while (index < raw.len and isDigit(raw[index])) : (index += 1) {}
    }

    if (index != raw.len) return error.InvalidNumber;
    return has_fraction_or_exponent;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}
