//! SIMD primitives, mask run arithmetic and UTF-8 classification.
//!
//! `Vec` and `Mask` name the lane widths the matchers work at, `windows` cuts
//! a borrowed slice into chunks of that width, `prefixXor`,
//! `computeBackslashRuns` and `trailingRunOdd` answer run-parity questions over
//! one `Mask`, and `validateUtf8` classifies one borrowed byte range. Reached
//! as `simd` from the package root, or by relative import from inside this
//! project.
//!
//! The module allocates nothing, retains nothing and performs no I/O, so a
//! consumer releases nothing after use and every slice it returns borrows the
//! storage the caller passed in. Grammar, tape building and structural
//! indexing live in `stage1`, `stage2` and `json_value` instead.
//!
//! Lane widths and target selection are resolved at comptime from
//! `builtin.cpu` and the `vector_len` build option, so a width is fixed for
//! the whole build rather than chosen per call, and a mask produced at one
//! width is a different type from the same mask at another.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const testing = std.testing;

/// Lanes per vector on the compile target, chosen from its CPU features.
///
/// 64 with both `avx512f` and `avx512bw`, 32 with `avx2`, otherwise 16 on
/// x86, and 16 on every other architecture. This is a decision made while
/// compiling, not a probe of the machine at run time.
pub const native_vector_len: usize = switch (builtin.cpu.arch) {
    .x86, .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) and
        std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw))
        64
    else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
        32
    else
        16,
    else => 16,
};

/// The lane width used when a caller does not name one.
///
/// The `vector_len` build option when the package was compiled with one,
/// otherwise `native_vector_len`.
pub const default_vector_len: usize = build_options.vector_len orelse native_vector_len;

/// A vector of `len` lanes of `T`.
///
/// `len` must be greater than zero, checked at comptime. Every matcher here
/// takes and returns one width, so a vector is only ever exchanged with a
/// vector of the same `T` and `len`. The lanes are plain values: a `Vec` owns
/// nothing, and copying one copies every lane.
pub fn Vec(comptime T: type, comptime len: usize) type {
    comptime assert(len > 0);
    return @Vector(len, T);
}

/// An unsigned mask with exactly `bit_count` lanes.
///
/// `bit_count` must be greater than zero, checked at comptime; lane `i` is bit
/// `i`, counted from the least significant. Every value in
/// `0..maxInt(Mask(bit_count))` is a valid mask, and only those lanes exist
/// logically whatever width the object occupies in memory. `MaskStorage`
/// names that occupied width and `exactMask` converts a mask to it.
pub fn Mask(comptime bit_count: usize) type {
    comptime assert(bit_count > 0);
    return @Int(.unsigned, bit_count);
}

fn validateMaskType(comptime T: type) void {
    const int_info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError("mask type must be an unsigned integer"),
    };
    if (int_info.signedness != .unsigned) {
        @compileError("mask type must be an unsigned integer");
    }
    if (int_info.bits == 0) {
        @compileError("mask type must contain at least one bit");
    }
}

/// Hands out one `len`-wide `Vec` per call over a borrowed slice, optionally
/// padding the final short chunk.
///
/// `T` and `len` are fixed at comptime and `len` must be greater than zero.
/// `pad` decides whether a trailing partial chunk is produced, and the two
/// answers are separate instantiations rather than a run-time branch. The
/// iterator copies no elements: `rest` borrows the `data` given to `init`,
/// which must stay alive and unmodified until the iterator reports
/// exhaustion. The value itself needs no stable address, and copying one
/// borrows the same input and continues from the same position.
pub fn ChunkIterator(comptime T: type, comptime len: usize, comptime pad: bool) type {
    comptime assert(len > 0);
    return struct {
        const Self = @This();

        /// Value written into the padded tail lanes. `null` only when `pad` is
        /// `false`, where no lane is ever padded.
        fill: ?T,
        /// The unconsumed tail of the borrowed input. `next` advances it and
        /// empties it after the final chunk; it never regrows.
        rest: []const T,

        /// Borrows all of `data` as the remaining input.
        ///
        /// `fill` must be non-`null` when `pad` is `true`. That is a caller
        /// precondition held by `std.debug.assert`, so Debug and ReleaseSafe
        /// diagnose it and ReleaseFast and ReleaseSmall treat a violation as
        /// unchecked illegal behavior.
        pub fn init(data: []const T, fill: ?T) Self {
            if (pad) {
                assert(fill != null);
            }
            return .{
                .fill = fill,
                .rest = data,
            };
        }

        /// The next `len` elements, or `null` once the input is spent.
        ///
        /// Fewer than `len` remaining elements return `null`, except under
        /// `pad`, where one final chunk is returned with the tail lanes set
        /// from `init`'s `fill`; an input whose length is an exact multiple of
        /// `len`, including an empty one, produces no padding chunk at all.
        /// The returned vector holds the elements by value and does not borrow
        /// the iterator.
        pub fn next(self: *Self) ?Vec(T, len) {
            if (self.rest.len < len) {
                if (self.rest.len == 0 or !pad) return null;
                var values: [len]T = @splat(self.fill.?);
                for (self.rest, 0..) |elem, idx| {
                    values[idx] = elem;
                }
                self.rest = &.{};
                return values;
            }
            const v: Vec(T, len) = self.rest[0..len].*;
            self.rest = self.rest[len..];
            return v;
        }
    };
}

/// `ChunkIterator(T, len, fill != null)` over `data`, padded when `fill` is given.
///
/// The returned iterator borrows `data` on the terms `ChunkIterator.init`
/// states. Whether the padding exists is decided here, at comptime, so an
/// unpadded caller never pays for the padded path.
pub fn windows(
    comptime T: type,
    comptime len: usize,
    comptime fill: ?T,
    data: []const T,
) ChunkIterator(T, len, fill != null) {
    return ChunkIterator(T, len, fill != null).init(data, fill);
}

const PrefixXorPclmul = struct {
    fn multiply(_bitmask: u64) u64 {
        const product = asm (
            \\ vpclmulqdq $0x00, %[bitmask], %[ones], %[out]
            : [out] "=x" (-> @Vector(2, u64)),
            : [bitmask] "x" (@as(@Vector(2, u64), @bitCast(@as(u128, _bitmask)))),
              [ones] "x" (@as(@Vector(2, u64), @bitCast(@as(u128, std.math.maxInt(u64))))),
        );
        return @truncate(@as(u128, @bitCast(product)));
    }
};

/// Inclusive prefix XOR: bit `i` of the result is the XOR of bits `0..i`.
///
/// `T` must be an integer type with at least one bit. Widths up to 64 use
/// `PrefixXorPclmul.multiply` on `x86_64` with `avx` and `pclmul`, except with the
/// `.stage2_c` backend. Every other instantiation uses the portable shift chain.
/// Both paths compute the same logical value; this states no instruction count
/// or performance result. Widths above 64 are supported by the portable path.
pub fn prefixXor(comptime T: type, bitmask: T) T {
    const bits = @typeInfo(T).int.bits;
    comptime assert(bits > 0);
    if (comptime bits <= 64 and
        builtin.cpu.arch == .x86_64 and
        builtin.zig_backend != .stage2_c and
        builtin.cpu.has(.x86, .avx) and
        builtin.cpu.has(.x86, .pclmul))
    {
        const unsigned = @Int(.unsigned, bits);
        const widened: unsigned = @bitCast(bitmask);
        const extended: u64 = widened;
        const prefix = PrefixXorPclmul.multiply(extended);
        return @bitCast(@as(unsigned, @truncate(prefix)));
    }
    var x = bitmask;
    const steps = @typeInfo(std.math.Log2Int(T)).int.bits;
    inline for (0..steps) |step| {
        x ^= x << comptime (1 << step);
    }
    return x;
}

/// The two run facts `computeBackslashRuns` derives from one backslash mask.
///
/// `T` must be an unsigned integer type with at least one bit; a type that is
/// not one fails at comptime. The value holds plain integers: it owns
/// nothing, borrows nothing, and a copy is independent of the original.
pub fn BackslashResult(comptime T: type) type {
    comptime validateMaskType(T);
    return struct {
        /// Lanes that immediately follow a backslash run of odd length, so the
        /// byte at such a lane is escaped by an odd run before it.
        odd_length_ends: T,
        /// Whether the highest lane is a backslash, meaning a run is still open
        /// at the end of the mask and continues into the next one.
        ends_in_backslash: bool,
    };
}

/// Finds the lanes an odd-length backslash run escapes, within `backslash_mask`.
///
/// `T` must be an unsigned integer type with at least one bit. The run
/// arithmetic uses `T`'s logical width, so a mask whose object is stored wider
/// than its logical width is unaffected by the spare bits.
///
/// `prev_ends_in_backslash` continues the run left open by the previous mask
/// and must be that mask's own `ends_in_backslash`; any other value splits a
/// run in two and changes both answers. A clear mask with a carried-in run
/// still marks lane 0, because that lane follows the run. Nothing is retained
/// and no allocation happens.
pub fn computeBackslashRuns(
    comptime T: type,
    backslash_mask: T,
    prev_ends_in_backslash: bool,
) BackslashResult(T) {
    comptime validateMaskType(T);

    // The run arithmetic stays at the logical width, where the carry out of a
    // run and the alternating complement name the lanes they describe. The
    // three lane tests are reads, so they run on the storage-width value.
    const b = backslash_mask;
    const exact = exactMask(T, b);
    const one: T = 1;
    if (exact == 0) {
        return .{
            .odd_length_ends = if (prev_ends_in_backslash) one else 0,
            .ends_in_backslash = false,
        };
    }

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    // maxInt(T) / 3 starts on the wrong lane for odd-width masks.
    var even_bits: T = 0;
    inline for (0..bit_count) |bit_index| {
        if (bit_index % 2 == 0) {
            even_bits |= one << @as(Shift, @intCast(bit_index));
        }
    }
    const odd_bits: T = ~even_bits;
    const prev_start: T = @intFromBool(prev_ends_in_backslash);
    const starts = (b & ~((b << 1) | prev_start)) |
        (if (prev_ends_in_backslash and (exact & 1) != 0) one else 0);

    const even_starts = starts & even_bits;
    const odd_starts = starts & odd_bits;

    const even_carries = (b +% even_starts) & ~b;
    const odd_carries = (b +% odd_starts) & ~b;

    const odd_length_ends =
        (even_carries & odd_bits) | (odd_carries & even_bits);
    const top_bit: @TypeOf(exact) = @intCast(one << (@typeInfo(T).int.bits - 1));

    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = (exact & top_bit) != 0,
    };
}

/// The unsigned integer type that occupies the storage of `Mask(bits)`.
///
/// `bits` must be greater than zero, checked at comptime. The returned type is
/// `Mask(bits)` itself when the object occupies exactly its logical width, and
/// otherwise an unsigned integer of `@sizeOf(Mask(bits)) * 8` bits. The width
/// a given `bits` maps to is decided by the target, so derive it from
/// `@sizeOf` rather than from a fixed power-of-two rule.
pub fn MaskStorage(comptime bits: usize) type {
    comptime assert(bits > 0);
    const result = Mask(bits);
    if (@bitSizeOf(result) == @sizeOf(result) * 8) return result;
    return @Int(.unsigned, @sizeOf(result) * 8);
}

/// Converts `mask` to its storage width with the logical lanes explicitly
/// bounded.
///
/// `T` must be an unsigned integer type with at least one bit. Bits at and
/// above `T`'s logical width are cleared, so a storage-width scan never reads a
/// spare bit as a lane. A `T` that already occupies its full storage width is
/// returned unchanged. The result is a value: nothing is borrowed or retained.
pub fn exactMask(comptime T: type, mask: T) MaskStorage(@typeInfo(T).int.bits) {
    comptime validateMaskType(T);

    const storage = MaskStorage(@typeInfo(T).int.bits);
    if (storage == T) return mask;

    const logical_bits: storage = @intCast(std.math.maxInt(T));
    return @as(storage, @intCast(mask)) & logical_bits;
}

// Explicit lane-to-bit masks for big-endian and sub-16-byte Hexagon vectors.
// Widen each 0/1 result before shifting it into bit `lane`. Opaque scalar
// predicates avoid the observed aarch64_be ReleaseSafe weighted-loop
// divergence. The noinline walks take vectors directly: converting a width-64
// vector to an array in a large inlined caller also corrupted lanes there.
// Resolve target selection at comptime: no runtime Arch.endian call, and
// other targets do not instantiate these walks.
// Keep public matchers inline: out-of-line LoongArch Debug calls corrupt
// width-256/512 mask results, while direct comparisons and bitcasts agree.

// Both halves of the lane-walk selection are compilation-unit invariants.
// Resolve each one once instead of re-reading `builtin.cpu.arch` inside every
// matcher: callers instantiate one width at a time, and each repeat of that
// `Arch.endian()` switch spent backwards branches of the calling function's
// shared comptime budget.
const target_is_big_endian: bool = builtin.cpu.arch.endian() == .big;
const target_is_hexagon: bool = builtin.cpu.arch == .hexagon;

noinline fn laneMatchByte(comptime len: usize, v: Vec(u8, len), target: u8) Mask(len) {
    const storage = MaskStorage(len);
    var result: storage = 0;
    inline for (0..len) |lane| {
        result |= @as(storage, @intFromBool(v[lane] == target)) << lane;
    }
    return @truncate(result);
}

noinline fn laneByteMatches2(byte: u8, c1: u8, c2: u8) u8 {
    return @intCast(@intFromBool(byte == c1) | @intFromBool(byte == c2));
}

noinline fn laneByteMatches4(byte: u8, c1: u8, c2: u8, c3: u8, c4: u8) u8 {
    return @intCast(
        @intFromBool(byte == c1) | @intFromBool(byte == c2) |
            @intFromBool(byte == c3) | @intFromBool(byte == c4),
    );
}

noinline fn laneMatchAny2(
    comptime len: usize,
    v: Vec(u8, len),
    c1: u8,
    c2: u8,
) Mask(len) {
    const storage = MaskStorage(len);
    var result: storage = 0;
    inline for (0..len) |lane| {
        const matches = laneByteMatches2(v[lane], c1, c2);
        result |= @as(storage, matches) << lane;
    }
    return @truncate(result);
}

noinline fn laneMatchAny4(
    comptime len: usize,
    v: Vec(u8, len),
    c1: u8,
    c2: u8,
    c3: u8,
    c4: u8,
) Mask(len) {
    const storage = MaskStorage(len);
    var result: storage = 0;
    inline for (0..len) |lane| {
        const matches = laneByteMatches4(v[lane], c1, c2, c3, c4);
        result |= @as(storage, matches) << lane;
    }
    return @truncate(result);
}

noinline fn laneMatchRange(
    comptime len: usize,
    v: Vec(u8, len),
    min: u8,
    max: u8,
) Mask(len) {
    const storage = MaskStorage(len);
    var result: storage = 0;
    inline for (0..len) |lane| {
        const matches = @intFromBool(v[lane] >= min) & @intFromBool(v[lane] <= max);
        result |= @as(storage, matches) << lane;
    }
    return @truncate(result);
}

/// Lanes equal to `target`: lane `i` is set when `v[i] == target`.
///
/// `len` must be greater than zero. This entry point must stay `inline`; the
/// out-of-line instantiation corrupts wide mask results on LoongArch, while the
/// inlined comparison agrees with it. Big-endian targets and vectors narrower
/// than 16 bytes on Hexagon take a lane-by-lane walk that yields the same mask.
pub inline fn matchByte(comptime len: usize, v: Vec(u8, len), target: u8) Mask(len) {
    if (comptime target_is_big_endian or (target_is_hexagon and len < 16)) {
        return laneMatchByte(len, v, target);
    }

    const byte_vector = Vec(u8, len);
    const eq: Vec(bool, len) = v == @as(byte_vector, @splat(target));
    return @bitCast(eq);
}

/// Lanes equal to either `c1` or `c2`. Same inline contract as `matchByte`.
pub inline fn matchAny2(comptime len: usize, v: Vec(u8, len), c1: u8, c2: u8) Mask(len) {
    if (comptime target_is_big_endian or (target_is_hexagon and len < 16)) {
        return laneMatchAny2(len, v, c1, c2);
    }

    const byte_vector = Vec(u8, len);
    const combined: Vec(bool, len) = (v == @as(byte_vector, @splat(c1))) |
        (v == @as(byte_vector, @splat(c2)));
    return @bitCast(combined);
}

/// Lanes equal to one of `c1`, `c2`, `c3` or `c4`. Same inline contract as `matchByte`.
pub inline fn matchAny4(comptime len: usize, v: Vec(u8, len), c1: u8, c2: u8, c3: u8, c4: u8) Mask(len) {
    if (comptime target_is_big_endian or (target_is_hexagon and len < 16)) {
        return laneMatchAny4(len, v, c1, c2, c3, c4);
    }

    const byte_vector = Vec(u8, len);
    const combined: Vec(bool, len) = (v == @as(byte_vector, @splat(c1))) |
        (v == @as(byte_vector, @splat(c2))) |
        (v == @as(byte_vector, @splat(c3))) |
        (v == @as(byte_vector, @splat(c4)));
    return @bitCast(combined);
}

/// Lanes in `min..=max`, inclusive at both ends. Same inline contract as `matchByte`.
pub inline fn matchRange(comptime len: usize, v: Vec(u8, len), min: u8, max: u8) Mask(len) {
    if (comptime target_is_big_endian or (target_is_hexagon and len < 16)) {
        return laneMatchRange(len, v, min, max);
    }

    const byte_vector = Vec(u8, len);
    const in_range: Vec(bool, len) = (v >= @as(byte_vector, @splat(min))) &
        (v <= @as(byte_vector, @splat(max)));
    return @bitCast(in_range);
}

/// The low `valid_count` lanes set, for a `Mask(bits)` of `bits` lanes.
///
/// `bits` must be greater than zero, checked at comptime. A `valid_count` of
/// `0` yields `0` and one of `bits` yields every lane set. A `valid_count`
/// above `bits` is a caller precondition held by `std.debug.assert`, so Debug
/// and ReleaseSafe diagnose it and ReleaseFast and ReleaseSmall treat it as
/// unchecked illegal behavior. Bits at and above `valid_count` are clear,
/// whatever width the mask occupies in storage.
pub fn validMask(comptime bits: usize, valid_count: usize) Mask(bits) {
    comptime assert(bits > 0);
    assert(valid_count <= bits);

    const result = Mask(bits);
    if (valid_count == bits) return std.math.maxInt(result);
    if (valid_count == 0) return 0;

    const shift = std.math.Log2Int(result);
    return (@as(result, 1) << @as(shift, @intCast(valid_count))) - 1;
}

/// Lanes holding JSON whitespace: `' '`, `'\t'`, `'\n'` or `'\r'`.
///
/// No other byte matches, including the `0x0b` and `0x0c` a JSON5 grammar also
/// accepts as whitespace; a JSON5 scanner matches those on its own. This
/// entry point must stay `inline` on the terms `matchByte` states.
pub inline fn matchJsonWhitespace(comptime len: usize, v: Vec(u8, len)) Mask(len) {
    comptime assert(len > 0);
    if (comptime target_is_big_endian or (target_is_hexagon and len < 16)) {
        return matchAny4(len, v, ' ', '\t', '\n', '\r');
    }

    const byte_vector = Vec(u8, len);
    const tab: byte_vector = @splat(0x09);
    const distance_from_tab = v -% tab;
    const folded_distance = distance_from_tab |
        ((distance_from_tab & @as(byte_vector, @splat(0x02))) <<
            @as(byte_vector, @splat(1)));
    const control_whitespace = folded_distance <= @as(byte_vector, @splat(0x04));
    const whitespace = control_whitespace | (v == @as(byte_vector, @splat(0x20)));
    return @bitCast(whitespace);
}

/// Whether the run of lanes clear in `mask`, ending at its last valid lane,
/// has odd length.
///
/// `bits` must be greater than zero, checked at comptime. Only the first
/// `valid_count` lanes take part, and a `valid_count` of `0` returns `false`.
/// A `valid_count` above `bits` is a caller precondition held by
/// `std.debug.assert`, so Debug and ReleaseSafe diagnose it and the fast
/// release modes treat it as unchecked illegal behavior.
///
/// `previous_odd` continues the same run across a block boundary and must be
/// the previous block's own answer; any other value changes the parity. When
/// every valid lane has its bit set, this block adds no clear lane, so the run
/// keeps the length it had before this block. The answer is then the carried-in
/// parity combined with the parity of `valid_count`.
pub fn trailingRunOdd(
    comptime bits: usize,
    mask: Mask(bits),
    valid_count: usize,
    previous_odd: bool,
) bool {
    comptime assert(bits > 0);
    assert(valid_count <= bits);
    if (valid_count == 0) return false;

    // Complement at the storage width, then restrict the result to valid
    // logical lanes before scanning it.
    const exact = exactMask(Mask(bits), mask);
    const valid_exact = exactMask(Mask(bits), validMask(bits, valid_count));
    const non_matching = ~exact & valid_exact;
    if (non_matching == 0) {
        return (valid_count % 2 == 0) == previous_odd;
    }

    // Align the top valid lane with the top storage bit, so the leading-zero
    // count names the trailing non-matching run at the width it is read from.
    // A logical-width alignment read through a widened `@clz` would add the
    // spare bits to the count and flip the parity at every odd spare width.
    const storage = MaskStorage(bits);
    const shift = std.math.Log2Int(storage);
    const alignment: shift = @intCast(@bitSizeOf(storage) - valid_count);
    const trailing_count: usize = @intCast(@clz(non_matching << alignment));
    return trailing_count % 2 != 0;
}

/// Writes `base_offset` plus the lane index of every set lane of `bitmask`
/// into `out_indexes`.
///
/// `T` must be an unsigned integer type with at least one bit. Lanes are
/// written from the lowest upward, at most `out_indexes.len` of them, and the
/// returned count is how many were stored; `out_indexes[written..]` keeps
/// whatever the caller left there. A mask with more set lanes than room is
/// truncated silently, so a caller that must see every lane sizes the output
/// from `@popCount` or calls `extractBitIndexesChecked`. Each written value
/// must fit in `u32`, and this call does not check that.
pub fn extractBitIndexes(
    comptime T: type,
    bitmask: T,
    base_offset: usize,
    out_indexes: []u32,
) usize {
    comptime validateMaskType(T);

    // Use one explicitly bounded storage-width representation for every scan.
    var mask = exactMask(T, bitmask);
    var written: usize = 0;
    inline for (0..8) |_| {
        if (mask != 0 and written < out_indexes.len) {
            const bit_pos: usize = @ctz(mask);
            out_indexes[written] = @intCast(base_offset + bit_pos);
            written += 1;
            mask &= mask - 1;
        }
    }
    while (mask != 0 and written < out_indexes.len) {
        const bit_pos: usize = @ctz(mask);
        out_indexes[written] = @intCast(base_offset + bit_pos);
        written += 1;
        mask &= mask - 1;
    }
    return written;
}

/// `extractBitIndexes` that reports a mask that will not fit instead of
/// truncating it.
///
/// `error.CapacityExceeded` when `out_indexes` is shorter than the number of
/// set lanes, and `error.InputTooLarge` when `base_offset` plus the highest
/// set lane does not fit in `u32`. Both are decided before any lane is
/// written, so `out_indexes` is unchanged on either path. On success every
/// set lane is written from the lowest upward and the returned count equals
/// the number of set lanes.
pub fn extractBitIndexesChecked(
    comptime T: type,
    bitmask: T,
    base_offset: usize,
    out_indexes: []u32,
) error{ CapacityExceeded, InputTooLarge }!usize {
    comptime validateMaskType(T);

    // Count and scan the same normalized storage-width value.
    const exact = exactMask(T, bitmask);
    const required_count: usize = @intCast(@popCount(exact));
    if (out_indexes.len < required_count) return error.CapacityExceeded;
    if (required_count == 0) return 0;

    // `exact` is zero-extended into its storage width, so counting from the
    // storage width and counting from the logical width name the same bit.
    const storage_bits: usize = @bitSizeOf(@TypeOf(exact));
    const leading_zero_count: usize = @intCast(@clz(exact));
    const highest_bit: usize = storage_bits - leading_zero_count - 1;
    const highest_offset = std.math.add(usize, base_offset, highest_bit) catch {
        return error.InputTooLarge;
    };
    if (highest_offset > std.math.maxInt(u32)) return error.InputTooLarge;

    var mask = exact;
    var written: usize = 0;
    while (mask != 0) {
        const bit_pos: usize = @intCast(@ctz(mask));
        out_indexes[written] = @intCast(base_offset + bit_pos);
        written += 1;
        mask &= mask - 1;
    }
    return written;
}

/// The UTF-8 rules `validateUtf8` distinguishes.
///
/// One class per rule, so a caller can tell a malformed sequence from one that
/// is merely cut short at the end of the range it was given.
pub const Utf8ErrorKind = enum(u8) {
    /// A byte in `0xf8..0xff`, which is not a UTF-8 lead byte at all.
    invalid_header,
    /// A `0x80..0xbf` byte that no sequence consumed.
    unexpected_continuation,
    /// The byte at which a continuation byte was required and something else
    /// was found.
    missing_continuation,
    /// The range ended inside a sequence; `Utf8Error.offset` is the lead byte.
    truncated_sequence,
    /// A sequence encoding a value below the shortest form for its length.
    overlong,
    /// `0xed` followed by `0xa0..0xbf`, encoding a UTF-16 surrogate half.
    surrogate,
    /// A sequence above `U+10FFFF`: a `0xf5..0xf7` lead byte, or `0xf4`
    /// followed by a byte above `0x8f`.
    too_large,
};

/// Why `validateUtf8` rejected a byte range, and where.
///
/// `offset` is a byte index into the slice that was validated. It names the
/// offending byte for every class except `.truncated_sequence`, which names
/// the lead byte of the sequence the range ended inside.
pub const Utf8Error = struct {
    /// Which rule the input broke.
    kind: Utf8ErrorKind,
    /// Byte index into the validated slice, as this comment describes.
    offset: usize,
};

/// Whether a byte range is valid UTF-8, and the first failure when it is not.
///
/// This is a returned value rather than an error union: an invalid range is
/// an ordinary answer a caller inspects rather than an exceptional path, and
/// neither answer allocates or retains anything.
pub const Utf8Result = union(enum) {
    /// Every byte in the range is well-formed UTF-8.
    valid,
    /// The first failure, scanning upward from the lowest byte offset.
    invalid: Utf8Error,
};

const Utf8BlockState = struct {
    continuation_count: u2 = 0,
    constrained_header: u8 = 0,
};

fn utf8Invalid(kind: Utf8ErrorKind, offset: usize) Utf8Result {
    return .{ .invalid = .{
        .kind = kind,
        .offset = offset,
    } };
}

fn utf8Continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

fn validateUtf8Scalar(input: []const u8) Utf8Result {
    var offset: usize = 0;
    while (offset < input.len) {
        const header = input[offset];
        if (header <= 0x7f) {
            offset += 1;
            continue;
        }
        if (header <= 0xbf) {
            return utf8Invalid(.unexpected_continuation, offset);
        }
        if (header <= 0xc1) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 1])) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            return utf8Invalid(.overlong, offset);
        }
        if (header <= 0xdf) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 1])) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            offset += 2;
            continue;
        }
        if (header <= 0xef) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            const continuation_1 = input[offset + 1];
            if (!utf8Continuation(continuation_1)) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            if (header == 0xe0 and continuation_1 < 0xa0) {
                return utf8Invalid(.overlong, offset + 1);
            }
            if (header == 0xed and continuation_1 >= 0xa0) {
                return utf8Invalid(.surrogate, offset + 1);
            }
            if (offset + 2 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 2])) {
                return utf8Invalid(.missing_continuation, offset + 2);
            }
            offset += 3;
            continue;
        }
        if (header <= 0xf4) {
            if (offset + 1 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            const continuation_1 = input[offset + 1];
            if (!utf8Continuation(continuation_1)) {
                return utf8Invalid(.missing_continuation, offset + 1);
            }
            if (header == 0xf0 and continuation_1 < 0x90) {
                return utf8Invalid(.overlong, offset + 1);
            }
            if (header == 0xf4 and continuation_1 > 0x8f) {
                return utf8Invalid(.too_large, offset + 1);
            }
            if (offset + 2 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 2])) {
                return utf8Invalid(.missing_continuation, offset + 2);
            }
            if (offset + 3 >= input.len) {
                return utf8Invalid(.truncated_sequence, offset);
            }
            if (!utf8Continuation(input[offset + 3])) {
                return utf8Invalid(.missing_continuation, offset + 3);
            }
            offset += 4;
            continue;
        }
        if (header <= 0xf7) {
            return utf8Invalid(.too_large, offset);
        }
        return utf8Invalid(.invalid_header, offset);
    }
    return .valid;
}

fn utf8ContinuationMask(comptime len: usize, count: u2) Mask(len) {
    return switch (count) {
        0 => 0,
        1 => 0b001,
        2 => 0b011,
        3 => 0b111,
    };
}

fn utf8ConstrainedContinuationValid(header: u8, continuation: u8) bool {
    return switch (header) {
        0xe0 => continuation >= 0xa0 and continuation <= 0xbf,
        0xed => continuation >= 0x80 and continuation <= 0x9f,
        0xf0 => continuation >= 0x90 and continuation <= 0xbf,
        0xf4 => continuation >= 0x80 and continuation <= 0x8f,
        else => true,
    };
}

fn utf8BlockIsValid(
    comptime len: usize,
    bytes: Vec(u8, len),
    state: *Utf8BlockState,
) bool {
    const ascii = matchRange(len, bytes, 0x00, 0x7f);
    const continuation = matchRange(len, bytes, 0x80, 0xbf);
    const lead_2 = matchRange(len, bytes, 0xc2, 0xdf);
    const lead_3 = matchRange(len, bytes, 0xe0, 0xef);
    const lead_4 = matchRange(len, bytes, 0xf0, 0xf4);
    const valid_byte = ascii | continuation | lead_2 | lead_3 | lead_4;
    // Complement only the logical lanes, then use the normalized representation.
    if (exactMask(Mask(len), ~valid_byte) != 0) return false;

    const expected_continuation =
        ((lead_2 | lead_3 | lead_4) << 1) |
        ((lead_3 | lead_4) << 2) |
        (lead_4 << 3) |
        utf8ContinuationMask(len, state.continuation_count);
    // Compare both masks in the same explicit storage-width representation.
    if (exactMask(Mask(len), continuation) !=
        exactMask(Mask(len), expected_continuation))
    {
        return false;
    }
    if (state.constrained_header != 0 and
        !utf8ConstrainedContinuationValid(state.constrained_header, bytes[0]))
    {
        return false;
    }

    const bad_e0 = (matchByte(len, bytes, 0xe0) << 1) &
        matchRange(len, bytes, 0x80, 0x9f);
    const bad_ed = (matchByte(len, bytes, 0xed) << 1) &
        matchRange(len, bytes, 0xa0, 0xbf);
    const bad_f0 = (matchByte(len, bytes, 0xf0) << 1) &
        matchRange(len, bytes, 0x80, 0x8f);
    const bad_f4 = (matchByte(len, bytes, 0xf4) << 1) &
        matchRange(len, bytes, 0x90, 0xbf);
    if (exactMask(Mask(len), bad_e0 | bad_ed | bad_f0 | bad_f4) != 0) return false;

    const bytes_array: [len]u8 = @bitCast(bytes);
    var trailing_index: usize = len;
    var trailing_count: u2 = 0;
    var trailing_header: u8 = 0;
    while (trailing_index > 0) {
        trailing_index -= 1;
        const byte = bytes_array[trailing_index];
        const required_count: usize = if (byte >= 0xf0 and byte <= 0xf4)
            3
        else if (byte >= 0xe0 and byte <= 0xef)
            2
        else if (byte >= 0xc2 and byte <= 0xdf)
            1
        else
            0;
        if (required_count == 0) {
            if (!utf8Continuation(byte)) break;
            continue;
        }
        const bytes_after = len - trailing_index - 1;
        if (bytes_after < required_count) {
            trailing_count = @intCast(required_count - bytes_after);
            if (bytes_after == 0) trailing_header = byte;
        }
        break;
    }
    state.continuation_count = trailing_count;
    state.constrained_header = trailing_header;
    return true;
}

// Full blocks use vector masks; a non-ASCII tail is replayed by the scalar
// classifier so short input is never over-read.

fn utf8SuspectOffset(comptime len: usize, input: []const u8) ?usize {
    comptime {
        if (len < 4) {
            @compileError(
                "UTF-8 SIMD vector width must be at least 4 bytes for four-byte UTF-8 " ++
                    "and mask-shift algorithms",
            );
        }
    }
    var state: Utf8BlockState = .{};
    var offset: usize = 0;
    while (input.len - offset >= len) : (offset += len) {
        const bytes: Vec(u8, len) = input[offset..][0..len].*;
        if (!utf8BlockIsValid(len, bytes, &state)) return offset;
    }

    if (state.continuation_count != 0) return offset;
    for (input[offset..], 0..) |byte, tail_offset| {
        if (byte >= 0x80) return offset + tail_offset;
    }
    return null;
}

fn utf8ReplayStart(input: []const u8, suspect_offset: usize) usize {
    var replay_start = @min(suspect_offset, input.len);
    if (replay_start == input.len) {
        return replay_start - @min(@as(usize, 3), replay_start);
    }
    while (replay_start > 0 and utf8Continuation(input[replay_start - 1])) {
        replay_start -= 1;
    }
    if (replay_start > 0) {
        const preceding = input[replay_start - 1];
        if (preceding >= 0xc2 and preceding <= 0xf4) {
            replay_start -= 1;
        }
    }
    return replay_start;
}

fn validateUtf8Replay(input: []const u8, suspect_offset: usize) Utf8Result {
    const replay_start = utf8ReplayStart(input, suspect_offset);
    return switch (validateUtf8Scalar(input[replay_start..])) {
        .valid => .valid,
        .invalid => |error_info| .{ .invalid = .{
            .kind = error_info.kind,
            .offset = replay_start + error_info.offset,
        } },
    };
}

/// UTF-8 classification of `input` at one vector width.
///
/// `len` is the block width the scan uses. A width below 4 takes the scalar
/// classifier directly; from 4 upward a vector pass locates a suspect block
/// and a scalar replay reclassifies it, so `Utf8Error.kind` and
/// `Utf8Error.offset` name the same first failure at every width. A short
/// input is never read past its end. Nothing is retained and no allocation
/// happens.
pub fn validateUtf8WithWidth(comptime len: usize, input: []const u8) Utf8Result {
    if (comptime len < 4) return validateUtf8Scalar(input);

    // SIMD identifies a suspect block; scalar replay establishes the first
    // failure class and offset without exposing internal mask bits.
    const suspect_offset = utf8SuspectOffset(len, input) orelse return .valid;
    return validateUtf8Replay(input, suspect_offset);
}

/// UTF-8 classification of `input` at `default_vector_len`.
///
/// The whole contract is `validateUtf8WithWidth`'s; this entry point only fixes
/// the width to the one this package's own scanners use.
pub fn validateUtf8(input: []const u8) Utf8Result {
    return validateUtf8WithWidth(default_vector_len, input);
}

fn expectUtf8Result(
    input: []const u8,
    expected: Utf8Result,
) !void {
    inline for ([_]usize{ 16, 32, 64 }) |width| {
        try testing.expectEqual(expected, validateUtf8WithWidth(width, input));
    }
    try testing.expectEqual(expected, validateUtf8(input));
}

fn expectUtf8ValidSequenceAtBoundary(
    comptime width: usize,
    sequence: []const u8,
    start: usize,
) !void {
    var input: [68]u8 = @splat('a');
    @memcpy(input[start..][0..sequence.len], sequence);
    const expected: Utf8Result = .valid;
    try testing.expectEqual(
        expected,
        validateUtf8WithWidth(width, input[0 .. start + sequence.len]),
    );
}

fn expectUtf8ValidSequenceInsideBlock(
    comptime width: usize,
    sequence: []const u8,
) !void {
    var input: [width + 1]u8 = @splat('a');
    @memcpy(input[1..][0..sequence.len], sequence);
    const expected: Utf8Result = .valid;
    try testing.expectEqual(expected, validateUtf8WithWidth(width, &input));
}

fn expectUtf8InvalidSequenceAtBoundary(
    comptime width: usize,
    sequence: []const u8,
    start: usize,
    kind: Utf8ErrorKind,
    error_relative_offset: usize,
) !void {
    var input: [68]u8 = @splat('a');
    @memcpy(input[start..][0..sequence.len], sequence);
    const expected: Utf8Result = .{ .invalid = .{
        .kind = kind,
        .offset = start + error_relative_offset,
    } };
    try testing.expectEqual(
        expected,
        validateUtf8WithWidth(width, input[0 .. start + sequence.len]),
    );
}

test "UTF-8 widths below four match scalar validation" {
    const cases = [_][]const u8{
        "ASCII only",
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
        &[_]u8{ 'x', 0x80 },
        &[_]u8{ 'x', 0xf0, 0x90, 0x8d },
    };

    for (cases) |input| {
        const expected = validateUtf8Scalar(input);
        inline for ([_]usize{ 1, 2, 3 }) |width| {
            try testing.expectEqual(expected, validateUtf8WithWidth(width, input));
        }
    }
}

test "UTF-8 accepts ASCII and valid sequences at every SIMD width" {
    const sequences = [_][]const u8{
        &[_]u8{ 0xc2, 0xa2 },
        &[_]u8{ 0xe0, 0xa0, 0x80 },
        &[_]u8{ 0xed, 0x9f, 0xbf },
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
        &[_]u8{ 0xf4, 0x8f, 0xbf, 0xbf },
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        var ascii: [width * 2 + 3]u8 = @splat('x');
        const expected: Utf8Result = .valid;
        try testing.expectEqual(expected, validateUtf8WithWidth(width, &ascii));

        for (sequences) |sequence| {
            try expectUtf8ValidSequenceInsideBlock(width, sequence);
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + sequence.len <= 68) {
                    try expectUtf8ValidSequenceAtBoundary(width, sequence, start);
                }
            }
        }
    }
}

test "UTF-8 reports exact scalar error classes and offsets" {
    const cases = [_]struct {
        bytes: []const u8,
        kind: Utf8ErrorKind,
        offset: usize,
    }{
        .{ .bytes = &[_]u8{0x80}, .kind = .unexpected_continuation, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xc2, 0x20 }, .kind = .missing_continuation, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xe2, 0x82, 0x20 }, .kind = .missing_continuation, .offset = 2 },
        .{ .bytes = &[_]u8{ 0xf0, 0x90, 0x8d, 0x20 }, .kind = .missing_continuation, .offset = 3 },
        .{ .bytes = &[_]u8{ 0xc0, 0x80 }, .kind = .overlong, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xe0, 0x80, 0x80 }, .kind = .overlong, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf0, 0x80, 0x80, 0x80 }, .kind = .overlong, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xed, 0xa0, 0x80 }, .kind = .surrogate, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf4, 0x90, 0x80, 0x80 }, .kind = .too_large, .offset = 1 },
        .{ .bytes = &[_]u8{ 0xf5, 0x80, 0x80, 0x80 }, .kind = .too_large, .offset = 0 },
        .{ .bytes = &[_]u8{0xff}, .kind = .invalid_header, .offset = 0 },
        .{ .bytes = &[_]u8{0xe2}, .kind = .truncated_sequence, .offset = 0 },
        .{ .bytes = &[_]u8{ 0xf0, 0x90 }, .kind = .truncated_sequence, .offset = 0 },
    };
    for (cases) |case| {
        const expected: Utf8Result = .{ .invalid = .{
            .kind = case.kind,
            .offset = case.offset,
        } };
        try expectUtf8Result(case.bytes, expected);
    }
}

test "UTF-8 reports truncation at block edges and tails" {
    const prefixes = [_][]const u8{
        &[_]u8{0xc2},
        &[_]u8{ 0xe2, 0x82 },
        &[_]u8{ 0xf0, 0x90, 0x8d },
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (prefixes) |prefix| {
            inline for ([_]usize{ width - 1, width, width + 1 }) |start| {
                if (start + prefix.len <= 68) {
                    var input: [68]u8 = @splat('z');
                    @memcpy(input[start..][0..prefix.len], prefix);
                    const expected: Utf8Result = .{ .invalid = .{
                        .kind = .truncated_sequence,
                        .offset = start,
                    } };
                    try testing.expectEqual(
                        expected,
                        validateUtf8WithWidth(width, input[0 .. start + prefix.len]),
                    );
                }
            }
        }
    }
}

test "UTF-8 SIMD widths match the scalar classifier" {
    const corpus = [_][]const u8{
        "",
        "ASCII only",
        &[_]u8{ 0x80, 'x' },
        &[_]u8{ 'x', 0xe0, 0x80, 0x80 },
        &[_]u8{ 'x', 0xed, 0xa0, 0x80 },
        &[_]u8{ 'x', 0xf4, 0x90, 0x80, 0x80 },
        &[_]u8{ 'x', 0xf0, 0x90 },
        &[_]u8{ 'x', 0xff },
    };

    for (corpus) |input| {
        try expectUtf8Result(input, validateUtf8Scalar(input));
    }
}

test "UTF-8 stays exact at padded and over-wide mask storage" {
    // Cover byte-aligned widths with larger storage and widths above a register.
    const emoji = [_]u8{ 0xf0, 0x90, 0x8d, 0x88 };
    inline for ([_]usize{ 24, 48, 65, 100 }) |width| {
        var input: [width * 3 + 8]u8 = undefined;
        inline for ([_]usize{ 1, 2, 3, 4 }) |lanes_in_first_block| {
            const start = width - lanes_in_first_block;
            @memset(input[0..], 'x');
            @memcpy(input[start..][0..emoji.len], &emoji);
            try testing.expectEqual(
                Utf8Result.valid,
                validateUtf8WithWidth(width, &input),
            );

            // Replacing the sequence's last byte with a plain ASCII byte has to
            // surface as the scalar classifier's own failure class and offset.
            var truncated = input;
            truncated[start + emoji.len - 1] = 'x';
            try testing.expectEqual(
                validateUtf8Scalar(&truncated),
                validateUtf8WithWidth(width, &truncated),
            );
        }
    }
}

test "UTF-8 carries valid and invalid sequences across SIMD blocks" {
    const valid_sequences = [_][]const u8{
        &[_]u8{ 0xc2, 0xa2 },
        &[_]u8{ 0xe2, 0x82, 0xac },
        &[_]u8{ 0xf0, 0x90, 0x8d, 0x88 },
    };
    const invalid_sequences = [_]struct {
        bytes: []const u8,
        kind: Utf8ErrorKind,
        error_relative_offset: usize,
    }{
        .{
            .bytes = &[_]u8{0x80},
            .kind = .unexpected_continuation,
            .error_relative_offset = 0,
        },
        .{
            .bytes = &[_]u8{0xff},
            .kind = .invalid_header,
            .error_relative_offset = 0,
        },
        .{
            .bytes = &[_]u8{ 0xc2, 0x20 },
            .kind = .missing_continuation,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xe0, 0x80, 0x80 },
            .kind = .overlong,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xed, 0xa0, 0x80 },
            .kind = .surrogate,
            .error_relative_offset = 1,
        },
        .{
            .bytes = &[_]u8{ 0xf4, 0x90, 0x80, 0x80 },
            .kind = .too_large,
            .error_relative_offset = 1,
        },
    };
    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (valid_sequences) |sequence| {
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + sequence.len <= 68) {
                    try expectUtf8ValidSequenceAtBoundary(width, sequence, start);
                }
            }
        }
        for (invalid_sequences) |case| {
            inline for ([_]usize{ width - 3, width - 2, width - 1, width }) |start| {
                if (start + case.bytes.len <= 68) {
                    try expectUtf8InvalidSequenceAtBoundary(
                        width,
                        case.bytes,
                        start,
                        case.kind,
                        case.error_relative_offset,
                    );
                }
            }
        }
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

fn scalarPrefixXor(comptime T: type, bitmask: T) T {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var parity = false;
    var result: T = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = (bitmask & (one << @as(Shift, @intCast(bit_index)))) != 0;
        parity = parity != bit;
        if (parity) result |= one << @as(Shift, @intCast(bit_index));
    }
    return result;
}

fn prefixXorAlternatingMask(comptime T: type, comptime even_bits_set: bool) T {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var mask: T = 0;
    inline for (0..bit_count) |bit_index| {
        if ((bit_index % 2 == 0) == even_bits_set) {
            mask |= one << @as(Shift, @intCast(bit_index));
        }
    }
    return mask;
}

fn prefixXorQuotePairMask(
    comptime T: type,
    comptime first_bit_index: usize,
    comptime second_bit_index: usize,
) T {
    comptime validateMaskType(T);
    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    comptime assert(first_bit_index < second_bit_index);
    comptime assert(second_bit_index < bit_count);

    const one: T = 1;
    return (one << @as(Shift, @intCast(first_bit_index))) |
        (one << @as(Shift, @intCast(second_bit_index)));
}

fn expectPrefixXorMask(comptime T: type, bitmask: T) !void {
    const expected = scalarPrefixXor(T, bitmask);
    const actual = prefixXor(T, bitmask);
    try testing.expectEqual(expected, actual);
}

fn expectPrefixXorMasks(comptime T: type) !void {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const one: T = 1;
    try expectPrefixXorMask(T, 0);
    try expectPrefixXorMask(T, std.math.maxInt(T));
    try expectPrefixXorMask(T, prefixXorAlternatingMask(T, true));
    try expectPrefixXorMask(T, prefixXorAlternatingMask(T, false));
    const Shift = std.math.Log2Int(T);
    inline for ([_]usize{ 0, bit_count / 2, bit_count - 1 }) |bit_index| {
        try expectPrefixXorMask(T, one << @as(Shift, @intCast(bit_index)));
    }

    if (bit_count > 1) {
        try expectPrefixXorMask(T, prefixXorQuotePairMask(T, 0, 1));
        try expectPrefixXorMask(
            T,
            prefixXorQuotePairMask(T, bit_count - 2, bit_count - 1),
        );
        try expectPrefixXorMask(T, prefixXorQuotePairMask(T, 0, bit_count - 1));
    }

    inline for ([_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 }) |boundary| {
        if (boundary < bit_count) {
            try expectPrefixXorMask(
                T,
                prefixXorQuotePairMask(T, boundary - 1, boundary),
            );
        }
    }
}

test "prefixXor matches scalar prefix parity across arbitrary mask widths" {
    inline for ([_]usize{
        1,  2,  3,  7,   8,   15,  16,  31,  32,
        63, 64, 65, 127, 128, 255, 256, 511, 512,
    }) |bit_count| {
        try expectPrefixXorMasks(Mask(bit_count));
    }
}

fn scalarBackslashRunParity(
    comptime T: type,
    backslash_mask: T,
    prev_ends_in_backslash: bool,
) BackslashResult(T) {
    comptime validateMaskType(T);

    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var odd_length_ends: T =
        if (prev_ends_in_backslash and exactMask(T, backslash_mask) == 0) one else 0;
    var run_length: usize = 0;
    var bit_index: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = (backslash_mask & (one << @as(Shift, @intCast(bit_index)))) != 0;
        if (bit) {
            run_length += 1;
            continue;
        }
        if (run_length != 0) {
            if (run_length % 2 != 0) {
                odd_length_ends |= one << @as(Shift, @intCast(bit_index));
            }
            run_length = 0;
        }
    }

    return .{
        .odd_length_ends = odd_length_ends,
        .ends_in_backslash = (backslash_mask & (one << @as(Shift, @intCast(bit_count - 1)))) != 0,
    };
}

fn backslashRunMask(comptime T: type, start: usize, length: usize) T {
    const bit_count: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    const end = @min(start + length, bit_count);
    var mask: T = 0;
    var bit_index = start;
    while (bit_index < end) : (bit_index += 1) {
        mask |= one << @as(Shift, @intCast(bit_index));
    }
    return mask;
}

fn expectBoundaryBackslashRunParity(comptime T: type) !void {
    const bit_count: usize = @typeInfo(T).int.bits;
    const boundary_positions = [_]usize{ 14, 15, 16, 17, 30, 31, 32, 33 };
    const run_lengths = [_]usize{ 1, 2, 3, 4 };

    for (boundary_positions) |start| {
        if (start >= bit_count) continue;
        for (run_lengths) |length| {
            const mask = backslashRunMask(T, start, length);
            for ([_]bool{ false, true }) |prev_ends_in_backslash| {
                const expected = scalarBackslashRunParity(
                    T,
                    mask,
                    prev_ends_in_backslash,
                );
                const actual = computeBackslashRuns(
                    T,
                    mask,
                    prev_ends_in_backslash,
                );
                try testing.expectEqual(expected.odd_length_ends, actual.odd_length_ends);
                try testing.expectEqual(expected.ends_in_backslash, actual.ends_in_backslash);
            }
        }
    }
}

fn expectBackslashRunParity(comptime T: type) !void {
    const one: T = 1;
    const mixed_runs: T = 0b1110_1101;
    const result = computeBackslashRuns(T, mixed_runs, false);
    const expected = scalarBackslashRunParity(T, mixed_runs, false);

    try testing.expectEqual((one << 1) | (one << 8), result.odd_length_ends);
    try testing.expect(!result.ends_in_backslash);
    try testing.expectEqual(expected.odd_length_ends, result.odd_length_ends);
    try testing.expectEqual(expected.ends_in_backslash, result.ends_in_backslash);

    const even_run = computeBackslashRuns(T, 0b11, false);
    const expected_even_run = scalarBackslashRunParity(T, 0b11, false);
    try testing.expectEqual(@as(T, 0), even_run.odd_length_ends);
    try testing.expectEqual(expected_even_run.odd_length_ends, even_run.odd_length_ends);
    try testing.expectEqual(expected_even_run.ends_in_backslash, even_run.ends_in_backslash);

    const carried_run = computeBackslashRuns(T, 0, true);
    const expected_carried_run = scalarBackslashRunParity(T, 0, true);
    try testing.expectEqual(one, carried_run.odd_length_ends);
    try testing.expectEqual(expected_carried_run.odd_length_ends, carried_run.odd_length_ends);
    try testing.expectEqual(expected_carried_run.ends_in_backslash, carried_run.ends_in_backslash);

    const top_bit = one << (@typeInfo(T).int.bits - 1);
    const trailing_run = computeBackslashRuns(T, top_bit, false);
    const expected_trailing_run = scalarBackslashRunParity(T, top_bit, false);
    try testing.expectEqual(
        expected_trailing_run.ends_in_backslash,
        trailing_run.ends_in_backslash,
    );

    try expectBoundaryBackslashRunParity(T);
}

test "computeBackslashRuns handles u16 escaped-run parity" {
    try expectBackslashRunParity(u16);
}

test "computeBackslashRuns handles u32 escaped-run parity" {
    try expectBackslashRunParity(u32);
}

test "computeBackslashRuns handles u64 escaped-run parity" {
    try expectBackslashRunParity(u64);
}

test "computeBackslashRuns stays exact at padded and over-wide storage" {
    // Cover empty, first-lane and last-lane masks across target-derived storage
    // widths, including an exact-storage control at 128 bits.
    inline for (.{
        Mask(24),  Mask(48),  Mask(65),  Mask(100),
        Mask(128), Mask(129), Mask(257),
    }) |t| {
        try expectBackslashRunParity(t);
    }
}

fn expectExhaustiveBackslashRunParity(comptime T: type) !void {
    const bit_count: usize = @typeInfo(T).int.bits;
    comptime assert(bit_count < @bitSizeOf(usize));
    const mask_count = @as(usize, 1) << bit_count;

    var mask_value: usize = 0;
    while (mask_value < mask_count) : (mask_value += 1) {
        const backslash_mask: T = @intCast(mask_value);
        for ([_]bool{ false, true }) |prev_ends_in_backslash| {
            const expected = scalarBackslashRunParity(
                T,
                backslash_mask,
                prev_ends_in_backslash,
            );
            const actual = computeBackslashRuns(
                T,
                backslash_mask,
                prev_ends_in_backslash,
            );
            try testing.expectEqual(expected.odd_length_ends, actual.odd_length_ends);
            try testing.expectEqual(expected.ends_in_backslash, actual.ends_in_backslash);
        }
    }
}

test "computeBackslashRuns matches scalar parity for every small mask" {
    inline for (.{ u4, u5, u7 }) |t| {
        try expectExhaustiveBackslashRunParity(t);
    }
}

fn expectBitIndexExtraction(comptime T: type) !void {
    const bit_count = @typeInfo(T).int.bits;
    const one: T = 1;
    const mask = (one << 1) | (one << (bit_count / 2)) | (one << (bit_count - 1));

    var indexes: [3]u32 = undefined;
    const count = extractBitIndexes(T, mask, 100, &indexes);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 101), indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(100 + bit_count / 2)), indexes[1]);
    try testing.expectEqual(@as(u32, @intCast(100 + bit_count - 1)), indexes[2]);

    var bounded_indexes: [2]u32 = undefined;
    const bounded_count = extractBitIndexes(T, mask, 200, &bounded_indexes);
    try testing.expectEqual(@as(usize, 2), bounded_count);
    try testing.expectEqual(@as(u32, 201), bounded_indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(200 + bit_count / 2)), bounded_indexes[1]);

    var empty: [0]u32 = .{};
    try testing.expectEqual(@as(usize, 0), extractBitIndexes(T, mask, 0, &empty));
}

test "extractBitIndexes handles arbitrary mask widths" {
    inline for (.{ u4, u5, u7, u16, u32, u64 }) |t| {
        try expectBitIndexExtraction(t);
    }
}

fn expectMatchedByteIndexExtraction(comptime len: usize) !void {
    const base_offset: usize = 500;
    var matching_lane: usize = 0;
    errdefer std.log.err("width={d} matching_lane={d}", .{ len, matching_lane });
    while (matching_lane < len) : (matching_lane += 1) {
        var bytes: [len]u8 = @splat(0);
        bytes[matching_lane] = '<';

        const vector: Vec(u8, len) = bytes;
        const storage = MaskStorage(len);
        const expected = @as(storage, 1) <<
            @as(std.math.Log2Int(storage), @intCast(matching_lane));
        try testing.expectEqual(expected, exactMask(Mask(len), matchByte(len, vector, '<')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny2(len, vector, '<', '>')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny4(len, vector, '<', '>', '=', '"')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchRange(len, vector, '<', '>')));

        // Candidate positions other than c1: the same lane must be found when
        // the matching byte is the second, third, or fourth candidate.
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny2(len, vector, '>', '<')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny4(len, vector, '>', '=', '"', '<')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny4(len, vector, '>', '=', '<', '"')));
        try testing.expectEqual(expected, exactMask(Mask(len), matchAny4(len, vector, '>', '<', '=', '"')));

        // Two matching lanes. Every assertion above finds a single byte, so
        // none of them can reach a mask that carries more than one bit.
        const other_lane = (matching_lane + 1) % len;
        var pair: [len]u8 = @splat(0);
        pair[matching_lane] = '<';
        pair[other_lane] = '<';
        const pair_vector: Vec(u8, len) = pair;
        const pair_expected = expected | (@as(storage, 1) <<
            @as(std.math.Log2Int(storage), @intCast(other_lane)));
        try testing.expectEqual(
            pair_expected,
            exactMask(Mask(len), matchByte(len, pair_vector, '<')),
        );
        try testing.expectEqual(
            pair_expected,
            exactMask(Mask(len), matchAny2(len, pair_vector, '<', '>')),
        );
        try testing.expectEqual(
            pair_expected,
            exactMask(Mask(len), matchAny4(len, pair_vector, '<', '>', '=', '"')),
        );
        try testing.expectEqual(
            pair_expected,
            exactMask(Mask(len), matchRange(len, pair_vector, '<', '>')),
        );

        const punctuation_mask = matchAny4(len, vector, '<', '>', '=', '"') |
            matchByte(len, vector, '\'');
        var indexes: [len]u32 = undefined;
        const count = extractBitIndexes(Mask(len), punctuation_mask, base_offset, &indexes);

        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(
            @as(u32, @intCast(base_offset + matching_lane)),
            indexes[0],
        );
    }
}

test "comparison masks extract only matching vector lanes" {
    inline for (.{ 4, 5, 7, 12, 16, 24, 32, 48, 64, 65, 257 }) |len| {
        try expectMatchedByteIndexExtraction(len);
    }
}

fn expectCtzResultType(comptime T: type) void {
    comptime validateMaskType(T);
    const CtzResultType = @TypeOf(@ctz(@as(T, 1)));
    comptime assert(CtzResultType == std.math.Log2IntCeil(T));
}

test "@ctz returns Log2IntCeil for every mask width" {
    comptime {
        expectCtzResultType(u16);
        expectCtzResultType(u32);
        expectCtzResultType(u64);
    }
}

test "extractBitIndexes handles u16 masks" {
    try expectBitIndexExtraction(u16);
}

test "extractBitIndexes handles u32 masks" {
    try expectBitIndexExtraction(u32);
}

test "extractBitIndexes handles u64 masks" {
    try expectBitIndexExtraction(u64);
}

fn scalarJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// The sweep's scalar oracle, kept out of line. Same classifier, same
/// arithmetic, one lane walk over the array. The inlined form also diverged at
/// width 64, so it is separated for the same reason the leaves above are.
noinline fn whitespaceMaskBytes(comptime len: usize, bytes: [len]u8) Mask(len) {
    var result: Mask(len) = 0;
    for (bytes, 0..) |byte, lane| {
        if (scalarJsonWhitespace(byte)) {
            result |= @as(Mask(len), 1) <<
                @as(std.math.Log2Int(Mask(len)), @intCast(lane));
        }
    }
    return result;
}

fn expectJsonWhitespaceForWidth(comptime len: usize) !void {
    var bytes: [len]u8 = undefined;
    var byte_start: usize = 0;
    errdefer std.log.err("width={d} byte_start={d}", .{ len, byte_start });
    while (byte_start < 256) : (byte_start += 1) {
        for (0..len) |lane| {
            bytes[lane] = @intCast((byte_start + lane) % 256);
        }

        const vector: Vec(u8, len) = bytes;
        // Compare the matcher and scalar oracle in the same representation.
        const actual = exactMask(Mask(len), matchJsonWhitespace(len, vector));
        const expected = whitespaceMaskBytes(len, bytes);
        try testing.expectEqual(exactMask(Mask(len), expected), actual);
    }
}

test "matchJsonWhitespace agrees with scalar classification for every byte" {
    inline for (.{ 4, 5, 7, 12, 16, 24, 32, 48, 64, 129, 257 }) |len| {
        try expectJsonWhitespaceForWidth(len);
    }
}

fn expectValidMasks(comptime bits: usize) !void {
    var valid_count: usize = 0;
    while (valid_count <= bits) : (valid_count += 1) {
        const expected: Mask(bits) = if (valid_count == bits)
            std.math.maxInt(Mask(bits))
        else if (valid_count == 0)
            0
        else
            (@as(Mask(bits), 1) <<
                @as(std.math.Log2Int(Mask(bits)), @intCast(valid_count))) - 1;
        try testing.expectEqual(expected, validMask(bits, valid_count));
    }
}

test "validMask canonicalizes every width and tail count" {
    inline for (.{ 4, 5, 7, 16, 32, 64 }) |bits| {
        try expectValidMasks(bits);
    }
}

fn scalarTrailingRunOdd(
    comptime T: type,
    mask: T,
    valid_count: usize,
    previous_odd: bool,
) bool {
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    if (valid_count == 0) return false;

    var run_length: usize = 0;
    var bit_index = valid_count;
    while (bit_index > 0 and
        (mask & (one << @as(Shift, @intCast(bit_index - 1)))) != 0)
    {
        bit_index -= 1;
        run_length += 1;
    }
    if (bit_index == 0) return (run_length % 2 == 0) == previous_odd;
    return run_length % 2 != 0;
}

fn expectTrailingRunOddSmall(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const mask_count: usize = @as(usize, 1) << bits;
    var mask_value: usize = 0;
    while (mask_value < mask_count) : (mask_value += 1) {
        const mask: T = @intCast(mask_value);
        var valid_count: usize = 0;
        while (valid_count <= bits) : (valid_count += 1) {
            for ([_]bool{ false, true }) |previous_odd| {
                try testing.expectEqual(
                    scalarTrailingRunOdd(T, mask, valid_count, previous_odd),
                    trailingRunOdd(bits, mask, valid_count, previous_odd),
                );
            }
        }
    }
}

fn alternatingMask(comptime T: type) T {
    const bits: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    var result: T = 0;
    inline for (0..bits) |bit_index| {
        if (bit_index % 2 == 0) {
            result |= one << @as(Shift, @intCast(bit_index));
        }
    }
    return result;
}

fn expectTrailingRunOddWide(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const masks = [_]T{
        0,
        std.math.maxInt(T),
        alternatingMask(T),
        1,
        std.math.maxInt(T) ^ @as(T, 1),
    };
    for (masks) |mask| {
        var valid_count: usize = 0;
        while (valid_count <= bits) : (valid_count += 1) {
            for ([_]bool{ false, true }) |previous_odd| {
                try testing.expectEqual(
                    scalarTrailingRunOdd(T, mask, valid_count, previous_odd),
                    trailingRunOdd(bits, mask, valid_count, previous_odd),
                );
            }
        }
    }
}

test "trailingRunOdd agrees with scalar carry for all small masks" {
    inline for (.{ u4, u5, u7 }) |t| {
        try expectTrailingRunOddSmall(t);
    }
}

test "trailingRunOdd agrees with scalar carry for wide masks" {
    inline for (.{ u16, u32, u64 }) |t| {
        try expectTrailingRunOddWide(t);
    }
}

test "trailingRunOdd agrees with scalar carry at padded and over-wide storage" {
    // Alignment and leading-zero count must use the same width to preserve
    // trailing-run parity. Storage need not be a power of two: 257 logical
    // bits can occupy 384 storage bits.
    inline for (.{
        Mask(24),  Mask(48),  Mask(65),  Mask(100),
        Mask(128), Mask(129), Mask(257),
    }) |t| {
        try expectTrailingRunOddWide(t);
    }
}

fn expectCheckedBitIndexExtraction(comptime T: type) !void {
    const bits: usize = @typeInfo(T).int.bits;
    const Shift = std.math.Log2Int(T);
    const one: T = 1;
    const bitmask = (one << @as(Shift, 0)) |
        (one << @as(Shift, @intCast(bits / 2))) |
        (one << @as(Shift, @intCast(bits - 1)));

    var indexes: [3]u32 = undefined;
    const count = try extractBitIndexesChecked(T, bitmask, 100, &indexes);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 100), indexes[0]);
    try testing.expectEqual(@as(u32, @intCast(100 + bits / 2)), indexes[1]);
    try testing.expectEqual(@as(u32, @intCast(100 + bits - 1)), indexes[2]);

    var short_indexes = [_]u32{ 0xdead_beef, 0xcafe_babe };
    try testing.expectError(
        error.CapacityExceeded,
        extractBitIndexesChecked(T, bitmask, 100, &short_indexes),
    );
    try testing.expectEqualSlices(
        u32,
        &.{ 0xdead_beef, 0xcafe_babe },
        &short_indexes,
    );

    var overflow_indexes = [_]u32{ 0xdead_beef, 0xcafe_babe, 0xfeed_face };
    try testing.expectError(
        error.InputTooLarge,
        extractBitIndexesChecked(
            T,
            bitmask,
            std.math.maxInt(u32),
            &overflow_indexes,
        ),
    );
    try testing.expectEqualSlices(
        u32,
        &.{ 0xdead_beef, 0xcafe_babe, 0xfeed_face },
        &overflow_indexes,
    );

    var boundary_index: [1]u32 = undefined;
    try testing.expectEqual(
        @as(usize, 1),
        try extractBitIndexesChecked(
            T,
            one,
            std.math.maxInt(u32),
            &boundary_index,
        ),
    );
    try testing.expectEqual(std.math.maxInt(u32), boundary_index[0]);

    var empty: [0]u32 = .{};
    try testing.expectEqual(
        @as(usize, 0),
        try extractBitIndexesChecked(
            T,
            0,
            std.math.maxInt(usize),
            &empty,
        ),
    );
}

test "extractBitIndexesChecked emits complete output at all supported widths" {
    inline for (.{ u4, u5, u7, u16, u32, u64 }) |t| {
        try expectCheckedBitIndexExtraction(t);
    }
}

test "extractBitIndexes handles mask widths above 64 bits" {
    inline for (.{ u65, u72, u100, u128 }) |t| {
        try expectBitIndexExtraction(t);
        try expectCheckedBitIndexExtraction(t);
    }
}
