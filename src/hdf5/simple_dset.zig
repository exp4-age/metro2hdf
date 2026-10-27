const std = @import("std");
const hdf5 = @import("libhdf5");

pub fn SimpleDset(comptime T: type) type {
    return struct {
        id: hdf5.hid_t = -1,
        shape: usize,

        const Self = @This();

        pub const WriteError = error{
            FileNotOpen,
            H5I_INVALID_HID,
            EmptyDataset,
            LcplError,
            DcplError,
            ShapeMismatch,
            WriteFailed,
        };

        pub fn write(
            file_id: hdf5.hid_t,
            name: [:0]const u8,
            shape: usize,
            buffer: []T,
        ) WriteError!Self {
            if (file_id < 0) return WriteError.FileNotOpen;
            if (buffer.len == 0) return WriteError.EmptyDataset;

            // Link creation property list for creation of intermediate groups
            const lcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_LINK_CREATE());
            if (lcpl_id < 0) return WriteError.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(lcpl_id);
            if (hdf5.H5Pset_create_intermediate_group(lcpl_id, 1) < 0) return WriteError.LcplError;

            // Dataset creation property list for chunking
            const dcpl_id = hdf5.H5Pcreate(hdf5.ZIG_H5P_DATASET_CREATE());
            if (dcpl_id < 0) return WriteError.H5I_INVALID_HID;
            defer _ = hdf5.H5Pclose(dcpl_id);

            // Dataspace
            var space_id: hdf5.hid_t = -1;
            if (shape > 1) {
                const rows = std.math.divExact(usize, buffer.len, shape) catch {
                    return WriteError.ShapeMismatch;
                };
                const dims = [2]hdf5.hsize_t{@intCast(rows), shape};
                space_id = hdf5.H5Screate_simple(2, &dims, null);
            } else {
                const dims = [1]hdf5.hsize_t{@intCast(buffer.len)};
                space_id = hdf5.H5Screate_simple(1, &dims, null);
            }
            if (space_id < 0) return WriteError.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(space_id);

            // HDF5 data type
            const type_id = getH5T(T);

            // Dataset access property list
            const dapl_id = hdf5.H5P_DEFAULT;

            // Dataset
            const id = hdf5.H5Dcreate2(file_id, name, type_id, space_id, lcpl_id, dcpl_id, dapl_id);
            if (id < 0) return WriteError.H5I_INVALID_HID;

            // Write the dataset
            const H5S_ALL = hdf5.H5S_ALL;
            const H5P_DEFAULT = hdf5.H5P_DEFAULT;
            if (hdf5.H5Dwrite(id, type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buffer.ptr) < 0) {
                return WriteError.WriteFailed;
            }

            return .{
                .id = id,
                .shape = if (shape > 1) shape else 1,
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
