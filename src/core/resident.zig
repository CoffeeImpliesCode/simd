const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const sentinel_count: usize = 3;

pub const Error = error{
    DocumentActive,
    DocumentReleased,
    FocusAlreadyClaimed,
    OutOfOrderIteration,
};

pub const State = struct {
    generation: u64 = 0,
    active: bool = false,
    claimed: bool = false,
    position: usize = 0,

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

    pub fn deinit(self: *State) void {
        assert(!self.active);
        self.* = undefined;
    }
};

pub const Lease = struct {
    state: *State,
    generation: u64,

    pub fn check(self: Lease) Error!void {
        if (!self.state.active) return error.DocumentReleased;
        if (self.state.generation != self.generation) return error.DocumentReleased;
    }

    pub fn release(self: Lease) void {
        if (!self.state.active) return;
        if (self.state.generation != self.generation) return;

        self.state.active = false;
        self.state.claimed = false;
    }

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

pub const Guard = struct {
    lease: Lease,
    expected_position: usize,

    pub fn check(self: *const Guard) Error!void {
        try self.lease.check();
        if (self.lease.state.position != self.expected_position) {
            return error.OutOfOrderIteration;
        }
    }

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

pub fn IndexBuffer(comptime Kind: type, comptime with_lengths: bool) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        indexes: []u32,
        kinds: []Kind,
        lengths: []u32,
        capacity: usize,
        count: usize,

        pub const ReserveError = std.mem.Allocator.Error || error{CapacityOverflow};
        pub const FinishError = ReserveError || error{
            CapacityExceeded,
            InputTooLarge,
        };

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
