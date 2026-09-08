const std = @import("std");
const stage2 = @import("src/core/stage2.zig");

const Case = struct { name: []const u8, pattern: []const u8, repetitions: usize };
const cases = [_]Case{
    .{ .name = "short", .pattern = "short text", .repetitions = 1 },
    .{ .name = "ascii", .pattern = "abcdefghijklmno", .repetitions = 32768 },
    .{ .name = "unicode", .pattern = "Grüße ☃ café 東京", .repetitions = 32768 },
    .{ .name = "escaped", .pattern = "text\\nquote\\\"slash\\\\end", .repetitions = 32768 },
};

fn makeInput(allocator: std.mem.Allocator, case: Case) ![]u8 {
    const body_len = try std.math.mul(usize, case.pattern.len, case.repetitions);
    const input = try allocator.alloc(u8, try std.math.add(usize, body_len, 2));
    input[0] = '"';
    for (0..case.repetitions) |index| {
        const start = 1 + index * case.pattern.len;
        @memcpy(input[start..][0..case.pattern.len], case.pattern);
    }
    input[input.len - 1] = '"';
    return input;
}

fn runCase(io: std.Io, writer: *std.Io.Writer, name: []const u8, input: []const u8) !void {
    const offsets = [_]u32{0};
    const view = try stage2.IndexView.init(input, &offsets, 0);
    var reader = try stage2.TokenReader.init(input, view, .json);
    const warm = (try reader.next()) orelse return error.MissingString;
    if (warm.word.tapeKind() != .string) return error.WrongKind;
    if (!std.mem.eql(u8, warm.raw, input[1 .. input.len - 1])) return error.WrongSpan;
    if (try reader.next() != null) return error.ExtraToken;

    const iterations: usize = if (input.len < 32) 65536 else 16;
    const input_hash = std.hash.Wyhash.hash(0, input);
    var checksum: u64 = input_hash;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(input.ptr);
        try reader.reset(input, view, .json);
        const token = (try reader.next()) orelse return error.MissingString;
        const consumed = @min(token.raw.len, 64);
        checksum = std.hash.Wyhash.hash(checksum, token.raw[0..consumed]);
        checksum ^= @as(u64, @intCast(token.raw.len));
        if (try reader.next() != null) return error.ExtraToken;
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    if (end < start) return error.ClockWentBackwards;
    std.mem.doNotOptimizeAway(&checksum);
    try writer.print("{s},{d},{x},{d},{d},{x}\n", .{
        name, input.len, input_hash, iterations, end - start, checksum,
    });
}

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output_writer.interface;
    try writer.writeAll("case,input_bytes,input_hash,iterations,elapsed_ns,checksum\n");
    for (cases) |case| {
        const input = try makeInput(init.gpa, case);
        defer init.gpa.free(input);
        try runCase(init.io, writer, case.name, input);
    }
    try writer.flush();
}
