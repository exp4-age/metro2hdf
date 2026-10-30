const Channel = @This();

const std = @import("std");
const metro = @import("../metro.zig");
const hdf5 = @import("../hdf5.zig");
const csv = @import("csv.zig");
const hptdc = @import("hptdc.zig");

path: []const u8,
name: []const u8,
format: FileFormat,

pub const FileFormat = enum {
    txt,
    hdf5,
    tdc,
    jpg,

    pub fn parse(ext: []const u8) !FileFormat {
        if (std.mem.eql(u8, ext, ".txt")) return .txt;
        if (std.mem.eql(u8, ext, ".tdc")) return .tdc;
        if (std.mem.eql(u8, ext, ".jpg")) return .jpg;
        if (std.mem.eql(u8, ext, ".h5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".hdf5")) return .hdf5;
        return error.UnknownFormat;
    }
};

pub fn parse(
    self: @This(),
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    // Call the parser based on the file format
    switch (self.format) {
        .txt => {
            try csv.parseChannel(self, file, h5f, io, allocator, options);
        },
        .tdc => {
            try hptdc.parseChannel(self, file, h5f, io, allocator, options);
        },
        else => {
            return error.UnknownFormat;
        },
    }
}
