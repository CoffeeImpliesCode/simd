const std = @import("std");
const lib = @import("simd_lib");

const VLEN = 64;
const U8Vec = @Vector(VLEN, u8);
const BVec = @Vector(VLEN, bool);

pub fn I(comptime bit_count: u16) type {
    return std.meta.Int(.signed, bit_count);
}

pub fn U(comptime bit_count: u16) type {
    return std.meta.Int(.unsigned, bit_count);
}

const checker01: U(VLEN) = @bitCast(@as(@Vector(VLEN / 2, u2), @splat(2)));
const checker10 = ~checker01;

pub fn ChunkIterator(comptime T: type, comptime len: usize, comptime pad: bool) type {
    return struct {
        fill: ?T,
        rest: []const T,
        pub fn init(data: []const T, fill: ?T) ChunkIterator {
            return .{ .fill = fill, .rest = data };
        }
        pub fn next(self: *@This()) ?@Vector(len, T) {
            if (self.rest.len < len) {
                if (self.rest.len == 0 or !pad) return null;
                var v: @Vector(len, T) = @splat(self.fill.?);
                for (0..self.rest.len) |j| v[j] = self.rest[j];
                self.rest = &.{};
                return v;
            }
            const v: @Vector(len, T) = self.rest[0..len].*;
            self.rest = self.rest[len..];
            return v;
        }
    };
}

pub fn windows(
    comptime T: type,
    comptime len: usize,
    data: []const T,
    comptime fill: ?T,
) ChunkIterator(T, len, fill != null) {
    return ChunkIterator(T, len, fill != null){
        .fill = fill,
        .rest = data,
    };
}

pub const Mode = enum {
    compact_char,
    char,
    // hex,
    num,
    marker,
};

pub fn print(comptime S: type, v: @Vector(VLEN, S), comptime mode: Mode, note: []const u8, writer: anytype) !void {
    const s: [VLEN]S = v;
    switch (mode) {
        .compact_char => {
            for (s) |val| {
                const c: u8 = switch (S) {
                    bool => @intFromBool(val),
                    u1, u2, u4, u8 => @intCast(val),
                    else => @compileError("Unimplemented."),
                };
                if (std.ascii.isPrint(c)) {
                    try writer.print("{c:1}", .{c});
                } else {
                    var buf = std.mem.zeroes([4]u8);
                    const len = try std.unicode.utf8Encode(0x2400 + @as(u21, c), &buf);
                    // try writer.print("�\u{2424}", .{});
                    try writer.print("{s}", .{buf[0..len]});
                }
            }

            try writer.print("  {s}\n", .{note});
            // for (0..s.len - 1) |_| try writer.print("───┼", .{});
            // try writer.print("───┤  {s}\n│", .{note});
            // for (s) |val| try writer.print("x{x:02}│", .{val});
            // try writer.print("\n└", .{});
            // for (0..s.len - 1) |_| try writer.print("───┴", .{});
            // try writer.print("───┘\n", .{});

        },
        .char => {
            try writer.print("┌", .{});
            for (0..s.len - 1) |_| try writer.print("───┬", .{});
            try writer.print("───┐\n│", .{});

            for (s) |val| {
                const c: u8 = switch (S) {
                    bool => @intFromBool(val),
                    u1, u2, u4, u8 => @intCast(val),
                    else => @compileError("Unimplemented."),
                };
                if (std.ascii.isPrint(c)) {
                    try writer.print("{c:2} │", .{c});
                } else {
                    try writer.print(" � │", .{});
                }
            }
            try writer.print("\n├", .{});
            for (0..s.len - 1) |_| try writer.print("───┼", .{});
            try writer.print("───┤  {s}\n│", .{note});
            for (s) |val| try writer.print("x{x:02}│", .{val});
            try writer.print("\n└", .{});
            for (0..s.len - 1) |_| try writer.print("───┴", .{});
            try writer.print("───┘\n", .{});
        },
        .num => {
            for (s) |val| {
                try writer.print("{d:3} ", .{val});
            }
            try writer.print("  {s}\n", .{note});
        },
        .marker => {
            for (s) |val| {
                const m = switch (S) {
                    bool => val,
                    u1, u2, u4, u8 => val > 0,
                    else => @compileError("Unimplemented."),
                };
                if (m) {
                    try writer.print("  ↑ ", .{});
                } else {
                    try writer.print("    ", .{});
                }
            }
            try writer.print("  {s}\n", .{note});
        },
    }
}

pub fn printAscii(c: u8, writer: anytype) !void {
    if (std.ascii.isPrint(c)) try writer.writeByte(c) else {
        var buf = std.mem.zeroes([4]u8);
        const len = try std.unicode.utf8Encode(0x2400 + @as(u21, c), &buf);
        try writer.writeAll(buf[0..len]);
    }
}

pub fn highlight(bytes: @Vector(VLEN, u8), j: anytype, note: []const u8, col: u8, w: anytype) !void {
    var k = j;
    for (0..VLEN) |idx| {
        if (k & 1 == 1) {
            try w.print("\x1b[48:5:{d}m", .{col});
        }
        try printAscii(bytes[idx], w);
        if (k & 1 == 1) {
            try w.print("\x1b[0m", .{});
        }
        k >>= 1;
    }
    try w.print("  {s}\n", .{note});
}

pub fn printInt(
    /// the vector to print
    j: anytype,
    note: []const u8,
    /// `w`: instance of `std.io.GenericWriter`
    w: anytype,
) !void {
    const len = @typeInfo(@TypeOf(j)).int.bits;
    var k = j;
    for (0..len) |_| {
        const s: []const u8 = if (k & 1 != 0) "1" else "_";
        // try w.print("__{c}_", .{c});
        try w.print("{s}", .{s});
        k = k >> 1;
    }
    try w.print("  {s}\n", .{note});
}

fn prefixXor(bitmask: anytype) @TypeOf(bitmask) {
    var x = bitmask;
    inline for (0..(@typeInfo(std.math.Log2Int(@TypeOf(bitmask))).int.bits)) |j|
        x ^= x << comptime (1 << j);
    return x;
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

pub fn matchStart(
    v: U8Vec,
    comptime s: []const u8,
) U(VLEN) {
    const m: U(VLEN) = ((1 << VLEN - 1) - 1) | (1 << VLEN - 1);
    inline for (s, 0..) |c, shift| {
        _ = v;
        _ = c;
        _ = shift;
        _ = m;
    }
}

pub fn main() !void {
    std.debug.print("{s}\n", .{text});
    const w = std.io.getStdOut().writer();
    var ci = windows(u8, VLEN, text, 0);
    const quote: U8Vec = @splat('"');
    var prev_q: U(VLEN) = 0;
    while (ci.next()) |c| {
        try print(u8, c, .compact_char, "input", w);
        var q: U(VLEN) = @bitCast(c == quote);
        // try print_int(q, "quotes", w);
        try highlight(c, q, "quotes", 27, w);
        const od: U(VLEN) = 0;
        q &= ~od;
        q = (prefixXor(q) ^ prev_q | q);
        prev_q = if (q & (1 << (VLEN - 1)) != 0) (~@as(U(VLEN), 0)) else 0;
        try highlight(c, q, "strings", 28, w);

        const zero: U8Vec = @splat('0');
        const nine: U8Vec = @splat('9');
        const period: U8Vec = @splat('.');
        const gezero: U(VLEN) = @bitCast(c >= zero);
        const lenine: U(VLEN) = @bitCast(c <= nine);
        const p: U(VLEN) = @bitCast(c == period);
        const numeric = (gezero & lenine | p) & ~q;
        try highlight(c, numeric, "numeric", 30, w);

        // const true0 = "truetruetruetruetruetruetruetrue"[0..VLEN];
        // const true1 = "ruetruetruetruetruetruetruetruet"[0..VLEN];
        // const true2 = "uetruetruetruetruetruetruetruetr"[0..VLEN];
        // const true3 = "etruetruetruetruetruetruetruetru"[0..VLEN];

        // try print_int(m_, "is `o`", w);
        // std.debug.print("{c:2}\n\n", .{_1_0});
        try w.writeAll("\n");
    }
}
