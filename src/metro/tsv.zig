const std = @import("std");
const metro = @import("../metro.zig");
const hdf5 = @import("../hdf5.zig");

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
            try parseContinuous(reader, h5f, shape, ch.name, &h5a, allocator, options);
        },
        .step => {
            try parseStep(reader, h5f, shape, ch.name, &h5a, allocator);
        },
        .unknown => {
            return error.UnsupportedChannel;
        },
    }
}

fn parseStep(
    reader: *std.Io.Reader,
    h5f: *hdf5.File,
    shape: usize,
    name: []const u8,
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
) !void {
    const col_num: usize = if (shape == 0) 1 else shape;

    // Channles with "step" frequency don't have step markers
    // Keep track of scan index and step index
    var scan_idx: ?usize = null;
    var step_idx: usize = 0;

    // Store data in array list
    var data = try allocator.alloc(f64, col_num);
    defer allocator.free(data);

    // Read line by line
    while (try reader.takeDelimiter('\n')) |line| {
        // Try parse as value first
        if (scan_idx != null) {
            // Append data and continue to next line if parsing is succesful
            var it = std.mem.splitScalar(u8, line, '\t');
            var n: usize = 0;
            while (it.next()) |col| {
                const val = std.fmt.parseFloat(f64, col) catch break;
                if (n < data.len) data[n] = val;
                n += 1;
            }

            // Check if the line matched the expected shape and write the data
            if (n == col_num) {
                const path = try allocator.printSentinel("{d}/by_idx/{d}/{s}", .{ scan_idx.?, step_idx, name }, 0);
                defer allocator.free(path);
                var h5d: hdf5.FixedDset(f64) = try .create(h5f.id, path, shape, data);
                h5a.write(h5d.id) catch {};
                h5d.close();
                step_idx += 1;
            }
        }

        // Is it a scan marker?
        if (std.mem.startsWith(u8, line, "# SCAN ")) {
            // Update scan index and reset step index
            scan_idx = std.fmt.parseInt(usize, line[7..], 10) catch null;
            step_idx = 0;
        }
    }
}

fn parseContinuous(
    reader: *std.Io.Reader,
    h5f: *hdf5.File,
    shape: usize,
    name: []const u8,
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    const col_num: usize = if (shape == 0) 1 else shape;
    const chunk_size = options.chunk_size;

    // Allocate a row buffer
    const row_buf = try allocator.alloc(f64, col_num);
    defer allocator.free(row_buf);

    // Allocate one reusable chunk buffer when chunking is enabled.
    var chunk_buf: ?[]f64 = null;
    if (chunk_size != 0) {
        const chunk_len = @divFloor(chunk_size, @sizeOf(f64));
        chunk_buf = try allocator.alloc(f64, chunk_len);
    }
    defer if (chunk_buf) |buf| allocator.free(buf);

    while (try reader.takeDelimiter('\n')) |scan_marker| {
        if (!std.mem.startsWith(u8, scan_marker, "# SCAN ")) continue;
        const scan_idx = std.fmt.parseInt(usize, scan_marker[7..], 10) catch continue;

        while (reader.peekDelimiterExclusive('\n')) |step_marker| {
            // Go back to main loop if a scan marker was found without
            // advancing seek position
            if (std.mem.startsWith(u8, step_marker, "# SCAN ")) break;
            reader.toss(step_marker.len + 1);
            if (!std.mem.startsWith(u8, step_marker, "# STEP ")) continue;

            const idx = std.mem.findScalar(u8, step_marker, ':') orelse continue;
            const step_idx = std.fmt.parseInt(usize, step_marker[7..idx], 10) catch continue;
            const step_val = try allocator.dupeSentinel(u8, step_marker[idx + 2 ..], 0);
            defer allocator.free(step_val);

            const path = try allocator.printSentinel("{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, name }, 0);
            defer allocator.free(path);
            var h5d: hdf5.BufferedDset(f64) = try .create(h5f.id, path, shape, allocator, chunk_buf);
            defer h5d.close();
            var writer = h5d.writer();

            while (reader.peekDelimiterExclusive('\n')) |line| {
                var it = std.mem.splitScalar(u8, line, '\t');
                var col_count: usize = 0;
                while (it.next()) |col| : (col_count += 1) {
                    const val = std.fmt.parseFloat(f64, col) catch break;
                    if (col_count < col_num) row_buf[col_count] = val;
                }

                // Check if the line matched the expected shape
                if (col_count == col_num) {
                    // Append data and continue to next line
                    try writer.appendRow(row_buf);
                } else {
                    if (std.mem.startsWith(u8, line, "# SCAN ")) break;
                    if (std.mem.startsWith(u8, line, "# STEP ")) break;
                }

                reader.toss(line.len + 1);
            } else |_| {}

            try writer.flush();
            // Write attributes to the dataset
            h5a.write(h5d.id()) catch {};
            // Create a shortcut link scan_idx/step_val pointing to scan_idx/by_idx/step_idx
            const target = try allocator.printSentinel("{d}/by_idx/{d}", .{ scan_idx, step_idx }, 0);
            defer allocator.free(target);
            const link = try allocator.printSentinel("{d}/{s}", .{ scan_idx, step_val }, 0);
            defer allocator.free(link);
            h5f.createLink(target, link) catch {};
        } else |_| {}
    }
}

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
