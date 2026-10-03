//! ANSI-highlighted rendering of a matched vector, for terminal diagnostics.
//!
//! `highlightMulti` walks one vector-width chunk, resolves the style each lane
//! gets from the highlight layers that name it, and writes the result plus a
//! caption to a writer the caller supplies. `printAscii` is the single-byte
//! case it uses. Callers reach this as `debug` from the package root.
//!
//! The module acquires no capability of its own: the writer the caller passes
//! carries the I/O, and no reference to it is kept after the call. Nothing is
//! allocated here beyond what that writer already owns.

const std = @import("std");
const simd = @import("simd.zig");
const testing = std.testing;

/// One set of terminal attributes, applied to a lane by a highlight layer.
///
/// `.{}` is the unstyled default. The colour fields are xterm-256 palette
/// indexes rather than true colour, and the five booleans are the attributes
/// `highlightMulti` emits.
pub const Style = struct {
    /// Background palette index, or `null`. Layers compose in slice order, so
    /// `null` here means this layer says nothing about the background and an
    /// earlier layer's choice stands, not that the lane gets no background.
    bg_color_256: ?u8 = null,
    /// Foreground palette index, or `null`, with the same meaning as
    /// `bg_color_256`.
    fg_color_256: ?u8 = null,
    /// Whether the lane is written bold.
    bold: bool = false,
    /// Whether the lane is written dim.
    dim: bool = false,
    /// Whether the lane is written italic.
    italic: bool = false,
    /// Whether the lane is underlined.
    underline: bool = false,
    /// Whether the lane is struck through.
    strikethrough: bool = false,

    /// Whether this style sets nothing at all.
    ///
    /// `true` only when both colours are `null` and all five attributes are
    /// `false`. It reports what this value says, not what a caller composing
    /// several layers would end up rendering.
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

/// One named rule over a vector: the lanes it matches and the style they get.
///
/// `vlen` is the lane count, and a layer only ever styles a vector and a set of
/// masks at that same width; a layer built for another width is a different
/// type and will not reach `highlightMulti` at all. The value owns nothing.
pub fn HighlightLayer(comptime vlen: usize) type {
    return struct {
        /// Lanes this layer applies to. Lane `i` is bit `i`, in the same
        /// numbering `simd` matchers produce.
        mask: simd.Mask(vlen),
        /// What those lanes get. A field left unset keeps whatever an earlier
        /// layer chose, so layers compose rather than replace one another.
        style: Style,
        /// A label for the rule. `highlightMulti` never reads it; it is here so
        /// a caller can name what the layer matched in its own output.
        name: []const u8,
    };
}

/// Writes one byte as a single visible character.
///
/// A printable ASCII byte is written as itself. Any other byte, `0x00` through
/// `0xff`, is written as the control picture U+2400 plus that byte's value, so
/// every input byte renders as one printable code point and cannot be mistaken
/// for, or break, the escape sequences written around it. Nothing is retained
/// between calls.
///
/// Duck-typed writer: provide `writeByte(byte: u8) Error!void` and
/// `writeAll(bytes: []const u8) Error!void`, where `Error` is the writer's set.
/// Missing member names produce a compile error naming the required signature;
/// ordinary Zig calls require those members to be callable with the documented
/// argument and result types. No concrete writer type is required. The writer
/// is borrowed only for this call.
/// This module obtains no `std.Io`; blocking and cancellation depend on the
/// supplied writer, and its errors propagate unchanged.
pub fn printAscii(character: u8, writer: anytype) !void {
    comptime {
        requireWriterMember(@TypeOf(writer), "printAscii", "writeByte", "writeByte(byte: u8) Error!void");
        requireWriterMember(@TypeOf(writer), "printAscii", "writeAll", "writeAll(bytes: []const u8) Error!void");
    }
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

/// Writes one vector-width chunk with ANSI styling applied to matched lanes.
///
/// `bytes` has exactly `vlen` lanes and every layer's mask is `vlen` lanes
/// wide, so one call styles exactly `vlen` characters however narrow the
/// logical width is. Lanes are written from index 0 upward. For each lane the
/// layers are applied in slice order, so a later layer's set field wins and an
/// unset field keeps what an earlier layer chose; a lane no layer names is
/// written unstyled. A lane any layer does name gets its attributes emitted
/// before its character and a reset after it, so no styling survives into
/// `note`.
///
/// `note` is appended after the lanes as two spaces, the note, and a newline.
///
/// Duck-typed writer: provide `writeByte(byte: u8) Error!void`,
/// `writeAll(bytes: []const u8) Error!void`, and
/// `print(comptime fmt: []const u8, args: anytype) Error!void`.
/// `Error` is the writer's error set. Discovery checks member names rather than
/// concrete type identity. Missing names produce signature-bearing compile errors;
/// ordinary Zig calls check callability and signatures. The writer is borrowed
/// only for the call. This module obtains no `std.Io`; blocking, allocation and
/// cancellation inside the writer belong to its implementation.
///
/// Output is not transactional. A failure can leave a styled chunk prefix,
/// unreset attributes, or a partially written trailing note. Writer errors
/// propagate unchanged; the caller decides whether to discard or continue.
pub fn highlightMulti(
    comptime vlen: usize,
    bytes: simd.Vec(u8, vlen),
    layers: []const HighlightLayer(vlen),
    note: []const u8,
    writer: anytype,
) !void {
    comptime {
        requireWriterMember(@TypeOf(writer), "highlightMulti", "writeByte", "writeByte(byte: u8) Error!void");
        requireWriterMember(@TypeOf(writer), "highlightMulti", "writeAll", "writeAll(bytes: []const u8) Error!void");
        requireWriterMember(
            @TypeOf(writer),
            "highlightMulti",
            "print",
            "print(comptime fmt: []const u8, args: anytype) Error!void",
        );
    }
    const mask = simd.Mask(vlen);
    const shift = std.math.Log2Int(mask);
    const values: [vlen]u8 = bytes;

    for (values, 0..) |character, bit_index| {
        const bit: mask = @as(mask, 1) <<
            @as(shift, @intCast(bit_index));
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

fn requireWriterMember(
    comptime Writer: type,
    comptime operation: []const u8,
    comptime member: []const u8,
    comptime signature: []const u8,
) void {
    var surface = Writer;
    while (true) {
        switch (@typeInfo(surface)) {
            .pointer => |pointer| {
                if (pointer.size != .one) break;
                surface = pointer.child;
            },
            else => break,
        }
    }
    const present = switch (@typeInfo(surface)) {
        .@"struct", .@"union" => @hasDecl(surface, member) or @hasField(surface, member),
        .@"enum", .@"opaque" => @hasDecl(surface, member),
        else => false,
    };
    if (!present) {
        @compileError(operation ++ " requires writer." ++ signature ++
            "; missing " ++ member ++ " on " ++ @typeName(Writer));
    }
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
    const vlen = 24;
    var bytes: simd.Vec(u8, vlen) = @splat('a');
    bytes[0] = 'b';
    bytes[7] = 'b';
    bytes[vlen - 1] = 'b';
    const layers = [_]HighlightLayer(vlen){.{
        .mask = simd.matchByte(vlen, bytes, 'b'),
        .style = .{ .bold = true },
        .name = "b",
    }};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try highlightMulti(vlen, bytes, &layers, "b", &output.writer);

    // Exactly the three named lanes are styled: one style sequence and one
    // reset each.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.written(), "\x1b[1m"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.written(), "\x1b[0m"));
}
