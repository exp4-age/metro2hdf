const std = @import("std");
const Allocator = std.mem.Allocator;
const hdf5 = @import("libhdf5");
const getH5T = @import("../types.zig").getH5T;

pub fn Allocating(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        shape: usize,
        data: std.ArrayList(T) = .empty,
        dset_id: hdf5.hid_t = -1,
        file_id: hdf5.hid_t = -1,

        const Self = @This();

        pub fn init(
            allocator: Allocator,
            path: [:0]const u8,
            shape: usize,
            file_id: hdf5.hid_t,
        ) Self {
            return .{
                .allocator = allocator,
                .path = path,
                .shape = if (shape > 1) shape else 1,
                .file_id = file_id,
            };
        }

        pub fn appendRow(self: *Self, row: []const T) !void {
            if (row.len != self.shape) return error.ShapeMismatch;
            try self.data.appendSlice(self.allocator, row);
        }

        pub fn flush(self: *Self) !void {
            if (self.dset_id >= 0) return error.DsetAlreadyWritten;
            const buffer = self.data.items;
            if (buffer.len == 0) return;

            // Link creation property list for creation of intermediate groups
            const lcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
            if (lcpl_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(lcpl_id);
            if (hdf5.H5Pset_create_intermediate_group(lcpl_id, 1) < 0) return error.LcplError;

            // Dataset creation property list for chunking
            const dcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
            if (dcpl_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(dcpl_id);

            // Dataspace
            var space_id: hdf5.hid_t = -1;
            if (self.shape > 1) {
                const rows = std.math.divExact(usize, buffer.len, self.shape) catch {
                    return error.ShapeMismatch;
                };
                const dims = [2]hdf5.hsize_t{ @intCast(rows), self.shape };
                space_id = hdf5.H5Screate_simple(2, &dims, null);
            } else {
                const dims = [1]hdf5.hsize_t{@intCast(buffer.len)};
                space_id = hdf5.H5Screate_simple(1, &dims, null);
            }
            if (space_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(space_id);

            // Dataset access property list
            const dapl_id = hdf5.H5P_DEFAULT;

            // Dataset
            const type_id: hdf5.hid_t = getH5T(T);
            self.dset_id = hdf5.H5Dcreate2(self.file_id, self.path, type_id, space_id, lcpl_id, dcpl_id, dapl_id);
            if (self.dset_id < 0) return error.H5I_INVALID_HID;

            // Write the dataset
            const H5S_ALL = hdf5.H5S_ALL;
            const H5P_DEFAULT = hdf5.H5P_DEFAULT;
            if (hdf5.H5Dwrite(self.dset_id, type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buffer.ptr) < 0) {
                return error.WriteFailed;
            }
        }

        pub fn close(self: *Self) void {
            self.data.deinit(self.allocator);
            if (self.dset_id >= 0) {
                if (hdf5.H5Dclose(self.dset_id) >= 0) self.dset_id = -1;
            }
        }
    };
}
