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

pub const HighlightLayer = struct {
    mask: u64,
    style: Style,
    name: []const u8,
};

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
    bytes: simd.Vec(64, u8),
    layers: []const HighlightLayer,
    note: []const u8,
    writer: anytype,
) !void {
    const values: [64]u8 = bytes;

    for (values, 0..) |character, bit_index| {
        const bit: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
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
