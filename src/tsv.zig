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
    var reader = file.readerStreaming(io, &read_buffer);

    // Get the channel name
    const name_marker = try reader.interface.takeDelimiter('\n');
    if (name_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, name_marker.?, "# Name: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, name_marker.?[8..], ch.name)) return error.ChannelMismatch;
    const name = try allocator.dupeSentinel(u8, ch.name, 0);
    defer allocator.free(name);

    // Get the hint
    const hint_marker = try reader.interface.takeDelimiter('\n');
    if (hint_marker == null) return error.MissingAttribute;
    if (!std.mem.startsWith(u8, hint_marker.?, "# Hint: ")) return error.MissingAttribute;
    const hint = try allocator.dupeSentinel(u8, hint_marker.?[8..], 0);
    defer allocator.free(hint);

    // Get the frequency
    const freq = "continuous";
    const freq_marker = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq_marker.?, "# Frequency: ")) return error.MissingAttribute;
    if (!std.mem.eql(u8, freq_marker.?[13..], freq)) return error.UnsupportedChannel;

    // Get the shape
    const shape_str = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return error.MissingAttribute;
    const shape = try std.fmt.parseInt(usize, shape_str.?[9..], 10);
    const ncols: usize = if (shape == 0) 1 else shape;

    // Create attribute list
    var name_attr = try hdf5.StrAttr.init("name", name);
    defer name_attr.deinit();
    var hint_attr = try hdf5.StrAttr.init("hint", hint);
    defer hint_attr.deinit();
    var freq_attr = try hdf5.StrAttr.init("freq", freq);
    defer freq_attr.deinit();
    var attrs: [3]hdf5.StrAttr = .{ name_attr, hint_attr, freq_attr };

    // Keep track of scan and step markers in the file
    var scan_marker: [buf_size]u8 = undefined;
    var scan_idx: ?usize = null;
    var step_marker: [buf_size]u8 = undefined;
    var step_idx: ?usize = null;
    var step_val: ?[]u8 = null;

    // Store data in array list
    var data: std.ArrayList(f64) = try .initCapacity(allocator, 1024 * ncols);
    defer data.deinit(allocator);

    // Read the line by line
    while (try reader.interface.takeDelimiter('\n')) |line| {
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
                    &attrs,
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
                    &attrs,
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
            &attrs,
            options,
        );
    }
}
