const std = @import("std");
const json_value = @import("simd_lib").json_value;
const testing = std.testing;

fn expectFilled(bytes: []const u8, expected: u8) !void {
    for (bytes) |byte| {
        try testing.expectEqual(expected, byte);
    }
}

fn expectDecode(expected: []const u8, raw: []const u8) !void {
    var output: [128]u8 = @splat(0xa5);
    const decoded = try json_value.decodeString(raw, &output);

    try testing.expectEqualSlices(u8, expected, decoded);
    try testing.expect(decoded.ptr == output[0..].ptr);
}

fn expectSigned(raw: []const u8, expected: i64) !void {
    const view = try json_value.parseNumber(raw);
    try testing.expect(view.raw.ptr == raw.ptr);
    try testing.expectEqual(raw.len, view.raw.len);

    switch (view.value) {
        .signed => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedNumberKind,
    }
}

fn expectUnsigned(raw: []const u8, expected: u64) !void {
    const view = try json_value.parseNumber(raw);
    try testing.expect(view.raw.ptr == raw.ptr);
    try testing.expectEqual(raw.len, view.raw.len);

    switch (view.value) {
        .unsigned => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedNumberKind,
    }
}

fn expectFloatBits(raw: []const u8, expected: u64) !void {
    const view = try json_value.parseNumber(raw);
    try testing.expect(view.raw.ptr == raw.ptr);
    try testing.expectEqual(raw.len, view.raw.len);

    switch (view.value) {
        .float => |actual| try testing.expectEqual(expected, @as(u64, @bitCast(actual))),
        else => return error.UnexpectedNumberKind,
    }
}

test "decodeString returns caller-owned bytes for empty and unescaped strings" {
    var empty_output: [0]u8 = .{};
    const empty = try json_value.decodeString("", &empty_output);
    try testing.expectEqual(@as(usize, 0), empty.len);

    try expectDecode("plain JSON", "plain JSON");
    try expectDecode("é € 😀", "é € 😀");
}

test "decodeString decodes every simple escape and escaped NUL" {
    const raw =
        "\\\"" ++
        "\\\\" ++
        "\\/" ++
        "\\b" ++
        "\\f" ++
        "\\n" ++
        "\\r" ++
        "\\t";
    const expected = [_]u8{ '"', '\\', '/', 0x08, 0x0c, '\n', '\r', '\t' };

    try expectDecode(&expected, raw);
    try expectDecode(&.{0}, "\\u0000");
}

test "decodeString decodes BMP escapes and paired surrogates" {
    const bmp = [_]u8{ 'A', 0xc3, 0xa9, 0xe2, 0x82, 0xac };
    const supplementary = [_]u8{ 0xf0, 0x9f, 0x98, 0x80 };

    try expectDecode(&bmp, "\\u0041\\u00e9\\u20AC");
    try expectDecode(&supplementary, "\\uD83D\\uDE00");
}

test "decodeString accepts exact output and leaves short output unchanged" {
    var exact: [4]u8 = undefined;
    const decoded = try json_value.decodeString("\\uD83D\\uDE00", &exact);
    try testing.expectEqualSlices(u8, &.{ 0xf0, 0x9f, 0x98, 0x80 }, decoded);
    try testing.expect(decoded.ptr == exact[0..].ptr);

    var short: [3]u8 = @splat(0xa5);
    try testing.expectError(
        error.CapacityExceeded,
        json_value.decodeString("\\uD83D\\uDE00", &short),
    );
    try testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, &short);
}

test "decodeString rejects every source and output overlap before writing" {
    var storage: [20]u8 = @splat(0xcc);
    @memcpy(storage[8..14], "\\u0041");
    const raw = storage[8..14];

    const before_prefix_overlap = storage;
    try testing.expectError(
        error.OverlappingBuffers,
        json_value.decodeString(raw, storage[4..12]),
    );
    try testing.expectEqualSlices(u8, &before_prefix_overlap, &storage);

    const before_suffix_overlap = storage;
    try testing.expectError(
        error.OverlappingBuffers,
        json_value.decodeString(raw, storage[10..16]),
    );
    try testing.expectEqualSlices(u8, &before_suffix_overlap, &storage);

    const before_exact_overlap = storage;
    try testing.expectError(
        error.OverlappingBuffers,
        json_value.decodeString(raw, storage[8..14]),
    );
    try testing.expectEqualSlices(u8, &before_exact_overlap, &storage);

    const adjacent = try json_value.decodeString(raw, storage[14..15]);
    try testing.expectEqualStrings("A", adjacent);
}

test "decodeString rejects invalid raw content and escapes without writing" {
    const cases = [_][]const u8{
        "\x00",
        "raw\nline",
        "unescaped\"quote",
        "\\",
        "\\q",
        "\\x41",
        "\\u",
        "\\u123",
        "\\u12g4",
        "\\uD800",
        "\\uD800\\u0041",
        "\\uDC00",
        "\\uDFFF\\uD800",
    };

    for (cases) |raw| {
        var output: [32]u8 = @splat(0xa5);
        try testing.expectError(error.InvalidEscape, json_value.decodeString(raw, &output));
        try expectFilled(&output, 0xa5);
    }
}

test "decodeString rejects malformed raw UTF-8 without writing" {
    const overlong = [_]u8{ 0xc0, 0xaf };
    const encoded_surrogate = [_]u8{ 0xed, 0xa0, 0x80 };
    const too_large = [_]u8{ 0xf4, 0x90, 0x80, 0x80 };
    const truncated = [_]u8{ 0xe2, 0x82 };
    const cases = [_][]const u8{
        &overlong,
        &encoded_surrogate,
        &too_large,
        &truncated,
    };

    for (cases) |raw| {
        var output: [16]u8 = @splat(0xa5);
        try testing.expectError(error.InvalidUtf8, json_value.decodeString(raw, &output));
        try expectFilled(&output, 0xa5);
    }
}

test "parseNumber classifies signed and unsigned integer boundaries" {
    try expectSigned("-1", -1);
    try expectSigned("-9223372036854775808", std.math.minInt(i64));

    try expectUnsigned("0", 0);
    try expectUnsigned("9223372036854775807", std.math.maxInt(i64));
    try expectUnsigned("9223372036854775808", @as(u64, std.math.maxInt(i64)) + 1);
    try expectUnsigned("18446744073709551615", std.math.maxInt(u64));
}

test "parseNumber preserves negative zero and rejects integer overflow" {
    try expectFloatBits("-0", 0x8000_0000_0000_0000);
    try expectFloatBits("-0.0", 0x8000_0000_0000_0000);
    try expectFloatBits("-0e99", 0x8000_0000_0000_0000);

    try testing.expectError(
        error.InvalidNumber,
        json_value.parseNumber("-9223372036854775809"),
    );
    try testing.expectError(
        error.InvalidNumber,
        json_value.parseNumber("18446744073709551616"),
    );
}

test "parseNumber preserves strict finite float conversion bits" {
    try expectFloatBits("1.5", 0x3ff8_0000_0000_0000);
    try expectFloatBits("6.25e-1", 0x3fe4_0000_0000_0000);
    try expectFloatBits("1.7976931348623157e308", 0x7fef_ffff_ffff_ffff);
    try expectFloatBits("5e-324", 0x0000_0000_0000_0001);
    try expectFloatBits("1e-324", 0x0000_0000_0000_0000);
    try expectFloatBits("-1e-324", 0x8000_0000_0000_0000);

    try testing.expectError(error.InvalidNumber, json_value.parseNumber("1e309"));
    try testing.expectError(error.InvalidNumber, json_value.parseNumber("-1e309"));
}

test "parseNumber validates the complete strict grammar" {
    const invalid = [_][]const u8{
        "",
        "-",
        "+1",
        ".1",
        "1.",
        "01",
        "-01",
        "1.e2",
        "1e",
        "1e+",
        "1e-",
        "1a",
        " 1",
        "1 ",
        "0x10",
        "1_0",
        "NaN",
        "Infinity",
        "true",
        "é",
    };

    for (invalid) |raw| {
        try testing.expectError(error.InvalidNumber, json_value.parseNumber(raw));
    }
}

test "parseNumber preserves the exact borrowed raw span" {
    const source = "x-12.5e+2y";
    const raw = source[1 .. source.len - 1];
    const view = try json_value.parseNumber(raw);

    try testing.expect(view.raw.ptr == source.ptr + 1);
    try testing.expectEqual(raw.len, view.raw.len);
    try testing.expectEqualStrings("-12.5e+2", view.raw);
    switch (view.value) {
        .float => |actual| try testing.expectEqual(
            @as(u64, @bitCast(@as(f64, -1250.0))),
            @as(u64, @bitCast(actual)),
        ),
        else => return error.UnexpectedNumberKind,
    }
}
