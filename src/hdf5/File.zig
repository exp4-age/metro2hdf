const File = @This();

const std = @import("std");
const hdf5 = @import("libhdf5");
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

pub fn createLink(self: *@This(), target: [:0]const u8, link: [:0]const u8) !void {
    if (self.id < 0) return LinkError.FileNotOpen;

    // Check if the link already exists
    if (hdf5.H5Lexists(self.id, link.ptr, hdf5.H5P_DEFAULT) > 0) return;

    // Create link creation property list for creation of intermediate groups
    const lcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
    if (lcpl < 0) return error.H5I_INVALID_HID;
    defer _ = hdf5.H5Pclose(lcpl);
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
