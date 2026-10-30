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
    options: metro.Options,
) !void {
    const col_num: usize = if (shape == 0) 1 else shape;
    const chunk_size = options.chunk_size;

    // Allocate a row buffer
    const row_buf = try allocator.alloc(f64, col_num);
    defer allocator.free(row_buf);

    // Allocate one reusable chunk buffer when chunking is enabled
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
            var h5d: hdf5.BufferedDset(f64) =
                if (chunk_buf) |buf|
                    .chunked(buf, path, shape, h5f.id)
                else
                    .allocating(allocator, path, shape, h5f.id);
            defer h5d.close();

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
                    try h5d.appendRow(row_buf);
                } else {
                    if (std.mem.startsWith(u8, line, "# SCAN ")) break;
                    if (std.mem.startsWith(u8, line, "# STEP ")) break;
                }

                reader.toss(line.len + 1);
            } else |_| {}

            // Write the buffered data to the hdf5 file
            try h5d.flush();
            if (!h5d.exists()) continue;
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
