const std = @import("std");
const simd = @import("simd_lib");
const testing = std.testing;

const assert = std.debug.assert;
const VLEN = simd.default_vector_len;
const BitMask = simd.Mask(VLEN);
const debug = simd.debug;

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
    comptime assert(text.len > 0);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll("\x1b[1m=== SIMD Vector Visualizer (Composite Multi-Mask Orthogonal Styling) ===\x1b[0m\n\n");
    try writer.print("{s}\n\n", .{text});

    var chunk_iterator = simd.windows(u8, VLEN, text, @as(u8, 0));
    var starts_in_string = false;
    var prev_ends_in_backslash = false;
    const chunk_count = @divFloor(text.len + VLEN - 1, VLEN);

    for (0..chunk_count) |chunk_idx| {
        const bytes = chunk_iterator.next() orelse unreachable;

        const backslash_mask = simd.matchByte(VLEN, bytes, '\\');
        const bs_runs = simd.computeBackslashRuns(
            BitMask,
            backslash_mask,
            prev_ends_in_backslash,
        );
        prev_ends_in_backslash = bs_runs.ends_in_backslash;

        const raw_quotes = simd.matchByte(VLEN, bytes, '"');
        const unescaped_quotes = raw_quotes & ~bs_runs.odd_length_ends;

        const prev_fill: BitMask = if (starts_in_string) ~@as(BitMask, 0) else 0;
        const inside_without_closing =
            simd.prefixXor(BitMask, unescaped_quotes) ^ prev_fill;
        const string_mask = inside_without_closing | unescaped_quotes;
        const top_bit: BitMask = @as(BitMask, 1) <<
            @as(std.math.Log2Int(BitMask), @intCast(VLEN - 1));
        starts_in_string = (inside_without_closing & top_bit) != 0;

        const digits = simd.matchRange(VLEN, bytes, '0', '9');
        const periods = simd.matchByte(VLEN, bytes, '.');
        const minus = simd.matchByte(VLEN, bytes, '-');
        const numeric_mask = (digits | periods | minus) & ~string_mask;

        const structurals = simd.matchAny4(VLEN, bytes, '{', '}', '[', ']') |
            simd.matchAny2(VLEN, bytes, ':', ',');
        const structural_mask = structurals & ~string_mask;

        const layers = [_]debug.HighlightLayer(VLEN){
            .{
                .mask = unescaped_quotes,
                .style = .{ .bg_color_256 = 220, .fg_color_256 = 16, .bold = true },
                .name = "quotes",
            },
            .{
                .mask = string_mask & ~unescaped_quotes,
                .style = .{ .fg_color_256 = 34, .italic = true },
                .name = "string-content",
            },
            .{
                .mask = numeric_mask,
                .style = .{ .fg_color_256 = 39, .underline = true, .bold = true },
                .name = "numeric",
            },
            .{
                .mask = structural_mask,
                .style = .{ .bg_color_256 = 99, .fg_color_256 = 15, .bold = true },
                .name = "structural",
            },
        };

        var note_buffer: [64]u8 = undefined;
        const note = try std.fmt.bufPrint(&note_buffer, "chunk [{d}/{d}]", .{ chunk_idx + 1, chunk_count });
        try debug.highlightMulti(VLEN, bytes, &layers, note, writer);
    }
    assert(chunk_iterator.next() == null);
    try writer.writeAll("\n");
    try writer.flush();
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
