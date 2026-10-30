const std = @import("std");
const hdf5 = @import("libhdf5");
const getH5T = @import("../types.zig").getH5T;

pub fn Chunked(comptime T: type) type {
    return struct {
        buffer: []T,
        count: usize = 0,
        path: [:0]const u8,
        shape: usize,
        dset_id: hdf5.hid_t = -1,
        file_id: hdf5.hid_t = -1,

        const Self = @This();

        pub fn init(
            buffer: []T,
            path: [:0]const u8,
            shape: usize,
            file_id: hdf5.hid_t,
        ) Self {
            return .{
                .buffer = buffer,
                .path = path,
                .shape = if (shape > 1) shape else 1,
                .file_id = file_id,
            };
        }

        fn create(self: *Self) !void {
            if (self.dset_id >= 0) return error.DsetAlreadyExists;
            if (self.file_id < 0) return error.FileNotOpen;

            // Link creation property list for creation of intermediate groups
            const lcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
            if (lcpl_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(lcpl_id);
            if (hdf5.H5Pset_create_intermediate_group(lcpl_id, 1) < 0) return error.LcplError;

            // Dataset creation property list for chunking
            const dcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
            if (dcpl_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(dcpl_id);
            if (self.shape > 1) {
                const chunk_rows: hdf5.hsize_t = @divFloor(self.buffer.len, self.shape);
                const chunk = [2]hdf5.hsize_t{ chunk_rows, self.shape };
                if (hdf5.H5Pset_chunk(dcpl_id, 2, &chunk) < 0) return error.DcplError;
            } else {
                const chunk = [1]hdf5.hsize_t{self.buffer.len};
                if (hdf5.H5Pset_chunk(dcpl_id, 1, &chunk) < 0) return error.DcplError;
            }

            // Dataspace
            var space_id: hdf5.hid_t = -1;
            if (self.shape > 1) {
                const dims = [2]hdf5.hsize_t{ 0, self.shape };
                const maxdims = [2]hdf5.hsize_t{ hdf5.H5S_UNLIMITED, self.shape };
                space_id = hdf5.H5Screate_simple(2, &dims, &maxdims);
            } else {
                const dims = [1]hdf5.hsize_t{0};
                const maxdims = [1]hdf5.hsize_t{hdf5.H5S_UNLIMITED};
                space_id = hdf5.H5Screate_simple(1, &dims, &maxdims);
            }
            if (space_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(space_id);

            // Dataset access property list
            const dapl_id = hdf5.H5P_DEFAULT;

            // Dataset
            const type_id: hdf5.hid_t = getH5T(T);
            const id = hdf5.H5Dcreate2(self.file_id, self.path, type_id, space_id, lcpl_id, dcpl_id, dapl_id);
            if (id < 0) return error.H5I_INVALID_HID;

            self.dset_id = id;
        }

        pub fn appendRow(self: *Self, row: []const T) !void {
            if (row.len != self.shape) return error.ShapeMismatch;
            if (self.count + row.len > self.buffer.len) try self.flush();
            const dst = self.buffer[self.count..][0..row.len];
            @memcpy(dst, row);
            self.count += row.len;
        }

        pub fn flush(self: *Self) !void {
            if (self.count == 0) return;
            if (self.dset_id < 0) try self.create();
            if (self.shape > 1) {
                try self.flush2d();
            } else {
                try self.flush1d();
            }
            // Reset count for next chunk
            self.count = 0;
        }

        fn flush1d(self: *Self) !void {
            // Get the file dataspace
            const fspace_id = hdf5.H5Dget_space(self.dset_id);
            if (fspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(fspace_id);

            // Get the current dimensions of the dataset
            var dims: [1]hdf5.hsize_t = undefined;
            if (hdf5.H5Sget_simple_extent_dims(fspace_id, &dims, null) < 0) return error.H5I_INVALID_HID;

            // Add the new chunk to the dimensions
            const new_dims = [1]hdf5.hsize_t{dims[0] + self.count};

            // Extend the dataset dimensions
            if (hdf5.H5Dset_extent(self.dset_id, &new_dims) < 0) return error.H5I_INVALID_HID;
            const new_fspace_id = hdf5.H5Dget_space(self.dset_id);
            if (new_fspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(new_fspace_id);

            // Update the hyperslab selection
            const start = [1]hdf5.hsize_t{dims[0]};
            const count = [1]hdf5.hsize_t{self.count};
            if (hdf5.H5Sselect_hyperslab(new_fspace_id, hdf5.H5S_SELECT_SET, &start, null, &count, null) < 0) {
                return error.H5I_INVALID_HID;
            }

            // Create a dataspace in memory
            const mspace_id = hdf5.H5Screate_simple(1, &count, null);
            if (mspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(mspace_id);

            // Write the chunk
            const dxpl_id = hdf5.H5P_DEFAULT;
            const type_id: hdf5.hid_t = getH5T(T);
            const data = self.buffer[0..self.count].ptr;
            if (hdf5.H5Dwrite(self.dset_id, type_id, mspace_id, new_fspace_id, dxpl_id, data) < 0) {
                return error.H5I_INVALID_HID;
            }
        }

        fn flush2d(self: *Self) !void {
            // Get the file dataspace
            const fspace_id = hdf5.H5Dget_space(self.dset_id);
            if (fspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(fspace_id);

            // Get the current dimensions of the dataset
            var dims: [2]hdf5.hsize_t = undefined;
            if (hdf5.H5Sget_simple_extent_dims(fspace_id, &dims, null) < 0) return error.H5I_INVALID_HID;

            // Add the new chunk to the dimensions
            const row_count = std.math.divExact(usize, self.count, self.shape) catch return error.ShapeMismatch;
            const new_dims = [2]hdf5.hsize_t{ dims[0] + row_count, dims[1] };

            // Extend the dataset dimensions
            if (hdf5.H5Dset_extent(self.dset_id, &new_dims) < 0) return error.H5I_INVALID_HID;
            const new_fspace_id = hdf5.H5Dget_space(self.dset_id);
            if (new_fspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(new_fspace_id);

            // Update the hyperslab selection
            const start = [2]hdf5.hsize_t{ dims[0], 0 };
            const count = [2]hdf5.hsize_t{ row_count, dims[1] };
            if (hdf5.H5Sselect_hyperslab(new_fspace_id, hdf5.H5S_SELECT_SET, &start, null, &count, null) < 0) {
                return error.H5I_INVALID_HID;
            }

            // Create a dataspace in memory
            const mspace_id = hdf5.H5Screate_simple(2, &count, null);
            if (mspace_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(mspace_id);

            // Write the chunk
            const dxpl_id = hdf5.H5P_DEFAULT;
            const type_id: hdf5.hid_t = getH5T(T);
            const data = self.buffer[0..self.count].ptr;
            if (hdf5.H5Dwrite(self.dset_id, type_id, mspace_id, new_fspace_id, dxpl_id, data) < 0) {
                return error.H5I_INVALID_HID;
            }
        }

        pub fn close(self: *Self) void {
            if (self.dset_id >= 0) {
                if (hdf5.H5Dclose(self.dset_id) >= 0) self.dset_id = -1;
            }
        }
    };
}
