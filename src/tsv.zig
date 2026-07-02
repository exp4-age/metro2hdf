const std = @import("std");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

pub fn parseChannel(
    run: metro.Run,
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    // Initialize the reader
    const buf_size = 4096;
    var read_buffer: [buf_size]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);

    // Get the channel name
    const name = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, name.?, "# Name: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, name.?[8..], run.channel)) return error.ChannelMismatch;

    // Get the hint
    const hint = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, hint.?, "# Hint: ")) return error.MissingAttribute;

    // Get the frequency
    const freq = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq.?, "# Frequency: ")) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, freq.?[13..], "continuous")) return error.UnsupportedChannel;

    // Get the shape
    const shape_str = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return error.MissingAttribute;
    const shape = try std.fmt.parseInt(u32, shape_str.?[9..], 10);

    // Keep track of scan and step markers in the file
    var scan_marker: [buf_size]u8 = undefined;
    var scan_idx: ?[]u8 = null;
    var step_marker: [buf_size]u8 = undefined;
    var step_val: ?[]u8 = null;
    // var step_val: ?f64 = null;

    // Store data in array list
    var data: std.ArrayList(f64) = .empty;
    defer data.deinit(allocator);

    // Allocate a reasonable amount of memory
    const capacity = if (shape == 0) 1024 else 1024 * shape;
    try data.ensureTotalCapacity(allocator, capacity);

    while (true) {
        // Read the next line
        var line = try reader.interface.takeDelimiter('\n');

        // Are we at EOF?
        if (line == null) {
            // Write dataset to hdf5
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }
            break;
        }

        // Try parse as value first
        if (step_val != null) {
            // Append data and continue to next line if parsing is succesful
            if (shape == 0) {
                // Try parse line as a float
                if (std.fmt.parseFloat(f64, line.?)) |val| {
                    try data.append(allocator, val);
                    continue;
                } else |_| {}
            } else {
                // Try parse line as float seperated by tabs
                var it = std.mem.splitScalar(u8, line.?, '\t');
                var n: usize = 0;
                while (it.next()) |col| {
                    if (std.fmt.parseFloat(f64, col)) |val| {
                        try data.append(allocator, val);
                        n += 1;
                    } else |_| {
                        break;
                    }
                }
                if (n == shape) {
                    // Continue to next line if parsing was succesful
                    continue;
                } else if (n != 0 and n < shape) {
                    // Line is partially degraded, skipping...
                    data.shrinkRetainingCapacity(data.items.len - n);
                } else if (n > shape) {
                    return error.ShapeMismatch;
                }
            }
        }

        // Is it a scan marker?
        if (std.mem.startsWith(u8, line.?, "# SCAN ")) {
            // Write dataset to hdf5 before continuing with next scan
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }

            // Update scan index and reset step marker
            @memcpy(scan_marker[0..line.?.len], line.?);
            scan_idx = scan_marker[7..line.?.len];
            step_val = null;

            // Already get next line (should be the step marker)
            line = try reader.interface.takeDelimiter('\n');
        }

        // Is it a step marker?
        if (std.mem.startsWith(u8, line.?, "# STEP ")) {
            // Step marker should never come without a scan marker
            if (scan_idx == null) return error.MissingMarker;

            // Write dataset to hdf5 before continuing with next step
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }

            // Find start of step value in line and update
            if (std.mem.find(u8, line.?, ":")) |idx| {
                @memcpy(step_marker[0..line.?.len], line.?);
                step_val = step_marker[idx+2..line.?.len];
            } else return error.MissingMarker;
        }

        // Ahh shibal... something is wrong, try next line...
    }
}
