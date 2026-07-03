const std = @import("std");

const hdf5 = @cImport({
    @cInclude("hdf5.h");
});
const h5t = @cImport({
    @cInclude("h5types.h");
});

const metro = @import("metro.zig");

pub const H5Error = error {
    OpenFailed,
    FileNotOpen,
    H5I_INVALID_HID,
    WriteFailed,
    InvalidShape,
};

pub const File = struct {
    id: hdf5.hid_t = -1,

    pub fn create(path: [:0]const u8) !File {
        const id: hdf5.hid_t = hdf5.H5Fcreate(
            path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT
        );
        if (id < 0) return error.H5I_INVALID_HID;
        return .{ .id = id };
    }

    pub fn close(self: *@This()) void {
        if (self.id >= 0) {
            _ = hdf5.H5Fclose(self.id);
            self.id = -1;
        }
    }

    pub fn write_dset(
        self: *@This(),
        scan_idx: []const u8,
        step_val: []const u8,
        channel: []const u8,
        data: []const f64,
        shape: usize,
    ) !void {
        // Fail if the file is not open
        if (self.id < 0) return H5Error.FileNotOpen;

        // Create path to dataset
        var buf: [1024]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}/{s}", .{scan_idx, step_val, channel}, 0);

        // Create link creation property list
        const lcpl = hdf5.H5Pcreate(h5t.shim_H5P_LINK_CREATE());
        if (lcpl < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Pclose(lcpl);

        // Create intermediate groups as needed
        if (hdf5.H5Pset_create_intermediate_group(lcpl, 1) < 0) return H5Error.H5I_INVALID_HID;

        // Create a 1D dataspace
        var rank: c_int = undefined;
        var dims_1d: [1]hdf5.hsize_t = undefined;
        var dims_2d: [2]hdf5.hsize_t = undefined;

        if (shape == 0) {
            rank = 1;
            dims_1d[0] = @intCast(data.len);
        } else {
            if (data.len % shape != 0) return H5Error.InvalidShape;
            const rows = data.len / shape;
            rank = 2;
            dims_2d[0] = @intCast(rows);
            dims_2d[1] = @intCast(shape);
        }
        const fspace = if (rank == 1)
            hdf5.H5Screate_simple(rank, &dims_1d, null)
        else
            hdf5.H5Screate_simple(rank, &dims_2d, null);
        if (fspace < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(fspace);

        // Define the datatype
        const type_id = h5t.shim_H5T_IEEE_F64LE();

        // Create the dataset
        const dset = hdf5.H5Dcreate2(self.id, name, type_id, fspace, lcpl, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (dset < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Dclose(dset);

        // Write the dataset
        if (hdf5.H5Dwrite(dset, type_id, hdf5.H5S_ALL, hdf5.H5S_ALL, hdf5.H5P_DEFAULT, data.ptr) < 0) return H5Error.WriteFailed;
    }

    pub fn write_attrs(self: *@This(), run: metro.Run) !void {
        var buf: [1024]u8 = undefined;

        // Write measurement number
        const num = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.num}, 0);
        try self.write_str_attr("number", num);

        // Write name
        const name = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.name}, 0);
        try self.write_str_attr("name", name);

        // Write date
        const date = try std.fmt.bufPrintSentinel(&buf, "{s}-{s}-{s}", .{run.date[0..2], run.date[2..4], run.date[4..8]}, 0);
        try self.write_str_attr("date", date);

        // Write time
        const time = try std.fmt.bufPrintSentinel(&buf, "{s}:{s}:{s}", .{run.time[0..2], run.time[2..4], run.time[4..6]}, 0);
        try self.write_str_attr("time", time);
    }

    pub fn write_str_attr(self: *@This(), name: [*:0]const u8, value: [*:0]const u8) !void {
        const value_c: [*c]const u8 = value;
        const buf: ?*const anyopaque = @ptrCast(&value_c);

        // Fail if the file is not open
        if (self.id < 0) return H5Error.FileNotOpen;

        const str_t = hdf5.H5Tcopy(h5t.shim_H5T_C_S1());
        if (str_t < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Tclose(str_t);

        if (hdf5.H5Tset_size(str_t, hdf5.H5T_VARIABLE) < 0) return H5Error.WriteFailed;
        if (hdf5.H5Tset_cset(str_t, hdf5.H5T_CSET_UTF8) < 0) return H5Error.WriteFailed;
        if (hdf5.H5Tset_strpad(str_t, hdf5.H5T_STR_NULLTERM) < 0) return H5Error.WriteFailed;

        // Open the root group
        const root = hdf5.H5Gopen2(self.id, "/", hdf5.H5P_DEFAULT);
        if (root < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Gclose(root);

        // Overwrite if attribute already exists
        if (hdf5.H5Aexists(root, name) > 0) {
            const attr = hdf5.H5Aopen(root, name, hdf5.H5P_DEFAULT);
            if (attr < 0) return H5Error.H5I_INVALID_HID;
            defer _ = hdf5.H5Aclose(attr);

            // Write attribute
            if (hdf5.H5Awrite(attr, str_t, buf) < 0) return H5Error.WriteFailed;
            return;
        }

        // Create dataspace for the attribute
        const dspace = hdf5.H5Screate(hdf5.H5S_SCALAR);
        if (dspace < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(dspace);

        // Create attribute
        const attr = hdf5.H5Acreate2(root, name, str_t, dspace, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (attr < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Aclose(attr);

        // Write attribute
        if (hdf5.H5Awrite(attr, str_t, buf) < 0) return H5Error.WriteFailed;
    }
};
