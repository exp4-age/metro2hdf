const std = @import("std");
const hdf5 = @cImport({
    @cInclude("hdf5/hdf5lib.h");
});

pub fn ChunkedDset(comptime T: type) type {
    return struct {
        id: hdf5.hid_t = -1,
        shape: usize,
        buffer: []T,
        row_count: usize = 0,

        const Self = @This();

        pub const CreateError = error{
            FileNotOpen,
            H5I_INVALID_HID,
            LcplError,
            DcplError,
        };

        pub const WriteError = error{
            FileNotOpen,
            H5I_INVALID_HID,
            NoData,
        };

        pub fn create(
            file_id: hdf5.hid_t,
            name: [:0]const u8,
            shape: usize,
            buffer: []T,
        ) CreateError!Self {
            if (file_id < 0) return CreateError.FileNotOpen;

            // Link creation property list for creation of intermediate groups
            const lcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
            if (lcpl_id < 0) return CreateError.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(lcpl_id);
            if (hdf5.H5Pset_create_intermediate_group(lcpl_id, 1) < 0) return CreateError.LcplError;

            // Dataset creation property list for chunking
            const dcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
            if (dcpl_id < 0) return CreateError.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(dcpl_id);
            if (shape > 1) {
                const chunk_rows: hdf5.hsize_t = @divFloor(buffer.len, shape);
                const chunk = [2]hdf5.hsize_t{chunk_rows, shape};
                if (hdf5.H5Pset_chunk(dcpl_id, 2, &chunk) < 0) return CreateError.DcplError;
            } else {
                const chunk = [1]hdf5.hsize_t{buffer.len};
                if (hdf5.H5Pset_chunk(dcpl_id, 1, &chunk) < 0) return CreateError.DcplError;
            }

            // Dataspace
            var space_id: hdf5.hid_t = -1;
            if (shape > 1) {
                const dims = [2]hdf5.hsize_t{0, shape};
                const maxdims = [2]hdf5.hsize_t{hdf5.H5S_UNLIMITED, shape};
                space_id = hdf5.H5Screate_simple(2, &dims, &maxdims);
            } else {
                const dims = [1]hdf5.hsize_t{0};
                const maxdims = [1]hdf5.hsize_t{hdf5.H5S_UNLIMITED};
                space_id = hdf5.H5Screate_simple(1, &dims, &maxdims);
            }
            if (space_id < 0) return CreateError.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(space_id);

            // HDF5 data type
            const type_id = getH5T(T);

            // Dataset access property list
            const dapl_id = hdf5.H5P_DEFAULT;

            // Dataset
            const id = hdf5.H5Dcreate2(file_id, name, type_id, space_id, lcpl_id, dcpl_id, dapl_id);
            if (id < 0) return CreateError.H5I_INVALID_HID;

            return .{
                .id = id,
                .shape = if (shape > 1) shape else 1,
                .buffer = buffer,
            };
        }

        pub fn write(self: *@This()) WriteError!void {
            if (self.row_count == 0) return;

            // Get the file dataspace
            const fspace_id = hdf5.H5Dget_space(self.id);
            if (fspace_id < 0) return WriteError.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(fspace_id);

            // Extend the dataset and get hyperslab selection
            if (self.shape > 1) {
                var dims: [2]hdf5.hsize_t = undefined;
                if (hdf5.H5Sget_simple_extent_dims(fspace_id, &dims, null) < 0) return WriteError.H5I_INVALID_HID;
                const new_dims = [2]hdf5.hsize_t{dims[0] + self.row_count, dims[1]};
                if (hdf5.H5Dset_extent(self.id, &new_dims) < 0) return WriteError.H5I_INVALID_HID;
                const new_fspace_id = hdf5.H5Dget_space(self.id);
                if (new_fspace_id < 0) return WriteError.H5I_INVALID_HID;
                defer _ = hdf5.H5Sclose(new_fspace_id);
                const start = [2]hdf5.hsize_t{dims[0], 0};
                const count = [2]hdf5.hsize_t{self.row_count, dims[1]};
                if (hdf5.H5Sselect_hyperslab(new_fspace_id, hdf5.H5S_SELECT_SET, &start, null, &count, null) < 0) return WriteError.H5I_INVALID_HID;
                const mspace_id = hdf5.H5Screate_simple(2, &count, null);
                if (mspace_id < 0) return WriteError.H5I_INVALID_HID;
                defer _ = hdf5.H5Sclose(mspace_id);
                const type_id = getH5T(T);
                const dxpl_id = hdf5.H5P_DEFAULT;
                const data = self.buffer[0..self.row_count * self.shape].ptr;
                if (hdf5.H5Dwrite(self.id, type_id, mspace_id, new_fspace_id, dxpl_id, data) < 0) return WriteError.H5I_INVALID_HID;
            } else{
                var dims: [1]hdf5.hsize_t = undefined;
                if (hdf5.H5Sget_simple_extent_dims(fspace_id, &dims, null) < 0) return WriteError.H5I_INVALID_HID;
                const new_dims = [1]hdf5.hsize_t{dims[0] + self.row_count};
                if (hdf5.H5Dset_extent(self.id, &new_dims) < 0) return WriteError.H5I_INVALID_HID;
                const new_fspace_id = hdf5.H5Dget_space(self.id);
                if (new_fspace_id < 0) return WriteError.H5I_INVALID_HID;
                defer _ = hdf5.H5Sclose(new_fspace_id);
                const start = [1]hdf5.hsize_t{dims[0]};
                const count = [1]hdf5.hsize_t{self.row_count};
                if (hdf5.H5Sselect_hyperslab(new_fspace_id, hdf5.H5S_SELECT_SET, &start, null, &count, null) < 0) return WriteError.H5I_INVALID_HID;
                const mspace_id = hdf5.H5Screate_simple(1, &count, null);
                if (mspace_id < 0) return WriteError.H5I_INVALID_HID;
                defer _ = hdf5.H5Sclose(mspace_id);
                const type_id = getH5T(T);
                const dxpl_id = hdf5.H5P_DEFAULT;
                const data = self.buffer[0..self.row_count].ptr;
                if (hdf5.H5Dwrite(self.id, type_id, mspace_id, new_fspace_id, dxpl_id, data) < 0) return WriteError.H5I_INVALID_HID;
            }

            // Reset row count for next chunk
            self.row_count = 0;
        }

        pub fn appendRow(self: *@This(), row: anytype) WriteError!void {
            if (self.row_count * self.shape + self.shape > self.buffer.len) try self.write();
            // Compute this after write(), since write() may reset row_count.
            const start = self.row_count * self.shape;
            const dst = self.buffer[start..][0..self.shape];
            const Src = @TypeOf(row[0]);
            if (T == Src) {
                @memcpy(dst, row);
            } else {
                for (dst, row) |*out, value| out.* = castNumber(value);
            }
            self.row_count += 1;
        }

        fn castNumber(value: anytype) T {
            const Src = @TypeOf(value);

            return switch (@typeInfo(T)) {
                .int => switch (@typeInfo(Src)) {
                    .int, .comptime_int =>
                        @as(T, @intCast(value)),

                    .float, .comptime_float =>
                        @as(T, @intFromFloat(value)),

                    else => @compileError(
                        "source element type must be an integer or float",
                    ),
                },

                .float => switch (@typeInfo(Src)) {
                    .int, .comptime_int =>
                        @as(T, @floatFromInt(value)),

                    .float, .comptime_float =>
                        @as(T, @floatCast(value)),

                    else => @compileError(
                        "source element type must be an integer or float",
                    ),
                },

                else => @compileError(
                    "dataset type must be an integer or float",
                ),
            };
        }

        pub fn close(self: *@This()) void {
            if (self.id >= 0) {
                if (hdf5.H5Dclose(self.id) >= 0) self.id = -1;
            }
        }
    };
}

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
