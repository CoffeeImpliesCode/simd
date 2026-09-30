const std = @import("std");
const simd = @import("simd.zig");
const assert = std.debug.assert;
const testing = std.testing;

pub const Style = struct {
    bg_color_256: ?u8 = null,
    fg_color_256: ?u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,

    pub fn isDefault(self: Style) bool {
        return self.bg_color_256 == null and
            self.fg_color_256 == null and
            !self.bold and
            !self.dim and
            !self.italic and
            !self.underline and
            !self.strikethrough;
    }
};

pub fn HighlightLayer(comptime VLEN: usize) type {
    return struct {
        mask: simd.Mask(VLEN),
        style: Style,
        name: []const u8,
    };
}

pub fn printAscii(character: u8, writer: anytype) !void {
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

pub fn highlightMulti(
    comptime VLEN: usize,
    bytes: simd.Vec(VLEN, u8),
    layers: []const HighlightLayer(VLEN),
    note: []const u8,
    writer: anytype,
) !void {
    const Mask = simd.Mask(VLEN);
    const Shift = std.math.Log2Int(Mask);
    const values: [VLEN]u8 = bytes;

    for (values, 0..) |character, bit_index| {
        const bit: Mask = @as(Mask, 1) <<
            @as(Shift, @intCast(bit_index));
        var composite: Style = .{};
        var has_style = false;

        for (layers) |layer| {
            if ((layer.mask & bit) != 0) {
                has_style = true;
                if (layer.style.bg_color_256) |bg| composite.bg_color_256 = bg;
                if (layer.style.fg_color_256) |fg| composite.fg_color_256 = fg;
                if (layer.style.bold) composite.bold = true;
                if (layer.style.dim) composite.dim = true;
                if (layer.style.italic) composite.italic = true;
                if (layer.style.underline) composite.underline = true;
                if (layer.style.strikethrough) composite.strikethrough = true;
            }
        }

        if (has_style) {
            if (composite.bold) try writer.writeAll("\x1b[1m");
            if (composite.dim) try writer.writeAll("\x1b[2m");
            if (composite.italic) try writer.writeAll("\x1b[3m");
            if (composite.underline) try writer.writeAll("\x1b[4m");
            if (composite.strikethrough) try writer.writeAll("\x1b[9m");
            if (composite.fg_color_256) |fg| try writer.print("\x1b[38;5;{d}m", .{fg});
            if (composite.bg_color_256) |bg| try writer.print("\x1b[48;5;{d}m", .{bg});
        }

        try printAscii(character, writer);

        if (has_style) {
            try writer.writeAll("\x1b[0m");
        }
    }

    try writer.print("  {s}\n", .{note});
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "Style default check" {
    const s: Style = .{};
    try testing.expect(s.isDefault());
    const styled: Style = .{ .italic = true };
    try testing.expect(!styled.isDefault());
}

test "highlightMulti styles the lanes a mask names" {
    // Exercise a logical width narrower than its target storage while styling
    // exactly the lanes selected by the matcher.
    const VLEN = 24;
    var bytes: simd.Vec(VLEN, u8) = @splat('a');
    bytes[0] = 'b';
    bytes[7] = 'b';
    bytes[VLEN - 1] = 'b';
    const layers = [_]HighlightLayer(VLEN){.{
        .mask = simd.matchByte(VLEN, bytes, 'b'),
        .style = .{ .bold = true },
        .name = "b",
    }};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try highlightMulti(VLEN, bytes, &layers, "b", &output.writer);

    // Exactly the three named lanes are styled: one style sequence and one
    // reset each.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.written(), "\x1b[1m"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.written(), "\x1b[0m"));
}
