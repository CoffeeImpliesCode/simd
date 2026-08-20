const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const StructuralIndex = struct {
    const sentinel_count = 3;

    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };
    pub const FinishError = error{InputTooLarge};

    indexes: []u32,
    count: usize,

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

    pub fn deinit(self: *StructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        self.* = undefined;
    }

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

    if (@bitSizeOf(usize) > @bitSizeOf(u32)) {
        try testing.expectError(
            error.InputTooLarge,
            StructuralIndex.init(
                testing.allocator,
                @as(usize, std.math.maxInt(u32)) + 1,
            ),
        );
    }

    var idx = try StructuralIndex.init(testing.allocator, 1);
    defer idx.deinit(testing.allocator);
    try testing.expectError(
        error.InputTooLarge,
        idx.finish(@as(usize, std.math.maxInt(u32)) + 1),
    );
}
