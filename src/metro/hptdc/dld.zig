const std = @import("std");
const metro = @import("../../metro.zig");
const hdf5 = @import("../../hdf5.zig");
const ScanTable = @import("ScanTable.zig");

const Hit = packed struct {
    time: i64,
    channel: u8,
    type: u8,
    bin: u16,
    @"align": i32,

    pub const scan_marker = Hit{
        .time = -1,
        .channel = 0xff,
        .type = 0xa0,
        .bin = 0x0000,
        .@"align" = 0,
    };

    pub const step_marker = Hit{
        .time = -1,
        .channel = 0xff,
        .type = 0xb0,
        .bin = 0x0000,
        .@"align" = 0,
    };
};

pub fn sortEvents(
    ch: metro.Channel,
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    // Parse or rebuild the scan table
    try scan_table.parseOrRebuild(Hit, Hit, file_reader);
    var reader = &file_reader.interface;

    // TDC channel number [0,7] of the MCP signal marking the start of an event
    const mcp_channel: u3 = options.hptdc_hit_mcp;
    // Events are filtered based on which channels triggered using a bit mask
    const filter = options.hptdc_hit_filter;
    var mask: u8 = 0;
    // Buffer for time signals of a single event
    var row_buf: [8]f64 = @splat(0);
    // Allocate one reusable chunk buffer when chunking is enabled
    var chunk_buf: ?[]f64 = null;
    if (options.chunk_size != 0) {
        const chunk_len = @divFloor(options.chunk_size, @sizeOf(f64));
        chunk_buf = try allocator.alloc(f64, chunk_len);
    }
    defer if (chunk_buf) |buf| allocator.free(buf);

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the next step marker location and check if it is one
            try file_reader.seekTo(@intCast(step.data_offset));
            if (try reader.takeStruct(Hit, .little) != Hit.step_marker) return error.MissingMarker;
            // Skip to the next step if there is no data before creating the dataset
            if (step.data_size < @sizeOf(Hit)) continue;

            // Create an empty chunked dataset at scan_idx/by_idx/step_idx/name
            const path = try allocator.printSentinel("{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, ch.name }, 0);
            defer allocator.free(path);
            var h5d: hdf5.BufferedDset(f64) =
                if (chunk_buf) |buf|
                    .chunked(buf, path, 8, h5f.id)
                else
                    .allocating(allocator, path, 8, h5f.id);
            defer h5d.close();

            var size: i64 = 0;
            while (size < step.data_size) : (size += @sizeOf(Hit)) {
                const hit = try reader.takeStruct(Hit, .little);

                // More than 8 tdc channels are currently not supported
                if (hit.channel > 7) {
                    @branchHint(.unlikely);
                    continue;
                }

                if (hit.channel == mcp_channel) {
                    // Append previous event to the dataset (the chunk buffer is
                    // automatically written to the hdf5 file when it is full)
                    if (mask == filter) try h5d.appendRow(&row_buf);
                    // Reset times and mask for the next event
                    row_buf = @splat(0);
                    mask = 0;
                }

                // Bit mask corresponding to the channel of the hit
                const shift: u3 = @intCast(hit.channel);
                const bit: u8 = @as(u8, 1) << shift;
                // Check if this is the first occurence of this channel for this event,
                // if a channel triggered multiple times only the first time is used
                if (mask & bit == 0) {
                    // Store the time in the buffer and update the mask
                    row_buf[hit.channel] = @floatFromInt(hit.time);
                    mask |= bit;
                }
            }

            // Append the last event
            if (mask == filter) try h5d.appendRow(&row_buf);
            // Write the dataset / the last chunk
            try h5d.flush();
            // Skip to the next step if the dataset was empty
            if (!h5d.exists()) continue;

            // Write attributes to the dataset
            h5a.write(h5d.id()) catch {};
            // Create a shortcut link scan_idx/step_val pointing to scan_idx/by_idx/step_idx
            if (step.value) |step_val| {
                const target = try allocator.printSentinel("{d}/by_idx/{d}", .{ scan_idx, step_idx }, 0);
                defer allocator.free(target);
                const link = try allocator.printSentinel("{d}/{s}", .{ scan_idx, step_val }, 0);
                defer allocator.free(link);
                h5f.createLink(target, link) catch {};
            }
        }
    }
}
