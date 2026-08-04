const std = @import("std");

const hdf5 = @cImport({
    @cInclude("hdf5lib.h");
});

const metro = @import("metro.zig");

pub const File = struct {
    id: hdf5.hid_t,
    lcpl: hdf5.hid_t,

    pub fn create(path: [:0]const u8) !File {
        // Create the file
        const id = hdf5.H5Fcreate(path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (id < 0) return error.H5I_INVALID_HID;

        // Create link creation property list for dataset creation
        const lcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
        if (lcpl < 0) return error.H5I_INVALID_HID;

        // Enable creation of intermediate groups as needed
        if (hdf5.H5Pset_create_intermediate_group(lcpl, 1) < 0) return error.H5I_INVALID_HID;

        return .{ .id = id, .lcpl = lcpl };
    }

    pub fn openRoot(self: *@This()) !Group {
        if (self.id < 0) return error.FileNotOpen;
        return try .open(self.id, "/");
    }

    pub fn getSize(self: *@This()) !u64 {
        if (self.id < 0) return error.H5I_INVALID_HID;
        var size: hdf5.hsize_t = 0;
        if (hdf5.H5Fget_filesize(self.id, @ptrCast(&size)) < 0) return error.H5Fget_filesizeError;
        return size;
    }

    pub fn createLink(self: *@This(), scan_idx: usize, step_idx: usize, step_val: []const u8) !void {
        // Format target path for the link
        var target_buf: [1024]u8 = undefined;
        const target = try std.fmt.bufPrintSentinel(&target_buf, "{d}/by_idx/{d}", .{ scan_idx, step_idx }, 0);

        // Format link path using the step value
        var link_buf: [1024]u8 = undefined;
        const link = try std.fmt.bufPrintSentinel(&link_buf, "{d}/{s}", .{ scan_idx, step_val }, 0);

        // Check if the link already exists
        if (hdf5.H5Lexists(self.id, link.ptr, hdf5.H5P_DEFAULT) > 0) return;

        // Create the link
        if (hdf5.H5Lcreate_hard(self.id, target.ptr, self.id, link.ptr, self.lcpl, hdf5.H5P_DEFAULT) < 0) return error.H5LcreateFailed;
    }

    pub fn close(self: *@This()) void {
        if (self.id >= 0) {
            if (hdf5.H5Fclose(self.id) >= 0) self.id = -1;
        }
        if (self.lcpl >= 0) {
            if (hdf5.H5Pclose(self.lcpl) >= 0) self.lcpl = -1;
        }
    }
};

pub const Group = struct {
    id: hdf5.hid_t,

    pub fn open(file_id: hdf5.hid_t, path: [:0]const u8) !Group {
        const id = hdf5.H5Gopen2(file_id, path, hdf5.H5P_DEFAULT);
        if (id < 0) return error.H5I_INVALID_HID;
        return .{ .id = id };
    }

    pub fn close(self: *@This()) void {
        if (self.id < 0) return;
        if (hdf5.H5Gclose(self.id) >= 0) self.id = -1;
    }
};

pub fn SimpleDset(comptime T: type) type {
    return struct {
        shape: usize,
        name: []const u8,

        const Self = @This();

        fn create(
            file_id: hdf5.hid_t,
            name: [:0]const u8,
            space: hdf5.hid_t,
            lcpl: hdf5.hid_t,
            dcpl: hdf5.hid_t,
        ) !hdf5.hid_t {
            // Get the H5 data type
            const type_id = getH5T(T);
            // Default dataset access property list
            const dapl = hdf5.H5P_DEFAULT;
            // Create the dataset
            const dset = hdf5.H5Dcreate2(file_id, name, type_id, space, lcpl, dcpl, dapl);
            if (dset < 0) return error.H5I_INVALID_HID;
            return dset;
        }

        pub fn write(
            self: *@This(),
            file: *File,
            data: []const T,
            scan_idx: usize,
            step_idx: usize,
            step_val: ?[]const u8,
            attrs: *AttrList,
        ) !void {
            // Fail if the file is not open
            if (file.id < 0) return error.FileNotOpen;

            // Create dataset properties
            const dcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
            if (dcpl < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(dcpl);

            // Create a dataspace
            var fspace: hdf5.hid_t = undefined;
            if (self.shape == 0) {
                fspace = hdf5.H5Screate_simple(1, &[1]hdf5.hsize_t{@intCast(data.len)}, null);
            } else {
                if (data.len % self.shape != 0) return error.InvalidShape;
                const rows = @divExact(data.len, self.shape);
                fspace = hdf5.H5Screate_simple(2, &[2]hdf5.hsize_t{ @intCast(rows), @intCast(self.shape) }, null);
            }
            if (fspace < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(fspace);

            // Format path to dataset
            var buf: [1024]u8 = undefined;
            const name = try std.fmt.bufPrintSentinel(&buf, "{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, self.name }, 0);

            // Create the dataset
            const dset = try create(file.id, name, fspace, file.lcpl, dcpl);
            defer _ = hdf5.H5Dclose(dset);

            // Write attributes but don't error if it fails
            attrs.write(dset) catch {};

            // Write the dataset
            // Get the H5 data type
            const type_id = getH5T(T);
            // Use file dataspace for the memory dataspace
            const mem_space = hdf5.H5S_ALL;
            // Selection in dataspace is set to "all"
            const file_space = hdf5.H5S_ALL;
            // Default transfer properties
            const dxpl = hdf5.H5P_DEFAULT;
            if (hdf5.H5Dwrite(dset, type_id, mem_space, file_space, dxpl, data.ptr) < 0) {
                return error.H5DwriteFailed;
            }

            // Create a link for accessing the dataset using the step value
            if (step_val != null) file.createLink(scan_idx, step_idx, step_val.?) catch {};
        }
    };
}

pub const AttrList = struct {
    attrs: std.ArrayList(Attr),
    allocator: std.mem.Allocator,
    type_id: hdf5.hid_t,
    fspace: hdf5.hid_t,

    const Attr = struct {
        name: [:0]const u8,
        value: [:0]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !AttrList {
        // Create the hdf5 type
        const type_id = hdf5.H5Tcopy(hdf5.ZIG_H5T_C_S1());
        if (type_id < 0) return error.H5I_INVALID_HID;
        errdefer _ = hdf5.H5Tclose(type_id);

        if (hdf5.H5Tset_size(type_id, hdf5.H5T_VARIABLE) < 0) return error.H5I_INVALID_HID;
        if (hdf5.H5Tset_cset(type_id, hdf5.H5T_CSET_UTF8) < 0) return error.H5I_INVALID_HID;
        if (hdf5.H5Tset_strpad(type_id, hdf5.H5T_STR_NULLTERM) < 0) return error.H5I_INVALID_HID;

        // Create dataspace for the attribute
        const fspace = hdf5.H5Screate(hdf5.H5S_SCALAR);
        if (fspace < 0) return error.H5I_INVALID_HID;

        return .{ .attrs = .empty, .allocator = allocator, .type_id = type_id, .fspace = fspace };
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

        for (self.attrs.items) |*attr| {
            const cptr: [*c]const u8 = attr.value.ptr;
            const buf: ?*const anyopaque = @ptrCast(&cptr);

            // Overwrite if attribute already exists
            if (hdf5.H5Aexists(obj, attr.name.ptr) > 0) {
                const attr_id = hdf5.H5Aopen(obj, attr.name.ptr, hdf5.H5P_DEFAULT);
                if (attr_id < 0) return error.H5I_INVALID_HID;
                defer _ = hdf5.H5Aclose(attr_id);

                // Write attribute
                if (hdf5.H5Awrite(attr_id, self.type_id, buf) < 0) return error.H5AwriteError;
                return;
            }

            // Create attribute
            const attr_id = hdf5.H5Acreate2(obj, attr.name.ptr, self.type_id, self.fspace, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
            if (attr_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Aclose(attr_id);

            // Write attribute
            if (hdf5.H5Awrite(attr_id, self.type_id, buf) < 0) return error.H5AwriteError;
        }
    }

    pub fn deinit(self: *@This()) void {
        // Close HDF5 objects
        if (self.type_id >= 0) _ = hdf5.H5Tclose(self.type_id);
        if (self.fspace >= 0) _ = hdf5.H5Sclose(self.fspace);

        // Free name and value strings
        for (self.attrs.items) |*attr| {
            self.allocator.free(attr.name);
            self.allocator.free(attr.value);
        }
        self.attrs.deinit(self.allocator);
    }
};

fn getH5T(comptime T: type) hdf5.hid_t {
    return switch (T) {
        u8 => hdf5.ZIG_H5T_NATIVE_UCHAR(),
        u16 => hdf5.ZIG_H5T_NATIVE_USHORT(),
        u32 => hdf5.ZIG_H5T_NATIVE_UINT(),
        i8 => hdf5.ZIG_H5T_NATIVE_SCHAR(),
        i32 => hdf5.ZIG_H5T_NATIVE_INT(),
        i64 => hdf5.ZIG_H5T_NATIVE_LLONG(),
        f64 => hdf5.ZIG_H5T_IEEE_F64LE(),
        [2]u8 => blk: {
            const type_id = hdf5.H5Tcopy(hdf5.ZIG_H5T_C_S1());
            _ = hdf5.H5Tset_size(type_id, 2);
            _ = hdf5.H5Tset_cset(type_id, hdf5.H5T_CSET_UTF8);
            break :blk type_id;
        },
        else => @compileError("No defined H5T for: " ++ @typeName(T)),
    };
}
