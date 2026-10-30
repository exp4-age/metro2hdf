const std = @import("std");
const metro = @import("../metro.zig");
const hdf5 = @import("../hdf5.zig");
const ScanTable = @import("hptdc/ScanTable.zig");
const coinc = @import("hptdc/coinc.zig");
const dld = @import("hptdc/dld.zig");

const Mode = enum {
    HITS,
    GRPS,
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

    var rebuild_tables = options.hptdc_rebuild_tables;
    var old_style: bool = false;

    // Check for HPTDC marker
    if (!std.mem.eql(u8, try reader.take(5), "HPTDC")) return error.CorruptedHeader;

    // Starting in around October 2017, a reworked (and extendable)
    // header format was introduced. We only support those newer
    // versions: use the python version of metro2hdf for older versions
    const header_size = try reader.takeInt(i32, .little);
    if (header_size > 4096) return error.UnsupportedVersion;
    if (header_size < 32) return error.CorruptedHeader;

    const version = try reader.takeInt(i32, .little);

    var mode: Mode = .HITS;
    var scan_table_offset: i64 = undefined;
    var scan_table_size: i32 = undefined;
    var param_table_offset: i64 = undefined;
    var param_table_size: i32 = undefined;

    if (std.meta.stringToEnum(Mode, try reader.peek(4))) |m| {
        reader.toss(4);

        // HPTDC mode (HITS, GRPS)
        mode = m;

        // Where and how big is the scan table?
        scan_table_offset = try reader.takeInt(i64, .little);
        if (scan_table_offset < header_size + 4) rebuild_tables = true;
        scan_table_size = try reader.takeInt(i32, .little);
        if (scan_table_size < 0) rebuild_tables = true;

        // Where and how big is the parameter table?
        param_table_offset = try reader.takeInt(i64, .little);
        param_table_size = try reader.takeInt(i32, .little);

        // Skip additional header if present
        // header_size does not include "HPTDC" and i32 header_size itself,
        // so add 9 bytes
        try file_reader.seekTo(@intCast(header_size + 9));

        // Next should be the 'DATA' marker
        if (!std.mem.eql(u8, try reader.take(4), "DATA")) rebuild_tables = true;
    } else {
        // Failed to get the mode: try parsing the old header style
        old_style = true;

        // The old style had no header size and version and offset was i32
        scan_table_offset = header_size;
        scan_table_size = version;
        param_table_offset = try reader.takeInt(i32, .little);
        param_table_size = try reader.takeInt(i32, .little);

        // Assume HITS mode by default unless next byte is 'G'
        if (try reader.takeByte() == 'G') mode = .GRPS;
    }

    // Create and parse parameter table, it is okay if it fails
    var h5a: hdf5.AttrList = try .init(allocator);
    defer h5a.deinit();
    h5a.append("name", ch.name) catch {};
    h5a.append("mode", @tagName(mode)) catch {};
    if (param_table_size > 0 and param_table_offset > header_size) {
        parseParamTable(&h5a, &file_reader, param_table_offset, param_table_size) catch {};
    }

    // Initialize the scan table with parsed settings (parseOrRebuild is called by sortEvents)
    var scan_table: ScanTable = .init(allocator, scan_table_offset, scan_table_size, old_style, rebuild_tables);
    defer scan_table.deinit();

    switch (mode) {
        .HITS => {
            try dld.sortEvents(ch, &file_reader, h5f, &scan_table, &h5a, allocator, options);
        },
        .GRPS => {
            try coinc.sortEvents(&file_reader, h5f, &scan_table, &h5a, allocator, options);
        },
    }
}

fn parseParamTable(
    h5a: *hdf5.AttrList,
    file_reader: *std.Io.File.Reader,
    offset: i64,
    size: i32,
) !void {
    // Read the entire parameter table
    try file_reader.seekTo(@intCast(offset));
    const table = try file_reader.interface.take(@intCast(size));

    // Parse line by line
    var params = std.mem.splitScalar(u8, table, '\n');
    outer: while (params.next()) |line| {
        var param = std.mem.splitScalar(u8, line, ' ');
        const name = param.next() orelse continue;
        const value = param.next() orelse continue;
        if (param.next() != null) continue;
        for (name) |c| if (!std.ascii.isAlphanumeric(c)) continue :outer;
        try h5a.append(name, value);
    }
}
