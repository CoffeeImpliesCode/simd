const std = @import("std");
const simd = @import("src/core/simd.zig");

const vector_len: usize = simd.default_vector_len;
const Vec = simd.Vec(vector_len, u8);
const Mask = simd.Mask(vector_len);
const input_len: usize = 1 << 20;
const iterations: usize = 8;

const BenchResult = struct {
    elapsed_ns: u64,
    checksum: u64,
};

fn mix(checksum: *u64, value: u64) void {
    checksum.* = (checksum.* ^ (value +% 0x9e3779b97f4a7c15)) *% 0x100000001b3;
}

fn elapsedNanoseconds(start: i96, end: i96) !u64 {
    if (end < start) return error.ClockWentBackwards;
    const delta = end - start;
    if (delta > std.math.maxInt(u64)) return error.ElapsedOverflow;
    return @intCast(delta);
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn oldWhitespaceMask(bytes: []const u8) u64 {
    var checksum: u64 = 0xcbf29ce484222325;
    var offset: usize = 0;
    while (offset + vector_len <= bytes.len) : (offset += vector_len) {
        const block: Vec = bytes[offset..][0..vector_len].*;
        const mask = simd.matchAny4(vector_len, block, ' ', '\t', '\n', '\r');
        mix(&checksum, mask);
    }
    if (offset < bytes.len) {
        var mask: Mask = 0;
        for (bytes[offset..], 0..) |byte, lane| {
            if (isJsonWhitespace(byte)) {
                mask |= @as(Mask, 1) << @as(std.math.Log2Int(Mask), @intCast(lane));
            }
        }
        mix(&checksum, mask);
    }
    return checksum;
}

fn newWhitespaceMask(bytes: []const u8) u64 {
    var checksum: u64 = 0xcbf29ce484222325;
    var offset: usize = 0;
    while (offset + vector_len <= bytes.len) : (offset += vector_len) {
        const block: Vec = bytes[offset..][0..vector_len].*;
        const mask: Mask = simd.matchJsonWhitespace(vector_len, block);
        mix(&checksum, mask);
    }
    if (offset < bytes.len) {
        var mask: Mask = 0;
        for (bytes[offset..], 0..) |byte, lane| {
            if (isJsonWhitespace(byte)) {
                mask |= @as(Mask, 1) <<
                    @as(std.math.Log2Int(Mask), @intCast(lane));
            }
        }
        mix(&checksum, mask);
    }
    return checksum;
}

fn maskPattern(block_index: usize) Mask {
    const rotated = @as(u64, @intCast(block_index *% 0x9e3779b9));
    const value = (rotated ^ (rotated >> 17) ^ 0xa5a5_5a5a_3c3c_c3c3) *% 0x27d4_eb2d;
    return @truncate(value);
}

fn oldScratchExtract(bytes_len: usize, seed: usize) u64 {
    var output: [vector_len]u32 = undefined;
    var checksum: u64 = 0xcbf29ce484222325;
    var block_index: usize = 0;
    var base_offset: usize = 0;
    while (base_offset < bytes_len) {
        const mask = maskPattern(block_index +% seed);
        var scratch: [vector_len]u32 = undefined;
        const scratch_count = simd.extractBitIndexes(Mask, mask, base_offset, &scratch);
        @memcpy(output[0..scratch_count], scratch[0..scratch_count]);
        for (output[0..scratch_count]) |index| mix(&checksum, index);
        base_offset += vector_len;
        block_index += 1;
    }
    std.mem.doNotOptimizeAway(&output);
    return checksum;
}

fn checkedDirectExtract(bytes_len: usize, seed: usize) !u64 {
    var output: [vector_len]u32 = undefined;
    var checksum: u64 = 0xcbf29ce484222325;
    var block_index: usize = 0;
    var base_offset: usize = 0;
    while (base_offset < bytes_len) {
        const bitmask = maskPattern(block_index +% seed);
        const output_count = simd.extractBitIndexesChecked(
            Mask,
            bitmask,
            base_offset,
            &output,
        ) catch |err| return err;
        for (output[0..output_count]) |index| mix(&checksum, index);
        base_offset += vector_len;
        block_index += 1;
    }
    std.mem.doNotOptimizeAway(&output);
    return checksum;
}

fn oldTrailingRunOdd(block: Vec, valid_count: usize, previous_odd: bool) bool {
    if (valid_count == 0) return false;
    const bytes: [vector_len]u8 = block;
    var index = valid_count;
    var run_length: usize = 0;
    while (index > 0 and bytes[index - 1] == '\\') : (index -= 1) {
        run_length += 1;
    }
    if (index == 0) return (run_length % 2 == 0) == previous_odd;
    return run_length % 2 != 0;
}

fn oldReverseByteCarry(bytes: []const u8) u64 {
    var previous_odd = false;
    var checksum: u64 = 0xcbf29ce484222325;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += vector_len) {
        const valid_count = @min(bytes.len - offset, vector_len);
        var block: [vector_len]u8 = @splat(0);
        @memcpy(block[0..valid_count], bytes[offset..][0..valid_count]);
        const vector: Vec = block;
        const backslashes: Mask = simd.matchByte(vector_len, vector, '\\');
        mix(&checksum, backslashes);
        const odd = oldTrailingRunOdd(block, valid_count, previous_odd);
        mix(&checksum, @intFromBool(odd));
        previous_odd = odd;
    }
    return checksum;
}

fn newMaskCarry(bytes: []const u8) u64 {
    var previous_odd = false;
    var checksum: u64 = 0xcbf29ce484222325;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += vector_len) {
        const valid_count = @min(bytes.len - offset, vector_len);
        var block: [vector_len]u8 = @splat(0);
        @memcpy(block[0..valid_count], bytes[offset..][0..valid_count]);
        const vector: Vec = block;
        const backslashes: Mask = simd.matchByte(vector_len, vector, '\\');
        mix(&checksum, backslashes);
        const odd = simd.trailingRunOdd(
            vector_len,
            backslashes,
            valid_count,
            previous_odd,
        );
        mix(&checksum, @intFromBool(odd));
        previous_odd = odd;
    }
    return checksum;
}

fn timeWhitespace(
    io: std.Io,
    bytes: []const u8,
    comptime function: fn ([]const u8) u64,
) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(bytes.ptr);
        mix(&checksum, function(bytes));
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{ .elapsed_ns = try elapsedNanoseconds(start, end), .checksum = checksum };
}

fn timeScratch(io: std.Io, bytes_len: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |seed| mix(&checksum, oldScratchExtract(bytes_len, seed));
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{ .elapsed_ns = try elapsedNanoseconds(start, end), .checksum = checksum };
}

fn timeDirect(io: std.Io, bytes_len: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |seed| mix(&checksum, try checkedDirectExtract(bytes_len, seed));
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{ .elapsed_ns = try elapsedNanoseconds(start, end), .checksum = checksum };
}

fn timeCarry(
    io: std.Io,
    bytes: []const u8,
    comptime function: fn ([]const u8) u64,
) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(bytes.ptr);
        mix(&checksum, function(bytes));
    }
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    std.mem.doNotOptimizeAway(&checksum);
    return .{ .elapsed_ns = try elapsedNanoseconds(start, end), .checksum = checksum };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const input = try gpa.alloc(u8, input_len);
    defer gpa.free(input);
    for (input, 0..) |*byte, index| {
        const phase = index % 37;
        byte.* = switch (phase) {
            0 => ' ',
            1 => '\t',
            2 => '\n',
            3 => '\r',
            4, 5, 6, 7 => '\\',
            else => @intCast((index *% 29 + 17) % 256),
        };
    }

    const whitespace_old = try timeWhitespace(init.io, input, oldWhitespaceMask);
    const whitespace_new = try timeWhitespace(init.io, input, newWhitespaceMask);
    if (whitespace_old.checksum != whitespace_new.checksum) return error.ChecksumMismatch;

    const scratch = try timeScratch(init.io, input.len);
    const direct = try timeDirect(init.io, input.len);
    if (scratch.checksum != direct.checksum) return error.ChecksumMismatch;

    const carry_old = try timeCarry(init.io, input, oldReverseByteCarry);
    const carry_new = try timeCarry(init.io, input, newMaskCarry);
    if (carry_old.checksum != carry_new.checksum) return error.ChecksumMismatch;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("candidate,elapsed_ns,checksum,iterations,input_bytes\n", .{});
    try stdout.print("old4_equality,{d},{x},{d},{d}\n", .{
        whitespace_old.elapsed_ns,
        whitespace_old.checksum,
        iterations,
        input.len,
    });
    try stdout.print("new_whitespace,{d},{x},{d},{d}\n", .{
        whitespace_new.elapsed_ns,
        whitespace_new.checksum,
        iterations,
        input.len,
    });
    try stdout.print("oldscratch_emission,{d},{x},{d},{d}\n", .{
        scratch.elapsed_ns,
        scratch.checksum,
        iterations,
        input.len,
    });
    try stdout.print("checked_direct_output,{d},{x},{d},{d}\n", .{
        direct.elapsed_ns,
        direct.checksum,
        iterations,
        input.len,
    });
    try stdout.print("reverse_byte_carry,{d},{x},{d},{d}\n", .{
        carry_old.elapsed_ns,
        carry_old.checksum,
        iterations,
        input.len,
    });
    try stdout.print("mask_carry,{d},{x},{d},{d}\n", .{
        carry_new.elapsed_ns,
        carry_new.checksum,
        iterations,
        input.len,
    });
    try stdout.flush();
}
