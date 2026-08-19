const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const assert = std.debug.assert;
const vector_len = lib.default_vector_len;
const ByteVector = lib.Vec(vector_len, u8);
const BitMask = lib.Mask(vector_len);

pub const Mode = enum {
    compact_char,
    char,
    num,
    marker,
};

fn valueToByte(comptime S: type, value: S) u8 {
    return switch (S) {
        bool => @intFromBool(value),
        u1, u2, u4, u8 => @intCast(value),
        else => @compileError("unsupported display element type"),
    };
}

fn valueIsSet(comptime S: type, value: S) bool {
    return switch (S) {
        bool => value,
        u1, u2, u4, u8 => value > 0,
        else => @compileError("unsupported marker element type"),
    };
}

fn print(
    comptime S: type,
    vector: lib.Vec(vector_len, S),
    comptime mode: Mode,
    note: []const u8,
    writer: anytype,
) !void {
    const values: [vector_len]S = vector;
    switch (mode) {
        .compact_char => {
            for (values) |value| {
                const character = valueToByte(S, value);
                if (std.ascii.isPrint(character)) {
                    try writer.print("{c:1}", .{character});
                } else {
                    var buffer: [4]u8 = undefined;
                    const encoded_len = try std.unicode.utf8Encode(
                        0x2400 + @as(u21, character),
                        &buffer,
                    );
                    try writer.print("{s}", .{buffer[0..encoded_len]});
                }
            }
            try writer.print("  {s}\n", .{note});
        },
        .char => {
            try writer.writeAll("┌");
            for (0..values.len - 1) |_| {
                try writer.writeAll("───┬");
            }
            try writer.writeAll("───┐\n│");

            for (values) |value| {
                const character = valueToByte(S, value);
                if (std.ascii.isPrint(character)) {
                    try writer.print("{c:2} │", .{character});
                } else {
                    try writer.writeAll(" � │");
                }
            }
            try writer.writeAll("\n├");
            for (0..values.len - 1) |_| {
                try writer.writeAll("───┼");
            }
            try writer.print("───┤  {s}\n│", .{note});
            for (values) |value| {
                try writer.print("x{x:02}│", .{valueToByte(S, value)});
            }
            try writer.writeAll("\n└");
            for (0..values.len - 1) |_| {
                try writer.writeAll("───┴");
            }
            try writer.writeAll("───┘\n");
        },
        .num => {
            for (values) |value| {
                try writer.print("{d:3} ", .{value});
            }
            try writer.print("  {s}\n", .{note});
        },
        .marker => {
            for (values) |value| {
                if (valueIsSet(S, value)) {
                    try writer.writeAll("  ↑ ");
                } else {
                    try writer.writeAll("    ");
                }
            }
            try writer.print("  {s}\n", .{note});
        },
    }
}

fn printAscii(character: u8, writer: anytype) !void {
    if (std.ascii.isPrint(character)) {
        try writer.writeByte(character);
    } else {
        var buffer: [4]u8 = undefined;
        const encoded_len = try std.unicode.utf8Encode(
            0x2400 + @as(u21, character),
            &buffer,
        );
        try writer.writeAll(buffer[0..encoded_len]);
    }
}

fn highlight(
    bytes: ByteVector,
    mask: BitMask,
    note: []const u8,
    color: u8,
    writer: anytype,
) !void {
    const values: [vector_len]u8 = bytes;
    var remaining_mask = mask;
    for (values) |character| {
        if ((remaining_mask & 1) != 0) {
            try writer.print("\x1b[48:5:{d}m", .{color});
        }
        try printAscii(character, writer);
        if ((remaining_mask & 1) != 0) {
            try writer.writeAll("\x1b[0m");
        }
        remaining_mask >>= 1;
    }
    try writer.print("  {s}\n", .{note});
}

const text =
    \\{ "Width": 800,
    \\   "Height": 600,
    \\   "Title": "View from
    \\      my room",
    \\   "Url ": "http://ex.com
    \\      /img.png",
    \\   "Private " : false ,
    \\   "Thumbnail " : {
    \\     "Url":"http://ex.
    \\       com/th.png",
    \\     "Height ": 125.0,
    \\     "Width ": 100.0
    \\   },
    \\   "array": [
    \\     116,
    \\     943,
    \\     234
    \\   ],
    \\   "Owner": null
    \\}
;

pub fn main(init: std.process.Init) !void {
    comptime assert(vector_len == 64);
    comptime assert(text.len > 0);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.print("{s}\n", .{text});

    var chunk_iterator = lib.windows(u8, vector_len, text, @as(u8, 0));
    var starts_in_string = false;
    const chunk_count = @divFloor(text.len + vector_len - 1, vector_len);
    for (0..chunk_count) |_| {
        const bytes = chunk_iterator.next() orelse unreachable;
        try print(u8, bytes, .compact_char, "input", writer);

        const quotes_mask = lib.findQuotes(vector_len, bytes);
        try highlight(bytes, quotes_mask, "quotes", 27, writer);

        const strings = lib.classifyStrings64(quotes_mask, starts_in_string);
        starts_in_string = strings.ends_in_string;
        try highlight(bytes, strings.mask, "strings", 28, writer);

        const periods_mask = lib.matchByte(vector_len, bytes, '.');
        const numeric_mask = (lib.findDigits(vector_len, bytes) | periods_mask) & ~strings.mask;
        try highlight(bytes, numeric_mask, "numeric", 30, writer);
        try writer.writeByte('\n');
    }
    assert(chunk_iterator.next() == null);
    try writer.flush();
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
