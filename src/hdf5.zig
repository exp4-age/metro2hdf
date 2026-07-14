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
        const id = hdf5.H5Fcreate(
            path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT
        );
        if (id < 0) return error.H5I_INVALID_HID;

        // Create link creation property list for dataset creation
        const lcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
        if (lcpl < 0) return error.H5I_INVALID_HID;

        // Enable creation of intermediate groups as needed
        if (hdf5.H5Pset_create_intermediate_group(lcpl, 1) < 0) return error.H5I_INVALID_HID;

        return .{.id=id, .lcpl=lcpl};
    }

    pub fn close(self: *@This()) void {
        if (self.id >= 0) {
            _ = hdf5.H5Fclose(self.id);
            self.id = -1;
        }
        if (self.lcpl >= 0) {
            _ = hdf5.H5Pclose(self.lcpl);
            self.lcpl = -1;
        }
    }

    pub fn writeSimpleDset(
        self: *@This(),
        comptime T: type,
        data: []const T,
        shape: usize,
        scan_idx: []const u8,
        step_val: []const u8,
        channel: []const u8,
        attrs: []StrAttr,
        options: metro.Options,
    ) !void {
        // Fail if the file is not open
        if (self.id < 0) return error.FileNotOpen;

        // Create dataset properties
        const dcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
        if (dcpl < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Pclose(dcpl);

        // Create a dataspace
        var fspace: hdf5.hid_t = undefined;
        if (shape == 0) {
            fspace = hdf5.H5Screate_simple(1, &[1]hdf5.hsize_t{@intCast(data.len)}, null);
        } else {
            if (data.len % shape != 0) return error.InvalidShape;
            const rows = @divExact(data.len, shape);
            fspace = hdf5.H5Screate_simple(
                2, &[2]hdf5.hsize_t{@intCast(rows), @intCast(shape)}, null);

            // Make 2d data column major by writing it in chunks
            const chunk = [2]hdf5.hsize_t{rows, 1};
            if (hdf5.H5Pset_chunk(dcpl, 2, &chunk) < 0) return error.H5I_INVALID_HID;
        }
        if (fspace < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(fspace);

        // Define the datatype
        const type_id = getH5T(T);

        // Format path to dataset
        var buf: [1024]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(
            &buf, "{s}/{s}/{s}", .{scan_idx, step_val, channel}, 0);

        // Create the dataset
        const dset = hdf5.H5Dcreate2(
            self.id, name, type_id, fspace, self.lcpl, dcpl, hdf5.H5P_DEFAULT);
        if (dset < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Dclose(dset);

        // Write attributes
        for (attrs) |*attr| {
            try attr.write(dset);
        }

        // Write the dataset
        if (hdf5.H5Dwrite(dset, type_id, hdf5.H5S_ALL, hdf5.H5S_ALL, hdf5.H5P_DEFAULT, data.ptr) < 0) {
            return error.H5DWriteFailed;
        }

        _ = &options;
    }

    pub fn writeCompoundDset(
        self: *@This(),
        comptime T: type,
        data: []const T,
        scan_idx: []const u8,
        step_val: []const u8,
        channel: []const u8,
        attrs: []StrAttr,
        options: metro.Options,
    ) !void {
        if (self.id < 0) return error.FileNotOpen;

        // Compile error if T has no fields
        if (@sizeOf(T) == 0) @compileError("Zero-sized structs are not supported");

        // Createa 1d dataspace
        const dims = [1]hdf5.hsize_t{@intCast(data.len)};
        const fspace = hdf5.H5Screate_simple(1, &dims, null);
        if (fspace < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(fspace);

        const dcpl = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
        if (dcpl < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Pclose(dcpl);

        const chunk_size: hdf5.hsize_t = @intCast(@divFloor(options.chunk_size, @sizeOf(T)));
        if (data.len > chunk_size) {
            const chunk = [1]hdf5.hsize_t{chunk_size};
            if (hdf5.H5Pset_chunk(dcpl, 1, &chunk) < 0) return error.H5I_INVALID_HID;
            if (hdf5.H5Pset_deflate(dcpl, @intCast(options.compress)) < 0) return error.H5I_INVALID_HID;
        }

        // Create the compound datatype for T
        const type_id = try createCompoundType(T);
        if (type_id < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Tclose(type_id);

        // Format path to dataset
        var buf: [1024]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(
            &buf, "{s}/{s}/{s}", .{scan_idx, step_val, channel}, 0);

        // Create the dataset
        const dset = hdf5.H5Dcreate2(
            self.id, name, type_id, fspace, self.lcpl, dcpl, hdf5.H5P_DEFAULT);
        if (dset < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Dclose(dset);

        // Write attributes
        for (attrs) |*attr| {
            try attr.write(dset);
        }

        // Write the dataset
        if (hdf5.H5Dwrite(dset, type_id, hdf5.H5S_ALL, hdf5.H5S_ALL, hdf5.H5P_DEFAULT, data.ptr) < 0) {
            return error.WriteFailed;
        }
    }

    pub fn writeRootAttrs(self: *@This(), run: metro.Run) !void {
        // Open the root group
        const root = hdf5.H5Gopen2(self.id, "/", hdf5.H5P_DEFAULT);
        if (root < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Gclose(root);

        var buf: [1024]u8 = undefined;

        // Write measurement number
        const num = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.num}, 0);
        var num_attr = try StrAttr.init("number", num);
        defer num_attr.deinit();
        try num_attr.write(root);

        // Write name
        const name = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.name}, 0);
        var name_attr = try StrAttr.init("name", name);
        defer name_attr.deinit();
        try name_attr.write(root);

        // Write date
        const date = try std.fmt.bufPrintSentinel(&buf, "{s}-{s}-{s}", .{run.date[0..2], run.date[2..4], run.date[4..8]}, 0);
        var date_attr = try StrAttr.init("date", date);
        defer date_attr.deinit();
        try date_attr.write(root);

        // Write time
        const time = try std.fmt.bufPrintSentinel(&buf, "{s}:{s}:{s}", .{run.time[0..2], run.time[2..4], run.time[4..6]}, 0);
        var time_attr = try StrAttr.init("time", time);
        defer time_attr.deinit();
        try time_attr.write(root);
    }
};

pub const StrAttr = struct {
    name: [:0]const u8,
    value: [:0]const u8,
    type_id: hdf5.hid_t,
    fspace: hdf5.hid_t,

    pub fn init(name: [:0]const u8, value: [:0]const u8) !StrAttr {
        // Create the hdf5 type
        const type_id = hdf5.H5Tcopy(hdf5.ZIG_H5T_C_S1());
        if (type_id < 0) return error.H5I_INVALID_HID;
        if (hdf5.H5Tset_size(type_id, hdf5.H5T_VARIABLE) < 0) return error.H5Error;
        if (hdf5.H5Tset_cset(type_id, hdf5.H5T_CSET_UTF8) < 0) return error.H5Error;
        if (hdf5.H5Tset_strpad(type_id, hdf5.H5T_STR_NULLTERM) < 0) return error.H5Error;

        // Create dataspace for the attribute
        const fspace = hdf5.H5Screate(hdf5.H5S_SCALAR);
        if (fspace < 0) return error.H5I_INVALID_HID;

        return .{.name=name, .value=value, .type_id=type_id, .fspace=fspace};
    }

    pub fn write(self: *@This(), obj: hdf5.hid_t) !void {
        if (obj < 0) return error.H5I_INVALID_HID;

        const cptr: [*c]const u8 = self.value.ptr;
        const buf: ?*const anyopaque = @ptrCast(&cptr);

        // Overwrite if attribute already exists
        if (hdf5.H5Aexists(obj, self.name.ptr) > 0) {
            const attr = hdf5.H5Aopen(obj, self.name.ptr, hdf5.H5P_DEFAULT);
            if (attr < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Aclose(attr);

            // Write attribute
            if (hdf5.H5Awrite(attr, self.type_id, buf) < 0) return error.H5Error;
            return;
        }

        // Create attribute
        const attr = hdf5.H5Acreate2(
            obj, self.name.ptr, self.type_id, self.fspace, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (attr < 0) return error.H5I_INVALID_HID;
        defer _ = hdf5.H5Aclose(attr);

        // Write attribute
        if (hdf5.H5Awrite(attr, self.type_id, buf) < 0) return error.H5Error;
    }

    pub fn deinit(self: *@This()) void {
        if (self.type_id >= 0) _ = hdf5.H5Tclose(self.type_id);
        self.type_id = -1;
        if (self.fspace >= 0) _ = hdf5.H5Sclose(self.fspace);
        self.fspace = -1;
    }
};

fn getH5T(comptime T: type) hdf5.hid_t {
    return switch (T) {
        u8 => hdf5.ZIG_H5T_NATIVE_UCHAR(),
        u16 => hdf5.ZIG_H5T_NATIVE_USHORT(),
        u32 => hdf5.ZIG_H5T_NATIVE_UINT(),
        i32 => hdf5.ZIG_H5T_NATIVE_INT(),
        i64 => hdf5.ZIG_H5T_NATIVE_LLONG(),
        f64 => hdf5.ZIG_H5T_IEEE_F64LE(),
        else => @compileError("No known H5T for: " ++ @typeName(T)),
    };
}

fn createCompoundType(comptime T: type) !hdf5.hid_t {
    const ti = @typeInfo(T);
    if (ti != .@"struct") {
        @compileError("T must be a struct");
    }

    // Create the H5T compound type
    const type_id = hdf5.H5Tcreate(hdf5.H5T_COMPOUND, @sizeOf(T));
    if (type_id < 0) return error.H5I_INVALID_HID;
    errdefer _ = hdf5.H5Tclose(type_id);

    // Insert corresponding type for each field of T
    inline for (ti.@"struct".fields) |f| {
        // Look up H5T type corresponding to the zig type
        const f_type = getH5T(f.type);

        // Add null termination
        const cname = f.name ++ "\x00";

        // Try to insert the type
        if (hdf5.H5Tinsert(type_id, cname.ptr, @offsetOf(T, f.name), f_type) < 0) {
            return error.H5I_INVALID_HID;
        }
    }

    return type_id;
}
