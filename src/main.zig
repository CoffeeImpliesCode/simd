const std = @import("std");
const lib = @import("simd_lib");
const testing = std.testing;

const assert = std.debug.assert;
const vector_len = lib.default_vector_len;
const ByteVector = lib.Vec(vector_len, u8);
const BitMask = lib.Mask(vector_len);
const debug = lib.debug;

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

    try writer.writeAll("\x1b[1m=== SIMD Vector Visualizer (Composite Multi-Mask Orthogonal Styling) ===\x1b[0m\n\n");
    try writer.print("{s}\n\n", .{text});

    var chunk_iterator = lib.windows(u8, vector_len, text, @as(u8, 0));
    var starts_in_string = false;
    var prev_ends_in_backslash = false;
    const chunk_count = @divFloor(text.len + vector_len - 1, vector_len);

    for (0..chunk_count) |chunk_idx| {
        const bytes = chunk_iterator.next() orelse unreachable;

        const backslash_mask = lib.matchByte(vector_len, bytes, '\\');
        const bs_runs = lib.computeBackslashRuns64(backslash_mask, prev_ends_in_backslash);
        prev_ends_in_backslash = bs_runs.ends_in_backslash;

        const raw_quotes = lib.matchByte(vector_len, bytes, '"');
        const unescaped_quotes = raw_quotes & ~bs_runs.odd_length_ends;

        const prev_fill: u64 = if (starts_in_string) ~@as(u64, 0) else 0;
        const inside_without_closing = lib.prefixXor(u64, unescaped_quotes) ^ prev_fill;
        const string_mask = inside_without_closing | unescaped_quotes;
        starts_in_string = (inside_without_closing & (@as(u64, 1) << 63)) != 0;

        const digits = lib.matchRange(vector_len, bytes, '0', '9');
        const periods = lib.matchByte(vector_len, bytes, '.');
        const minus = lib.matchByte(vector_len, bytes, '-');
        const numeric_mask = (digits | periods | minus) & ~string_mask;

        const structurals = lib.matchAny4(vector_len, bytes, '{', '}', '[', ']') |
            lib.matchAny2(vector_len, bytes, ':', ',');
        const structural_mask = structurals & ~string_mask;

        const layers = [_]debug.HighlightLayer{
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
        try debug.highlightMulti(bytes, &layers, note, writer);
    }
    assert(chunk_iterator.next() == null);
    try writer.writeAll("\n");
    try writer.flush();
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
