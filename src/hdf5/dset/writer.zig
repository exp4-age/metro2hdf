const std = @import("std");

pub fn Writer(comptime T: type) type {
    return struct {
        vtable: *const VTable,

        const Self = @This();

        pub const Error = error{
            DsetClosed,
            DsetAlreadyWritten,
            DsetEmpty,
            FileNotOpen,
            LcplError,
            ShapeMismatch,
            OutOfMemory,
            H5I_INVALID_HID,
            WriteFailed,
        };

        pub const VTable = struct {
            append_row: *const fn (interface: *Self, row: []const T) Error!void,
            flush: *const fn (interface: *Self) Error!void,
        };

        pub fn appendRow(self: *Self, row: []const T) Error!void {
            return self.vtable.append_row(self, row);
        }

        pub fn flush(self: *Self) Error!void {
            return self.vtable.flush(self);
        }
    };
}
