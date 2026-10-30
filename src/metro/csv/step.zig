const std = @import("std");
const metro = @import("../../metro.zig");
const hdf5 = @import("../../hdf5.zig");

pub fn parse(
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
