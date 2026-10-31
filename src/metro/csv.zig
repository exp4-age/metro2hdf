const std = @import("std");
const metro = @import("../metro.zig");
const hdf5 = @import("../hdf5.zig");
const step_channel = @import("csv/step.zig");
const stream_channel = @import("csv/stream.zig");

const Frequency = enum {
    continuous,
    step,
    unknown,

    fn fromString(freq: []const u8) Frequency {
        if (std.mem.eql(u8, freq, "continuous")) return .continuous;
        if (std.mem.eql(u8, freq, "step")) return .step;
        return .unknown;
    }
};

pub fn parseChannel(
    ch: metro.Channel,
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    // Initialize the reader
    const buf_size = 64 * 1024;
    var read_buffer: [buf_size]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var reader = &file_reader.interface;

    // The data channels ..._xspec and ..._yspec have more values per scan
    // than there are steps and I don't know how to write them into the hdf5
    // file structure in a way that makes sense, so I skip them here
    if (std.mem.endsWith(u8, ch.name, "xspec") or std.mem.endsWith(u8, ch.name, "yspec")) {
        return error.UnsupportedChannel;
    }

    // Create an attribute list
    var h5a: hdf5.AttrList = try .init(allocator);
    defer h5a.deinit();

    // Get the channel name
    if (try reader.takeDelimiter('\n')) |marker| {
        if (marker.len < 9 or !std.mem.startsWith(u8, marker, "# Name: ")) {
            return error.MissingAttribute;
        }
        if (!std.mem.eql(u8, marker[8..], ch.name)) return error.ChannelMismatch;
        try h5a.append("name", ch.name);
    } else return error.CorruptedFile;

    // Get the hint
    if (try reader.takeDelimiter('\n')) |marker| {
        if (marker.len < 9 or !std.mem.startsWith(u8, marker, "# Hint: ")) {
            return error.MissingAttribute;
        }
        try h5a.append("hint", marker[8..]);
    } else return error.CorruptedFile;

    // Get the frequency
    var freq: Frequency = .unknown;
    if (try reader.takeDelimiter('\n')) |marker| {
        if (marker.len < 14 or !std.mem.startsWith(u8, marker, "# Frequency: ")) {
            return error.MissingAttribute;
        }
        try h5a.append("freq", marker[13..]);
        freq = .fromString(marker[13..]);
    } else return error.CorruptedFile;

    // Get the shape
    var shape: usize = 0;
    if (try reader.takeDelimiter('\n')) |marker| {
        if (marker.len < 10 or !std.mem.startsWith(u8, marker, "# Shape: ")) {
            return error.MissingAttribute;
        }
        shape = try std.fmt.parseInt(usize, marker[9..], 10);
    } else return error.CorruptedFile;

    // Parse additional attributes if present
    while (reader.peekDelimiterExclusive('\n')) |marker| {
        if (std.mem.find(u8, marker, ":")) |idx| {
            if (marker.len > idx + 2) try h5a.append(marker[2..idx], marker[idx + 2 ..]);
            reader.toss(marker.len + 1);
        } else break;
    } else |_| return error.CorruptedFile;

    switch (freq) {
        .continuous => {
            try stream_channel.parse(reader, h5f, shape, ch.name, &h5a, allocator, options);
        },
        .step => {
            try step_channel.parse(reader, h5f, shape, ch.name, &h5a, allocator);
        },
        .unknown => {
            return error.UnsupportedChannel;
        },
    }
}
