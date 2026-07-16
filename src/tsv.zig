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

    // Create parameter table to store the attributes
    var param_table = ParamTable{ .allocator = allocator };
    defer param_table.deinit();

    // Get the channel name
    const name_marker = try reader.takeDelimiter('\n');
    if (name_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, name_marker.?, "# Name: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, name_marker.?[8..], ch.name)) return error.ChannelMismatch;
    try param_table.addAttr("name", name_marker.?[8..]);

    // Get the hint
    const hint_marker = try reader.takeDelimiter('\n');
    if (hint_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, hint_marker.?, "# Hint: ")) return error.MissingAttribute;
    try param_table.addAttr("hint", hint_marker.?[8..]);

    // Get the frequency
    const freq_marker = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq_marker.?, "# Frequency: ")) return error.MissingAttribute;
    try param_table.addAttr("freq", freq_marker.?[13..]);

    // Get the shape
    const shape_str = try reader.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return error.MissingAttribute;
    const shape = try std.fmt.parseInt(usize, shape_str.?[9..], 10);

    // Parse additional attributes if present
    while (reader.peekDelimiterExclusive('\n')) |line| {
        if (std.mem.find(u8, line, ":")) |idx| {
            try param_table.addAttr(line[2..idx], line[idx + 2 ..]);
            reader.toss(line.len + 1);
        } else break;
    } else |err| { return err; }

    const freq = param_table.attrs.items[2].value;

    if (std.mem.eql(u8, freq, "continuous")) {
        try parseContinuous(reader, h5f, ch, shape, param_table.attrs.items, allocator, options);
    } else if (std.mem.eql(u8, freq, "step")) {
        try parseStep(reader, h5f, ch, shape, param_table.attrs.items, allocator, options);
    } else {
        return error.UnsupportedChannel;
    }
}

fn parseStep(
    reader: *std.Io.Reader,
    h5f: *hdf5.File,
    ch: metro.Channel,
    shape: usize,
    attrs: []hdf5.StrAttr,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    const ncols: usize = if (shape == 0) 1 else shape;

    // Keep track of scan markers in the file
    var scan_marker: [4096]u8 = undefined;
    var scan_idx: ?usize = null;

    // Channles with "step" frequency don't have step markers
    var step_idx: usize = 0;

    // Store data in array list
    var data = try allocator.alloc(f64, ncols);
    defer allocator.free(data);

    // Read the line by line
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
                    options,
                );
                step_idx += 1;
            }
        }

        // Is it a scan marker?
        if (std.mem.startsWith(u8, line, "# SCAN ")) {
            // Update scan index and reset step marker
            @memcpy(scan_marker[0..line.len], line);
            scan_idx = std.fmt.parseInt(usize, scan_marker[7..line.len], 10) catch null;
            step_idx = 0;
        }
    }
}

fn parseContinuous(
    reader: *std.Io.Reader,
    h5f: *hdf5.File,
    ch: metro.Channel,
    shape: usize,
    attrs: []hdf5.StrAttr,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    const ncols: usize = if (shape == 0) 1 else shape;

    // Keep track of scan and step markers in the file
    var scan_marker: [4096]u8 = undefined;
    var scan_idx: ?usize = null;
    var step_marker: [4096]u8 = undefined;
    var step_idx: ?usize = null;
    var step_val: ?[]u8 = null;

    // Store data in array list
    var data: std.ArrayList(f64) = try .initCapacity(allocator, 1024 * ncols);
    defer data.deinit(allocator);

    // Read the line by line
    while (try reader.takeDelimiter('\n')) |line| {
        // Try parse as value first
        if (step_idx != null) {
            // Append data and continue to next line if parsing is succesful
            var it = std.mem.splitScalar(u8, line, '\t');
            var n: usize = 0;
            while (it.next()) |col| {
                const val = std.fmt.parseFloat(f64, col) catch break;
                try data.append(allocator, val);
                n += 1;
            }

            // Check if the line matched the expected shape
            if (n == ncols) {
                // Continue to next line if parsing was succesful
                continue;
            } else if (n != 0) {
                // Line is partially degraded, skipping...
                data.shrinkRetainingCapacity(data.items.len - n);
            }
        }

        // Is it a scan marker?
        if (std.mem.startsWith(u8, line, "# SCAN ")) {
            // Write dataset to hdf5 before continuing with next scan
            if (step_idx != null and data.items.len > 0) {
                try h5f.writeSimpleDset(
                    f64,
                    data.items,
                    shape,
                    scan_idx.?,
                    step_idx.?,
                    step_val.?,
                    ch.name,
                    attrs,
                    options,
                );
                data.clearRetainingCapacity();
            }

            // Update scan index and reset step marker
            @memcpy(scan_marker[0..line.len], line);
            scan_idx = std.fmt.parseInt(usize, scan_marker[7..line.len], 10) catch null;
            step_idx = null;

            // Get next line
            continue;
        }

        // Is it a step marker?
        if (std.mem.startsWith(u8, line, "# STEP ")) {
            // Step marker should never come without a scan marker
            if (scan_idx == null) return error.MissingMarker;

            // Write dataset to hdf5 before continuing with next step
            if (step_idx != null and data.items.len > 0) {
                try h5f.writeSimpleDset(
                    f64,
                    data.items,
                    shape,
                    scan_idx.?,
                    step_idx.?,
                    step_val.?,
                    ch.name,
                    attrs,
                    options,
                );
                data.clearRetainingCapacity();
            }

            // Find start of step value in line and update
            if (std.mem.find(u8, line, ":")) |idx| {
                @memcpy(step_marker[0..line.len], line);
                step_idx = std.fmt.parseInt(usize, step_marker[7..idx], 10) catch null;
                step_val = step_marker[idx + 2 .. line.len];
            } else return error.CorruptedMarker;
        }
    }

    // Write last dataset to hdf5
    if (step_idx != null and data.items.len > 0) {
        try h5f.writeSimpleDset(
            f64,
            data.items,
            shape,
            scan_idx.?,
            step_idx.?,
            step_val.?,
            ch.name,
            attrs,
            options,
        );
    }
}

const ParamTable = struct {
    attrs: std.ArrayList(hdf5.StrAttr) = .empty,
    allocator: std.mem.Allocator,

    pub fn addAttr(self: *@This(), name: []const u8, value: []const u8) !void {
        const cname = try self.allocator.dupeSentinel(u8, name, 0);
        errdefer self.allocator.free(cname);
        const cvalue = try self.allocator.dupeSentinel(u8, value, 0);
        errdefer self.allocator.free(cvalue);
        var attr = try hdf5.StrAttr.init(cname, cvalue);
        errdefer attr.deinit();
        try self.attrs.append(self.allocator, attr);
    }

    pub fn deinit(self: *@This()) void {
        for (self.attrs.items) |*attr| {
            self.allocator.free(attr.name);
            self.allocator.free(attr.value);
            attr.deinit();
        }
        self.attrs.deinit(self.allocator);
    }
};
