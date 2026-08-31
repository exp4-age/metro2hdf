const File = @This();

const std = @import("std");
const hdf5 = @cImport({
    @cInclude("hdf5/hdf5lib.h");
});
const SimpleDset = @import("simple_dset.zig").SimpleDset;
const ChunkedDset = @import("chunked_dset.zig").ChunkedDset;
const Group = @import("Group.zig");


id: hdf5.hid_t = -1,

pub const OpenError = error{
    H5I_INVALID_HID,
};

pub const StatError = error{
    FileNotOpen,
    BrokenPipe,
};

pub const LinkError = error{
    FileNotOpen,
    H5I_INVALID_HID,
    CreateFailed,
};

pub fn create(path: [:0]const u8) OpenError!File {
    const id = hdf5.H5Fcreate(path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
    if (id < 0) return OpenError.H5I_INVALID_HID;
    return .{ .id = id };
}

pub fn getSize(self: @This()) StatError!u64 {
    if (self.id < 0) return StatError.FileNotOpen;
    var size: hdf5.hsize_t = 0;
    if (hdf5.H5Fget_filesize(self.id, @ptrCast(&size)) < 0) return StatError.BrokenPipe;
    return size;
}

pub fn close(self: *@This()) void {
    if (self.id >= 0) {
        if (hdf5.H5Fclose(self.id) >= 0) self.id = -1;
    }
}

pub fn createLink(self: *@This(), scan_idx: usize, step_idx: usize, step_val: []const u8) !void {
    if (self.id < 0) return LinkError.FileNotOpen;

    // Format target path for the link
    var target_buf: [1024]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{d}/by_idx/{d}", .{ scan_idx, step_idx }, 0);

    // Format link path using the step value
    var link_buf: [1024]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_buf, "{d}/{s}", .{ scan_idx, step_val }, 0);

    // Check if the link already exists
    if (hdf5.H5Lexists(self.id, link.ptr, hdf5.H5P_DEFAULT) > 0) return;

    // Create link creation property list for creation of intermediate groups
    const lcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
    if (lcpl < 0) return error.H5I_INVALID_HID;
    if (hdf5.H5Pset_create_intermediate_group(lcpl, 1) < 0) return LinkError.H5I_INVALID_HID;

    // Create the link
    if (hdf5.H5Lcreate_hard(self.id, target.ptr, self.id, link.ptr, lcpl, hdf5.H5P_DEFAULT) < 0) return LinkError.CreateFailed;
}

pub fn openGroup(self: @This(), path: [:0]const u8) !Group {
    if (self.id < 0) return error.FileNotOpen;
    const group_id = hdf5.H5Gopen2(self.id, path, hdf5.H5P_DEFAULT);
    if (group_id < 0) return error.H5I_INVALID_HID;
    return .{ .id = group_id };
}

pub fn openRoot(self: @This()) !Group {
    return try self.openGroup("/");
}

pub fn writeSimpleDset(
    self: File,
    comptime T: type,
    buffer: []T,
    scan_idx: usize,
    step_idx: usize,
    name: []const u8,
    shape: usize
) !SimpleDset(T) {
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, name }, 0);
    return try .write(self.id, path, shape, buffer);
}

pub fn createChunkedDset(
    self: File,
    comptime T: type,
    buffer: []T,
    scan_idx: usize,
    step_idx: usize,
    name: []const u8,
    shape: usize
) !ChunkedDset(T) {
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, name }, 0);
    return try .create(self.id, path, shape, buffer);
}
