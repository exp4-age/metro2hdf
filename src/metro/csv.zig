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
    var h5a = try hdf5.AttrList.init(allocator);
    defer h5a.deinit();

    // Get the channel name
    const name_marker = try reader.takeDelimiter('\n');
    if (name_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, name_marker.?, "# Name: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, name_marker.?[8..], ch.name)) return error.ChannelMismatch;
    try h5a.append("name", name_marker.?[8..]);

    // Get the hint
    const hint_marker = try reader.takeDelimiter('\n');
    if (hint_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, hint_marker.?, "# Hint: ")) return error.MissingAttribute;
    try h5a.append("hint", hint_marker.?[8..]);

    // Get the frequency
    const freq_marker = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq_marker.?, "# Frequency: ")) return error.MissingAttribute;
    try h5a.append("freq", freq_marker.?[13..]);
    const freq = Frequency.fromString(freq_marker.?[13..]);

    // Get the shape
    const shape_str = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return error.MissingAttribute;
    const shape = try std.fmt.parseInt(usize, shape_str.?[9..], 10);

    // Parse additional attributes if present
    while (reader.peekDelimiterExclusive('\n')) |line| {
        if (std.mem.find(u8, line, ":")) |idx| {
            try h5a.append(line[2..idx], line[idx + 2 ..]);
            reader.toss(line.len + 1);
        } else break;
    } else |err| {
        return err;
    }

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
