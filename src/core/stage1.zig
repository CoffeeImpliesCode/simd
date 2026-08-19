const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const StructuralIndex = struct {
    indexes: []u32,
    count: usize,

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) !StructuralIndex {
        const memory = try allocator.alloc(u32, max_capacity);
        return .{
            .indexes = memory,
            .count = 0,
        };
    }

    pub fn deinit(self: *StructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        self.* = undefined;
    }

    pub fn slice(self: *const StructuralIndex) []const u32 {
        return self.indexes[0..self.count];
    }
};

test "StructuralIndex lifecycle" {
    var idx = try StructuralIndex.init(testing.allocator, 16);
    defer idx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), idx.count);
    try testing.expectEqual(@as(usize, 16), idx.indexes.len);
}
