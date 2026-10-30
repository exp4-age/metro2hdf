const StepTable = @This();

const std = @import("std");

steps: std.ArrayList(StepEntry) = .empty,
allocator: std.mem.Allocator,

pub const StepEntry = struct {
    value: ?[:0]const u8,
    data_offset: i64,
    data_size: i64,
};

pub fn append(
    self: *@This(),
    step_val: ?[]const u8,
    data_offset: i64,
    data_size: i64,
) !void {
    if (step_val) |val| {
        const value = try self.allocator.dupeSentinel(u8, std.mem.trim(u8, val, &.{0}), 0);
        errdefer self.allocator.free(value);
        try self.steps.append(
            self.allocator,
            .{
                .value = value,
                .data_offset = data_offset,
                .data_size = data_size,
            },
        );
    } else {
        try self.steps.append(
            self.allocator,
            .{
                .value = null,
                .data_offset = data_offset,
                .data_size = data_size,
            },
        );
    }
}

pub fn deinit(self: *@This()) void {
    for (self.steps.items) |*step| {
        if (step.value != null) self.allocator.free(step.value.?);
    }
    self.steps.deinit(self.allocator);
}
