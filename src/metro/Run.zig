const Run = @This();

const std = @import("std");
const Channel = @import("Channel.zig");
const hdf5 = @import("../hdf5.zig");

num: []const u8,
name: []const u8,
date: []const u8,
time: []const u8,
channels: std.ArrayList(Channel) = .empty,

pub fn addChannel(
    self: *@This(),
    allocator: std.mem.Allocator,
    channel: Channel,
) !void {
    try self.channels.append(allocator, channel);
}

pub fn writeAttrs(self: *@This(), h5f: *hdf5.File, allocator: std.mem.Allocator) !void {
    var h5a = try hdf5.AttrList.init(allocator);
    defer h5a.deinit();

    // Measurement run number
    try h5a.append("number", self.num);

    // Measurement name
    try h5a.append("name", self.name);

    var buf: [10]u8 = undefined;

    // Format and append the date
    const date = try std.fmt.bufPrint(&buf, "{s}-{s}-{s}", .{ self.date[0..2], self.date[2..4], self.date[4..8] });
    try h5a.append("date", date);

    // Format and append the time
    const time = try std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ self.time[0..2], self.time[2..4], self.time[4..6] });
    try h5a.append("time", time);

    // Write the attributes to the root group
    var root = try h5f.openRoot();
    defer root.close();

    try h5a.write(root.id);
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.channels.deinit(allocator);
}
