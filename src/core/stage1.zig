//! The fixed-capacity offset index Stage 1 produces and Stage 2 consumes.
//!
//! `StructuralIndex` owns one buffer of `u32` byte offsets and the three
//! sentinels that close it; it copies no input and holds no reference to the
//! bytes those offsets point at. Callers reach it as `stage1` from the package
//! root. Incremental scanning that fills one lives in `stream`, and the tape
//! and grammar that read an index live in `stage2`.
//!
//! The caller supplies the allocator to `init` and the same allocator to
//! `deinit`, and calls `deinit` exactly once. Nothing here reads or writes a
//! file.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// One input's structural byte offsets, in a buffer sized once and never grown.
///
/// `init` reserves `max_capacity` offsets plus three sentinels; the producer
/// writes offsets into `indexes` and keeps `count`, and `finish` writes the
/// sentinels. There is no push, no growth and no check that the producer stayed
/// inside `max_capacity`: entries past `indexes.len` are an overrun this type
/// cannot see. A struct literal is not a usable state either, because
/// `finish` then has no room for the sentinels.
///
/// The buffer is unmanaged. The allocator passed to `init` must be the one
/// passed to `deinit`, and `deinit` is called exactly once. Copying the value
/// copies the slice header rather than the offsets, so a copy is a second name
/// for the same allocation and deinitializing both is a double free.
pub const StructuralIndex = struct {
    const sentinel_count = 3;

    /// Every way `init` can fail: its own two refusals and the allocator's.
    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    /// Every way `finish` can fail. The only one is decided before anything
    /// is written.
    pub const FinishError = error{InputTooLarge};

    /// The reserved buffer: offsets written by the producer, then the three
    /// sentinels `finish` appends. It is never resized, so a write past
    /// `max_capacity + 3` entries overruns it.
    indexes: []u32,
    /// How many leading entries of `indexes` are real offsets. Nothing in this
    /// type maintains it: the producer sets it, `finish` and `slice` read it,
    /// and `finish` deliberately leaves it alone.
    count: usize,

    /// Reserves room for `max_capacity` offsets plus the three sentinels.
    ///
    /// `error.CapacityOverflow` when `max_capacity` plus three wraps `usize`,
    /// and `error.InputTooLarge` when `max_capacity` exceeds `maxInt(u32)`;
    /// neither allocates. `error.OutOfMemory` comes from `allocator` and
    /// leaves nothing for the caller to release.
    pub fn init(
        allocator: std.mem.Allocator,
        max_capacity: usize,
    ) InitError!StructuralIndex {
        const allocation_capacity = std.math.add(
            usize,
            max_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;

        const memory = try allocator.alloc(u32, allocation_capacity);
        return .{
            .indexes = memory,
            .count = 0,
        };
    }

    /// Releases the offset buffer with the allocator `init` was given.
    ///
    /// The allocator itself is not released here; the caller keeps it. The
    /// value is `undefined` afterward, so a second call is a double free.
    pub fn deinit(self: *StructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        self.* = undefined;
    }

    /// Writes the three sentinels for an input of `input_len` bytes.
    ///
    /// They land at `indexes[count..]` as `input_len, input_len, 0`, and
    /// `count` is unchanged, so they stay outside `slice`.
    /// `error.InputTooLarge` when `input_len` exceeds `maxInt(u32)`, decided
    /// before anything is written, so the buffer keeps its previous contents.
    /// Calling it again simply rewrites the sentinels.
    ///
    /// Two `std.debug.assert` checks hold that the buffer has room for three
    /// sentinels and that `count` leaves that room. A value built by struct
    /// literal rather than `init` can break both, which Debug and ReleaseSafe
    /// diagnose and the fast release modes treat as unchecked illegal behavior.
    pub fn finish(self: *StructuralIndex, input_len: usize) FinishError!void {
        if (input_len > std.math.maxInt(u32)) return error.InputTooLarge;
        assert(self.indexes.len >= sentinel_count);
        assert(self.count <= self.indexes.len - sentinel_count);

        const sentinel: u32 = @intCast(input_len);
        self.indexes[self.count..][0..sentinel_count].* = .{
            sentinel,
            sentinel,
            0,
        };
    }

    /// The `count` offsets written so far, borrowing `indexes`.
    ///
    /// The result excludes the sentinels and is invalidated by `deinit`; the
    /// sentinel region `finish` writes lies outside it.
    pub fn slice(self: *const StructuralIndex) []const u32 {
        return self.indexes[0..self.count];
    }
};

fn checkStructuralIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    var index = try StructuralIndex.init(allocator, 16);
    defer index.deinit(allocator);
}

test "StructuralIndex propagates allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkStructuralIndexAllocationFailure,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "StructuralIndex lifecycle" {
    var idx = try StructuralIndex.init(testing.allocator, 16);
    defer idx.deinit(testing.allocator);

    idx.indexes[0..2].* = .{ 3, 11 };
    idx.count = 2;
    try idx.finish(42);

    try testing.expectEqual(@as(usize, 2), idx.count);
    try testing.expectEqual(@as(usize, 19), idx.indexes.len);
    try testing.expectEqualSlices(u32, &.{ 3, 11 }, idx.slice());
    try testing.expectEqualSlices(u32, &.{ 42, 42, 0 }, idx.indexes[2..5]);
}

test "StructuralIndex empty input has sentinel capacity" {
    var idx = try StructuralIndex.init(testing.allocator, 0);
    defer idx.deinit(testing.allocator);

    try idx.finish(0);

    try testing.expectEqual(@as(usize, 0), idx.count);
    try testing.expectEqual(@as(usize, 3), idx.indexes.len);
    try testing.expectEqual(@as(usize, 0), idx.slice().len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, idx.indexes);
}

test "StructuralIndex rejects unrepresentable capacity and input" {
    try testing.expectError(
        error.CapacityOverflow,
        StructuralIndex.init(testing.allocator, std.math.maxInt(usize)),
    );

    var idx = try StructuralIndex.init(testing.allocator, 1);
    defer idx.deinit(testing.allocator);

    // Only expressible where usize is wider than u32. On a 32-bit target the
    // oversized length itself does not fit the pointer width, so there is no
    // input to reject: the expression below would not compile there.
    if (@bitSizeOf(usize) > @bitSizeOf(u32)) {
        try testing.expectError(
            error.InputTooLarge,
            StructuralIndex.init(
                testing.allocator,
                @as(usize, std.math.maxInt(u32)) + 1,
            ),
        );
        try testing.expectError(
            error.InputTooLarge,
            idx.finish(@as(usize, std.math.maxInt(u32)) + 1),
        );
    }
}
