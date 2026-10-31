const std = @import("std");
const Allocator = std.mem.Allocator;
const hdf5 = @import("libhdf5");
const getH5T = @import("types.zig").getH5T;

pub fn Fixed(comptime T: type) type {
    return struct {
        id: hdf5.hid_t = -1,

        const Self = @This();

        pub fn create(
            file_id: hdf5.hid_t,
            name: [:0]const u8,
            shape: usize,
            buffer: []const T,
        ) !Self {
            if (file_id < 0) return error.FileNotOpen;
            if (buffer.len == 0) return error.DsetEmpty;

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
            if (shape > 1) {
                const rows = std.math.divExact(usize, buffer.len, shape) catch {
                    return error.ShapeMismatch;
                };
                const dims = [2]hdf5.hsize_t{ @intCast(rows), shape };
                space_id = hdf5.H5Screate_simple(2, &dims, null);
            } else {
                const dims = [1]hdf5.hsize_t{@intCast(buffer.len)};
                space_id = hdf5.H5Screate_simple(1, &dims, null);
            }
            if (space_id < 0) return error.H5I_INVALID_HID;
            defer _ = hdf5.H5Sclose(space_id);

            // HDF5 data type
            const type_id = getH5T(T);

            // Dataset access property list
            const dapl_id = hdf5.H5P_DEFAULT;

            // Dataset
            const id = hdf5.H5Dcreate2(file_id, name, type_id, space_id, lcpl_id, dcpl_id, dapl_id);
            if (id < 0) return error.H5I_INVALID_HID;
            errdefer _ = hdf5.H5Dclose(id);

            // Write the dataset
            const H5S_ALL = hdf5.H5S_ALL;
            const H5P_DEFAULT = hdf5.H5P_DEFAULT;
            if (hdf5.H5Dwrite(id, type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buffer.ptr) < 0) {
                return error.WriteFailed;
            }

            return .{ .id = id };
        }

        pub fn close(self: *@This()) void {
            if (self.id >= 0) {
                if (hdf5.H5Dclose(self.id) >= 0) self.id = -1;
            }
        }
    };
}

pub fn Buffered(comptime T: type) type {
    return struct {
        interface: Writer,

        const Self = @This();

        pub const Allocating = @import("dset/allocating.zig").Allocating;
        pub const Chunked = @import("dset/chunked.zig").Chunked;

        const Writer = union(enum) {
            allocating: Allocating(T),
            chunked: Chunked(T),
        };

        pub fn allocating(
            allocator: Allocator,
            path: [:0]const u8,
            shape: usize,
            file_id: hdf5.hid_t,
        ) Self {
            return .{ .interface = .{ .allocating = .init(allocator, path, shape, file_id) } };
        }

        pub fn chunked(
            buffer: []T,
            path: [:0]const u8,
            shape: usize,
            file_id: hdf5.hid_t,
        ) Self {
            return .{ .interface = .{ .chunked = .init(buffer, path, shape, file_id) } };
        }

        pub fn appendRow(self: *Self, row: []const T) !void {
            switch (self.interface) {
                inline else => |*interface| try interface.appendRow(row),
            }
        }

        pub fn flush(self: *Self) !void {
            switch (self.interface) {
                inline else => |*interface| try interface.flush(),
            }
        }

        pub fn id(self: *Self) hdf5.hid_t {
            return switch (self.interface) {
                inline else => |*interface| interface.dset_id,
            };
        }

        pub fn exists(self: *Self) bool {
            return (self.id() >= 0);
        }

        pub fn close(self: *Self) void {
            switch (self.interface) {
                inline else => |*interface| interface.close(),
            }
        }
    };
}
