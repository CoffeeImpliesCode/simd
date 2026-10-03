//! The lease, focus, and reusable index storage the resident on-demand readers
//! share.
//!
//! A `State` is one parser's liveness record: `begin` opens a single lease
//! against it, `Lease.claim` hands out at most one `Guard` for that lease, and
//! `Lease.release` closes it. `Guard` adds an ordered position inside the
//! lease. `IndexBuffer` is the reusable parallel storage a resident reader
//! fills with structural offsets and, when its format needs them, per-token
//! kinds and lengths.
//!
//! Nothing here copies source bytes. A `State` borrows no input, a `Lease` and
//! a `Guard` borrow their `State`, and an `IndexBuffer` stores offsets into
//! source the caller keeps alive; only the buffer owns memory, through the
//! allocator it was built with.
//!
//! No function here performs I/O or retains a capability, and none can block.
//!
//! The format adapters store these values in their own fields, so a consumer
//! reaches them through `formats.jsonl`, `formats.markdown`, `formats.xml`,
//! and `formats.yaml`. Grammar, dialect, and event rules belong to those
//! modules and to `core.stage2`; this module owns only the shared lifecycle
//! and storage.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const sentinel_count: usize = 3;

/// The failures the shared lease, focus, and guard state reports.
///
/// `error.DocumentActive` when a lease is already open, `error.DocumentReleased`
/// when a `Lease` or `Guard` no longer matches its `State`, and
/// `error.FocusAlreadyClaimed` when a second `Guard` is claimed on one lease.
/// `error.OutOfOrderIteration` is a `Guard` that no longer matches the shared
/// position, or one whose `advance` would overflow. Every entry point here
/// returns this whole set rather than a narrower one, so a caller switching
/// exhaustively handles tags the call it is matching cannot produce.
pub const Error = error{
    DocumentActive,
    DocumentReleased,
    FocusAlreadyClaimed,
    OutOfOrderIteration,
};

/// One parser's lease, focus, and position state.
///
/// A `State` owns nothing and borrows nothing: it holds four values, and the
/// parser that embeds it releases it with one `deinit`. `State{}` is a valid
/// empty state with no lease open. It must stay at a stable address while a
/// `Lease` or `Guard` from it is used, because both store `*State`, and a copy
/// is not a second owner: two copies describe the same lease.
///
/// No method synchronizes, so a `State` shared across threads is a data race,
/// and none calls back into caller code.
pub const State = struct {
    /// The generation of the open lease, `0` when none is open. `begin`
    /// advances it and wraps `std.math.maxInt(u64)` to `1`, so the values run
    /// `1 .. std.math.maxInt(u64)` and then repeat. A `Lease` and a `Guard`
    /// compare against it to reject handles from an earlier lease; the counter
    /// is finite, so it identifies a lease within `2^64 - 1` further `begin`
    /// calls and never proves that the source or storage behind a handle is
    /// still alive.
    generation: u64 = 0,
    /// Whether a lease is open. `begin` refuses while this is set and `release`
    /// clears it.
    active: bool = false,
    /// Whether the open lease's focus has been claimed by a `Guard`. Cleared
    /// by `release` and by the next `begin`, and never by dropping a `Guard`.
    claimed: bool = false,
    /// The position the open lease's `Guard` has advanced to. `Guard.check`
    /// compares it against that guard's own copy.
    position: usize = 0,

    /// Opens a lease and returns it.
    ///
    /// Advances `generation`, marks the state active, clears `claimed`, resets
    /// `position` to `0`, and returns a `Lease` naming this state and the new
    /// generation. Nothing is allocated and nothing is copied out of the
    /// state, so the state must outlive the returned lease and every `Guard`
    /// taken from it.
    ///
    /// `error.DocumentActive` when a lease is already open; the open lease and
    /// its claim are untouched on that path.
    pub fn begin(self: *State) Error!Lease {
        if (self.active) return error.DocumentActive;

        self.generation = if (self.generation == std.math.maxInt(u64))
            1
        else
            self.generation + 1;
        self.active = true;
        self.claimed = false;
        self.position = 0;

        return .{
            .state = self,
            .generation = self.generation,
        };
    }

    /// Invalidates the state.
    ///
    /// Every `Lease` and `Guard` must be released first. The precondition that
    /// no lease is open is checked by `std.debug.assert`, so Debug and
    /// ReleaseSafe diagnose the violation and ReleaseFast and ReleaseSmall
    /// treat it as unchecked illegal behavior. Nothing is freed, because the
    /// state owns no allocation. One call per value: the state is left
    /// undefined, so a second call reads undefined memory.
    pub fn deinit(self: *State) void {
        assert(!self.active);
        self.* = undefined;
    }
};

/// One open lease on a `State`.
///
/// A `Lease` is a value, so copying one copies the mark rather than creating a
/// second owner: `release` through any copy closes the lease for all of them.
/// It holds no reference count, so a copy kept past `release` is inert rather
/// than dangling, and `release` on such a copy closes nothing. There is no
/// `deinit`; the owning teardown is `State.deinit`.
pub const Lease = struct {
    /// The state this lease was opened on. Must stay alive and at the same
    /// address while the lease or any `Guard` from it is used, and must not be
    /// `deinit`'d before they are released.
    state: *State,
    /// The `State.generation` at `begin`, compared on every call so that a mark
    /// from an earlier lease is rejected.
    generation: u64,

    /// Reports whether this lease is still the state's open lease.
    ///
    /// `error.DocumentReleased` once the lease has been released or the state
    /// has moved to another generation. Changes nothing, including on failure.
    pub fn check(self: Lease) Error!void {
        if (!self.state.active) return error.DocumentReleased;
        if (self.state.generation != self.generation) return error.DocumentReleased;
    }

    /// Closes this lease and clears its focus claim.
    ///
    /// Clears `active` and `claimed` and nothing else; `generation` and
    /// `position` are left to the next `begin`. Nothing is freed. Repeating the
    /// call, and calling it through a mark from an earlier generation, does
    /// nothing: a stale `Lease` cannot close the live one, so this is safe in
    /// a `defer` next to an explicit release. A `Guard` taken from this lease
    /// reports `error.DocumentReleased` from then on.
    pub fn release(self: Lease) void {
        if (!self.state.active) return;
        if (self.state.generation != self.generation) return;

        self.state.active = false;
        self.state.claimed = false;
    }

    /// Claims the lease's single focus and returns a `Guard`.
    ///
    /// The guard starts at the state's current `position`.
    /// `error.DocumentReleased` when the lease is not the open one, and
    /// `error.FocusAlreadyClaimed` when the focus is already claimed.
    ///
    /// The claim lasts until `release`. Dropping the `Guard` does not give the
    /// focus back, so a second `claim` on the same lease reports
    /// `error.FocusAlreadyClaimed` until the lease is released.
    pub fn claim(self: Lease) Error!Guard {
        try self.check();
        if (self.state.claimed) return error.FocusAlreadyClaimed;

        self.state.claimed = true;
        return .{
            .lease = self,
            .expected_position = self.state.position,
        };
    }
};

/// One focused, ordered position inside a lease.
///
/// A `Guard` owns nothing and borrows its `Lease`, which borrows the `State`;
/// all three must stay alive while it is used. It has no teardown and must not
/// be released when it goes out of scope: releasing the lease here would end
/// the document the guard is still reading. `Lease.release` is the only
/// release.
///
/// Copying a guard copies its expected position rather than creating a second
/// consumer, so once either copy advances, the other reports
/// `error.OutOfOrderIteration`. No method synchronizes and none calls back
/// into caller code.
pub const Guard = struct {
    /// The lease whose focus this guard holds, by value. Its `state` field is
    /// reachable, so a consumer can call `release` on it directly, which closes
    /// the lease and makes every later call on this guard report
    /// `error.DocumentReleased`.
    lease: Lease,
    /// The position this guard expects `State.position` to hold. `advance`
    /// updates both; a copy keeps the older value.
    expected_position: usize,

    /// Reports whether the lease is open and the shared position still matches.
    ///
    /// `error.DocumentReleased` is checked first, so a guard that is both
    /// released and behind reports it rather than
    /// `error.OutOfOrderIteration`. The position is compared against
    /// `State.position`, which is what a sibling copy of this guard sees once
    /// the other advances.
    pub fn check(self: *const Guard) Error!void {
        try self.lease.check();
        if (self.lease.state.position != self.expected_position) {
            return error.OutOfOrderIteration;
        }
    }

    /// Advances the shared position by one and keeps this guard in step.
    ///
    /// `error.OutOfOrderIteration` is reported instead of advancing when
    /// `expected_position` is `std.math.maxInt(usize)`; the position and this
    /// guard are then left exactly as they were, as they are on every other
    /// failure. The checks `check` reports apply first.
    pub fn advance(self: *Guard) Error!void {
        try self.check();
        const next_position = std.math.add(
            usize,
            self.expected_position,
            1,
        ) catch return error.OutOfOrderIteration;
        self.lease.state.position = next_position;
        self.expected_position = next_position;
    }
};

/// Reusable parallel storage for one structural index.
///
/// The returned type is a struct with no name of its own: `Kind` is `void` for
/// a format that records no token kind, and `with_lengths` is `false` for one
/// that records no token length; the array for an absent kind or length stays
/// the empty slice at every capacity and occupies no storage. Both are comptime
/// parameters the format adapter chooses, not run-time options.
///
/// A buffer owns its three arrays and borrows the allocator it was built with,
/// which must stay valid and must not be replaced before `deinit`, or the
/// arrays are freed through an allocator that did not produce them. Every field
/// is reachable and writable, and `kinds` and `lengths` must stay parallel to
/// `indexes[0..count]`: a caller writes them and nothing here cross-checks.
///
/// `indexes` holds `capacity` offsets followed by three sentinel slots that
/// `finish` writes; `kinds` and `lengths` hold `capacity` entries each. Copying
/// a buffer copies the handles to those arrays rather than creating a second
/// owner, so exactly one copy is `deinit`'d. Nothing here synchronizes and no
/// method calls back into caller code.
pub fn IndexBuffer(comptime Kind: type, comptime with_lengths: bool) type {
    return struct {
        const Self = @This();

        /// The allocator every array was allocated from and is released
        /// through. Stored, not owned: `deinit` frees with it.
        allocator: std.mem.Allocator,
        /// The structural offsets, followed by three sentinel slots once
        /// `finish` has run. Owned, reachable, and replaced by a growing
        /// `reserve`, so a slice taken from it is valid only until that call.
        indexes: []u32,
        /// One `Kind` per token, parallel to `indexes[0..capacity]`. Always the
        /// empty slice when `Kind` is `void`.
        kinds: []Kind,
        /// One length per token, parallel to `indexes[0..capacity]`. Always the
        /// empty slice unless `with_lengths` is `true`.
        lengths: []u32,
        /// Token slots each array holds, excluding the sentinel slots. `0` in a
        /// fresh buffer and the last size `reserve` installed.
        capacity: usize,
        /// Tokens the last `finish` recorded. `reserve` carries this many
        /// entries of each array into new storage and drops everything above
        /// them.
        count: usize,

        /// The failures `reserve` reports: allocation failure, a token count
        /// whose sum with the sentinel slots overflows `usize`, or a requested
        /// array whose byte size overflows `usize`. The last two are checked
        /// before anything is allocated.
        pub const ReserveError = std.mem.Allocator.Error || error{CapacityOverflow};
        /// The failures `finish` reports: every `ReserveError` tag, plus
        /// `error.CapacityExceeded` for a count above `capacity` and
        /// `error.InputTooLarge` for a source length above the `u32` offset
        /// range.
        pub const FinishError = ReserveError || error{
            CapacityExceeded,
            InputTooLarge,
        };

        /// Returns an empty buffer that owns nothing and allocates nothing.
        ///
        /// `capacity` and `count` are `0` and every array is the empty slice,
        /// so the buffer is usable immediately and `deinit` on it frees
        /// nothing. The allocator is stored for later `reserve` and for
        /// `deinit`; it is not released here.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .indexes = &.{},
                .kinds = &.{},
                .lengths = &.{},
                .capacity = 0,
                .count = 0,
            };
        }

        /// Makes room for `token_capacity` tokens in each array, growing only
        /// when it has to.
        ///
        /// A request that fits the current `capacity` and storage returns
        /// without touching the arrays, so a caller that sized the buffer once
        /// keeps the addresses it already holds. Otherwise all three arrays
        /// are allocated at the new size, `indexes[0..count]`,
        /// `kinds[0..count]`, and `lengths[0..count]` are copied into them, and
        /// the old arrays are freed: a growing call invalidates every slice
        /// previously taken from these fields, and it carries over only the
        /// entries below `count`, so the sentinel slots and anything past
        /// `count` are gone until the next `finish`.
        ///
        /// The call is transactional. Each new array is registered for release
        /// before the next allocation, so a failure at any allocation leaves
        /// `indexes`, `kinds`, `lengths`, `capacity`, and `count` exactly as
        /// they were and frees the new arrays. The residue after a failure is
        /// the caller's buffer unchanged, not a half-grown one.
        pub fn reserve(self: *Self, token_capacity: usize) ReserveError!void {
            assert(self.count <= self.capacity);
            if (token_capacity <= self.capacity and self.indexes.len != 0) return;

            const index_capacity = std.math.add(
                usize,
                token_capacity,
                sentinel_count,
            ) catch return error.CapacityOverflow;
            try checkAllocationSize(u32, index_capacity);
            if (comptime Kind != void) {
                try checkAllocationSize(Kind, token_capacity);
            }
            if (with_lengths) {
                try checkAllocationSize(u32, token_capacity);
            }

            const new_indexes = try self.allocator.alloc(u32, index_capacity);
            errdefer self.allocator.free(new_indexes);

            var new_kinds: []Kind = &.{};
            if (comptime Kind != void) {
                if (token_capacity != 0) {
                    new_kinds = try self.allocator.alloc(Kind, token_capacity);
                }
            }
            errdefer {
                if (comptime Kind != void) {
                    if (new_kinds.len != 0) self.allocator.free(new_kinds);
                }
            }

            var new_lengths: []u32 = &.{};
            if (with_lengths) {
                if (token_capacity != 0) {
                    new_lengths = try self.allocator.alloc(u32, token_capacity);
                }
            }
            errdefer {
                if (with_lengths) {
                    if (new_lengths.len != 0) self.allocator.free(new_lengths);
                }
            }

            if (self.count != 0) {
                @memcpy(new_indexes[0..self.count], self.indexes[0..self.count]);
                if (comptime Kind != void) {
                    @memcpy(new_kinds[0..self.count], self.kinds[0..self.count]);
                }
                if (with_lengths) {
                    @memcpy(new_lengths[0..self.count], self.lengths[0..self.count]);
                }
            }

            const old_indexes = self.indexes;
            const old_kinds = self.kinds;
            const old_lengths = self.lengths;

            self.indexes = new_indexes;
            self.kinds = new_kinds;
            self.lengths = new_lengths;
            self.capacity = token_capacity;

            if (old_indexes.len != 0) self.allocator.free(old_indexes);
            if (comptime Kind != void) {
                if (old_kinds.len != 0) self.allocator.free(old_kinds);
            }
            if (with_lengths) {
                if (old_lengths.len != 0) self.allocator.free(old_lengths);
            }
        }

        /// Records `count` tokens over a source of `input_len` bytes and writes
        /// the three sentinel slots that follow them.
        ///
        /// The sentinels are `input_len`, `input_len`, and `0`, which is what
        /// makes a length lookup at the last token and at the end of the source
        /// well defined. `finish` records a count and writes sentinels; it
        /// stores no offsets of its own and validates none of the ones the
        /// caller wrote into `indexes[0..count]`, which stays the caller's
        /// obligation. An unallocated buffer is allocated first, so
        /// `finish(0, 0)` on a fresh buffer succeeds.
        ///
        /// Calling it again is allowed: it rewrites `count` and the sentinels,
        /// and the offsets above the new count stay in the buffer unread.
        ///
        /// Every check runs before any write, so `error.InputTooLarge`,
        /// `error.CapacityExceeded`, and the `ReserveError` tags leave the
        /// buffer exactly as it was, `count` included.
        pub fn finish(
            self: *Self,
            count: usize,
            input_len: usize,
        ) FinishError!void {
            if (input_len > std.math.maxInt(u32)) return error.InputTooLarge;
            if (count > self.capacity) return error.CapacityExceeded;
            if (self.indexes.len == 0) try self.reserve(0);

            const sentinel: u32 = @intCast(input_len);
            self.indexes[count..][0..sentinel_count].* = .{
                sentinel,
                sentinel,
                0,
            };
            self.count = count;
        }

        /// Releases every array the buffer allocated and leaves it unusable.
        ///
        /// The `allocator` is not released, and arrays that were never
        /// allocated are skipped, so a fresh buffer and a fully grown one both
        /// release once. Exactly one call per buffer: the value is left
        /// undefined, so a second call, or a second `deinit` reached through a
        /// copy, frees the same arrays twice. No document, cursor, or reader
        /// may still be reading these arrays when it runs.
        pub fn deinit(self: *Self) void {
            if (self.indexes.len != 0) self.allocator.free(self.indexes);
            if (comptime Kind != void) {
                if (self.kinds.len != 0) self.allocator.free(self.kinds);
            }
            if (with_lengths) {
                if (self.lengths.len != 0) self.allocator.free(self.lengths);
            }
            self.* = undefined;
        }

        fn checkAllocationSize(
            comptime T: type,
            count: usize,
        ) error{CapacityOverflow}!void {
            _ = std.math.mul(usize, count, @sizeOf(T)) catch {
                return error.CapacityOverflow;
            };
        }
    };
}

test "resident lease rejects active, released, and stale copies" {
    var state: State = .{};
    defer state.deinit();

    const first = try state.begin();
    try first.check();
    try testing.expectError(error.DocumentActive, state.begin());

    const stale = first;
    first.release();
    try testing.expectError(error.DocumentReleased, stale.check());

    const second = try state.begin();
    try testing.expect(second.generation != first.generation);
    stale.release();
    try second.check();
    try testing.expect(state.active);

    second.release();
    try testing.expect(!state.active);
}

test "resident generation wraps to a nonzero value" {
    var state: State = .{ .generation = std.math.maxInt(u64) };
    defer state.deinit();

    const lease = try state.begin();
    try testing.expectEqual(@as(u64, 1), lease.generation);
    try testing.expectEqual(@as(u64, 1), state.generation);
    lease.release();
}

test "resident guard enforces one focus and ordered copies" {
    var state: State = .{};
    defer state.deinit();

    const lease = try state.begin();
    defer lease.release();

    var guard = try lease.claim();
    try testing.expectError(error.FocusAlreadyClaimed, lease.claim());

    var copied_guard = guard;
    try guard.check();
    try guard.advance();
    try testing.expectEqual(@as(usize, 1), state.position);
    try testing.expectEqual(@as(usize, 1), guard.expected_position);
    try testing.expectError(error.OutOfOrderIteration, copied_guard.check());
    try testing.expectError(error.OutOfOrderIteration, copied_guard.advance());
}

test "resident guard reports release before stale position" {
    var state: State = .{};
    defer state.deinit();

    const lease = try state.begin();
    var guard = try lease.claim();
    var stale_guard = guard;
    try guard.advance();
    lease.release();

    try testing.expectError(error.DocumentReleased, stale_guard.check());
    try testing.expectError(error.DocumentReleased, stale_guard.advance());
}

test "resident guard position cannot wrap" {
    var state: State = .{};
    defer state.deinit();

    const lease = try state.begin();
    defer lease.release();
    state.position = std.math.maxInt(usize);
    var guard = try lease.claim();

    try testing.expectError(error.OutOfOrderIteration, guard.advance());
    try testing.expectEqual(std.math.maxInt(usize), state.position);
    try testing.expectEqual(std.math.maxInt(usize), guard.expected_position);
}

const TestKind = enum(u8) {
    first,
    second,
};

test "IndexBuffer keeps optional storage absent" {
    var buffer = IndexBuffer(void, false).init(testing.allocator);
    defer buffer.deinit();

    try testing.expectEqual(@as(usize, 0), buffer.indexes.len);
    try testing.expectEqual(@as(usize, 0), buffer.kinds.len);
    try testing.expectEqual(@as(usize, 0), buffer.lengths.len);
    try testing.expectEqual(@as(usize, 0), buffer.capacity);
    try testing.expectEqual(@as(usize, 0), buffer.count);

    try buffer.reserve(0);
    try buffer.finish(0, 0);
    try testing.expectEqual(@as(usize, sentinel_count), buffer.indexes.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, buffer.indexes);
}

test "IndexBuffer preserves initialized parallel prefixes" {
    var buffer = IndexBuffer(TestKind, true).init(testing.allocator);
    defer buffer.deinit();

    try buffer.reserve(2);
    buffer.indexes[0..2].* = .{ 3, 11 };
    buffer.kinds[0..2].* = .{ .first, .second };
    buffer.lengths[0..2].* = .{ 4, 7 };
    buffer.count = 2;
    try buffer.finish(2, 18);

    try buffer.reserve(8);
    try testing.expectEqual(@as(usize, 8), buffer.capacity);
    try testing.expectEqual(@as(usize, 11), buffer.indexes.len);
    try testing.expectEqual(@as(usize, 8), buffer.kinds.len);
    try testing.expectEqual(@as(usize, 8), buffer.lengths.len);
    try testing.expectEqualSlices(u32, &.{ 3, 11 }, buffer.indexes[0..2]);
    try testing.expectEqualSlices(TestKind, &.{ .first, .second }, buffer.kinds[0..2]);
    try testing.expectEqualSlices(u32, &.{ 4, 7 }, buffer.lengths[0..2]);

    try buffer.finish(2, 18);
    try testing.expectEqualSlices(u32, &.{ 18, 18, 0 }, buffer.indexes[2..5]);

    const indexes_pointer = buffer.indexes.ptr;
    try buffer.reserve(3);
    try testing.expectEqual(indexes_pointer, buffer.indexes.ptr);
    try testing.expectEqual(@as(usize, 8), buffer.capacity);
}

fn checkIndexBufferAllocationFailure(allocator: std.mem.Allocator) !void {
    var buffer = IndexBuffer(TestKind, true).init(allocator);
    defer buffer.deinit();

    try buffer.reserve(2);
    buffer.indexes[0..2].* = .{ 5, 9 };
    buffer.kinds[0..2].* = .{ .first, .second };
    buffer.lengths[0..2].* = .{ 2, 4 };
    buffer.count = 2;

    const indexes_pointer = buffer.indexes.ptr;
    const kinds_pointer = buffer.kinds.ptr;
    const lengths_pointer = buffer.lengths.ptr;
    buffer.reserve(8) catch |err| {
        try testing.expectEqual(indexes_pointer, buffer.indexes.ptr);
        try testing.expectEqual(kinds_pointer, buffer.kinds.ptr);
        try testing.expectEqual(lengths_pointer, buffer.lengths.ptr);
        try testing.expectEqual(@as(usize, 2), buffer.capacity);
        try testing.expectEqual(@as(usize, 2), buffer.count);
        try testing.expectEqualSlices(u32, &.{ 5, 9 }, buffer.indexes[0..2]);
        try testing.expectEqualSlices(TestKind, &.{ .first, .second }, buffer.kinds[0..2]);
        try testing.expectEqualSlices(u32, &.{ 2, 4 }, buffer.lengths[0..2]);
        return err;
    };
}

test "IndexBuffer reserve is transactional across allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkIndexBufferAllocationFailure,
        .{},
    );
}

test "IndexBuffer rejects invalid capacities and offsets" {
    var buffer = IndexBuffer(void, false).init(testing.allocator);
    defer buffer.deinit();

    try testing.expectError(
        error.CapacityOverflow,
        buffer.reserve(std.math.maxInt(usize)),
    );

    const allocation_overflow = std.math.maxInt(usize) / @sizeOf(u32) + 1;
    try testing.expectError(
        error.CapacityOverflow,
        buffer.reserve(allocation_overflow),
    );

    try buffer.reserve(1);
    buffer.indexes[0] = 7;
    buffer.count = 1;
    try buffer.finish(1, std.math.maxInt(u32));
    try testing.expectEqualSlices(
        u32,
        &.{ std.math.maxInt(u32), std.math.maxInt(u32), 0 },
        buffer.indexes[1..4],
    );
    try testing.expectError(error.CapacityExceeded, buffer.finish(2, 8));

    if (@bitSizeOf(usize) > @bitSizeOf(u32)) {
        try testing.expectError(
            error.InputTooLarge,
            buffer.finish(1, @as(usize, std.math.maxInt(u32)) + 1),
        );
    }
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}
