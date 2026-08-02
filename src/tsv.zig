const std = @import("std");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

pub fn parseChannel(
    ch: metro.Channel,
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    // Currently no options supported
    _ = &options;

    // Initialize the reader
    const buf_size = 4096;
    var read_buffer: [buf_size]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    var reader = &file_reader.interface;

    // The data channels ..._xspec and ..._yspec have more values per scan
    // than there are steps and I don't know how to write them into the hdf5
    // file structure in a way that makes sense, so I skip them here
    if (std.mem.endsWith(u8, ch.name, "xspec") or std.mem.endsWith(u8, ch.name, "yspec")) {
        return error.UnsupportedChannel;
    }

    // Create an attribute list
    var attrs = try hdf5.AttrList.init(allocator);
    defer attrs.deinit();

    // Get the channel name
    const name_marker = try reader.takeDelimiter('\n');
    if (name_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, name_marker.?, "# Name: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, name_marker.?[8..], ch.name)) return error.ChannelMismatch;
    try attrs.append("name", name_marker.?[8..]);

    // Get the hint
    const hint_marker = try reader.takeDelimiter('\n');
    if (hint_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, hint_marker.?, "# Hint: ")) return error.MissingAttribute;
    try attrs.append("hint", hint_marker.?[8..]);

    // Get the frequency
    const freq_marker = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq_marker.?, "# Frequency: ")) return error.MissingAttribute;
    try attrs.append("freq", freq_marker.?[13..]);
    const freq = Frequency.fromString(freq_marker.?[13..]);

    // Get the shape
    const shape_str = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return error.MissingAttribute;
    const shape = try std.fmt.parseInt(usize, shape_str.?[9..], 10);

    // Parse additional attributes if present
    while (reader.peekDelimiterExclusive('\n')) |line| {
        if (std.mem.find(u8, line, ":")) |idx| {
            try attrs.append(line[2..idx], line[idx + 2 ..]);
            reader.toss(line.len + 1);
        } else break;
    } else |err| {
        return err;
    }

    switch (freq) {
        .continuous => {
            try parseContinuous(reader, h5f, ch, shape, &attrs, allocator);
        },
        .step => {
            try parseStep(reader, h5f, ch, shape, &attrs, allocator);
        },
        .unknown => {
            return error.UnsupportedChannel;
        },
    }
}

fn parseStep(
    reader: *std.Io.Reader,
    h5f: *hdf5.File,
    ch: metro.Channel,
    shape: usize,
    attrs: *hdf5.AttrList,
    allocator: std.mem.Allocator,
) !void {
    const ncols: usize = if (shape == 0) 1 else shape;

    // Channles with "step" frequency don't have step markers
    // Keep track of scan index and step index
    var scan_idx: ?usize = null;
    var step_idx: usize = 0;

    // Store data in array list
    var data = try allocator.alloc(f64, ncols);
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
            if (n == ncols) {
                try h5f.writeSimpleDset(
                    f64,
                    data,
                    shape,
                    scan_idx.?,
                    step_idx,
                    null,
                    ch.name,
                    attrs,
                );
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
    ch: metro.Channel,
    shape: usize,
    attrs: *hdf5.AttrList,
    allocator: std.mem.Allocator,
) !void {
    const col_num: usize = if (shape == 0) 1 else shape;

    var scan_idx: ?usize = null;
    var step_idx: ?usize = null;
    var step_marker: [4096]u8 = undefined;
    var step_val: ?[]u8 = null;

    var empty_step: bool = false;
    var corrupted_marker: bool = false;

    var row_buf = try allocator.alloc(f64, col_num);
    defer allocator.free(row_buf);

    var data: std.ArrayList(f64) = .empty;
    defer data.deinit(allocator);

    // Read line by line
    while (try reader.takeDelimiter('\n')) |line| {
        // Try parsing the line as tab separated values first
        if (scan_idx != null and step_idx != null) {
            var it = std.mem.splitScalar(u8, line, '\t');
            var col_idx: usize = 0;
            while (it.next()) |col| : (col_idx += 1) {
                const val = std.fmt.parseFloat(f64, col) catch break;
                if (col_idx < col_num) row_buf[col_idx] = val;
            }

            // Check if the line matched the expected shape
            if (col_idx == col_num) {
                // Append data and continue to next line
                try data.appendSlice(allocator, row_buf);
                continue;
            }
        }

        // Parse scan and step markers
        if (std.mem.startsWith(u8, line, "# STEP ")) {
            // Step marker should never come without a scan marker
            if (scan_idx == null) {
                corrupted_marker = true;
                continue;
            }

            // Write dataset to hdf5 before continuing with next step
            if (scan_idx != null and step_idx != null) {
                if (data.items.len > 0) {
                    try h5f.writeSimpleDset(
                        f64,
                        data.items,
                        shape,
                        scan_idx.?,
                        step_idx.?,
                        step_val,
                        ch.name,
                        attrs,
                    );
                    data.clearRetainingCapacity();
                } else {
                    empty_step = true;
                }
            }

            // Reset step index and value
            step_idx = null;
            step_val = null;

            // Find start of step value in line and update
            if (std.mem.findScalar(u8, line, ':')) |marker_idx| {
                step_idx = std.fmt.parseInt(usize, line[7..marker_idx], 10) catch {
                    corrupted_marker = true;
                    continue;
                };
                const val = line[marker_idx + 2 ..];
                @memcpy(step_marker[0 .. val.len], val);
                step_val = step_marker[0 .. val.len];
            } else {
                corrupted_marker = true;
            }
        } else if (std.mem.startsWith(u8, line, "# SCAN ")) {
            // Write dataset to hdf5 before continuing with next scan
            if (scan_idx != null and step_idx != null) {
                if (data.items.len > 0) {
                    try h5f.writeSimpleDset(
                        f64,
                        data.items,
                        shape,
                        scan_idx.?,
                        step_idx.?,
                        step_val,
                        ch.name,
                        attrs,
                    );
                    data.clearRetainingCapacity();
                } else {
                    empty_step = true;
                }
            }

            // Update scan index and reset step
            scan_idx = std.fmt.parseInt(usize, line[7..], 10) catch null;
            step_idx = null;
            step_val = null;
        }
    }

    // Write last dataset to hdf5
    if (scan_idx != null and step_idx != null) {
        if (data.items.len > 0) {
            try h5f.writeSimpleDset(
                f64,
                data.items,
                shape,
                scan_idx.?,
                step_idx.?,
                step_val,
                ch.name,
                attrs,
            );
        } else {
            empty_step = true;
        }
    }

    if (corrupted_marker) return error.CorruptedMarker;
    if (empty_step) return error.EmptySteps;
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
