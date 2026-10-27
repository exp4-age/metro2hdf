const AttrList = @This();

const std = @import("std");
const hdf5 = @import("libhdf5");

attrs: std.ArrayList(Attribute) = .empty,
allocator: std.mem.Allocator,

const Attribute = struct {
    name: [:0]const u8,
    value: [:0]const u8,
};

pub fn init(allocator: std.mem.Allocator) !AttrList {
    return .{ .allocator = allocator };
}

pub fn append(self: *@This(), name: []const u8, value: []const u8) !void {
    // Copy the strings and terminate them because this gets passed to hdf5
    const cname = try self.allocator.dupeSentinel(u8, name, 0);
    errdefer self.allocator.free(cname);

    const cvalue = try self.allocator.dupeSentinel(u8, value, 0);
    errdefer self.allocator.free(cvalue);

    try self.attrs.append(self.allocator, .{ .name = cname, .value = cvalue });
}

pub fn write(self: *@This(), obj: hdf5.hid_t) !void {
    if (obj < 0) return error.H5I_INVALID_HID;

    // Create the hdf5 type
    const type_id = hdf5.H5Tcopy(hdf5.ZIG_H5T_C_S1());
    if (type_id < 0) return error.H5I_INVALID_HID;
    defer _ = hdf5.H5Tclose(type_id);
    if (hdf5.H5Tset_size(type_id, hdf5.H5T_VARIABLE) < 0) return error.H5I_INVALID_HID;
    if (hdf5.H5Tset_cset(type_id, hdf5.H5T_CSET_UTF8) < 0) return error.H5I_INVALID_HID;
    if (hdf5.H5Tset_strpad(type_id, hdf5.H5T_STR_NULLTERM) < 0) return error.H5I_INVALID_HID;

    // Create dataspace for the attributes
    const space_id = hdf5.H5Screate(hdf5.H5S_SCALAR);
    if (space_id < 0) return error.H5I_INVALID_HID;
    defer _ = hdf5.H5Sclose(space_id);

    for (self.attrs.items) |*attr| {
        const cptr: [*c]const u8 = attr.value.ptr;
        const buf: ?*const anyopaque = @ptrCast(&cptr);

        // Overwrite if attribute already exists
        if (hdf5.H5Aexists(obj, attr.name.ptr) > 0) {
            const attr_id = hdf5.H5Aopen(obj, attr.name.ptr, hdf5.H5P_DEFAULT);
            if (attr_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Aclose(attr_id);

            // Write attribute
            if (hdf5.H5Awrite(attr_id, type_id, buf) < 0) return error.H5AwriteError;
            continue;
        }

        // Create attribute
        const attr_id = hdf5.H5Acreate2(obj, attr.name.ptr, type_id, space_id, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (attr_id < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Aclose(attr_id);

        // Write attribute
        if (hdf5.H5Awrite(attr_id, type_id, buf) < 0) return error.H5AwriteError;
    }
}

pub fn deinit(self: *@This()) void {
    // Free name and value strings
    for (self.attrs.items) |*attr| {
        self.allocator.free(attr.name);
        self.allocator.free(attr.value);
    }
    self.attrs.deinit(self.allocator);
}
