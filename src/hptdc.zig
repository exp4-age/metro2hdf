const std = @import("std");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

pub fn parseChannel(
    ch: metro.Channel,
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    // Initialize the reader
    const buf_size = 4096;
    var read_buffer: [buf_size]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var reader = &file_reader.interface;

    // Check for HPTDC marker
    if (!std.mem.eql(u8, try reader.take(5), "HPTDC")) return error.CorruptedHeader;

    // Starting in around October 2017, a reworked (and extendable)
    // header format was introduced. We only support those newer
    // versions: use the python version of metro2hdf for older versions
    const header_size = try reader.takeInt(i32, .little);
    if (header_size > 4096) return error.UnsupportedVersion;
    if (header_size < 32) return error.CorruptedHeader;

    const version = try reader.takeInt(i32, .little);
    _ = &version;

    // HPTDC mode (HITS, GRPS)
    const mode = try reader.take(4);

    if (std.mem.eql(u8, mode, "HITS")) {
        try parseHITS(ch, &file_reader, header_size, h5f, allocator);
    }
}

pub fn parseHITS(
    ch: metro.Channel,
    file_reader: *std.Io.File.Reader,
    header_size: i32,
    h5f: *hdf5.File,
    allocator: std.mem.Allocator,
) !void {
    var reader = &file_reader.interface;

    // Where and how big is the scan table?
    const scan_table_offset = try reader.takeInt(i64, .little);
    const scan_table_size = try reader.takeInt(i32, .little);
    if (scan_table_offset < header_size + 4) return error.CorruptedHeader;

    // Where and how big is the parameter table?
    const param_table_offset = try reader.takeInt(i64, .little);
    const param_table_size = try reader.takeInt(i32, .little);

    // Skip additional header if present
    // header_size does not include "HPTDC" and i32 header_size itself,
    // so add 9 bytes
    try file_reader.seekTo(@intCast(header_size + 9));

    // Next should be 'DATA' in supported versions
    if (!std.mem.eql(u8, try reader.take(4), "DATA")) return error.UnsupportedVersion;

    // Go to scan table start
    // const scan_table_offset: usize = @intCast(scan_table.offset);
    // try reader.discardAll(scan_table_offset - reader.seek);
    // const scan_table_offset_u64: u64 = @intCast(scan_table_offset);
    // try file_reader.seekTo(scan_table_offset_u64);
    try file_reader.seekTo(@intCast(scan_table_offset));

    var scan_table = ScanTable{.allocator = allocator};
    defer scan_table.deinit();

    var scan_idx: i32 = 0;

    while (scan_idx < scan_table_size) {
        // Create a new step table
        var step_table = StepTable{.allocator=allocator};
        errdefer step_table.deinit();
        // try scan_table.addScan();

        const step_count = try reader.takeInt(i32, .little);
        const step_table_size = try reader.takeInt(i32, .little);
        _ = &step_table_size;
        var step_idx: i32 = 0;

        while (step_idx < step_count) {
            const value = try reader.take(32);
            const data_offset = try reader.takeInt(i64, .little);
            const data_size = try reader.takeInt(i64, .little);
            if (data_size < 0 or @mod(data_size, 16) != 0) {
                return error.CorruptedStepTable;
            } else {
                try step_table.append(value, data_offset, data_size);
            }
            step_idx += 1;
        }
        try scan_table.append(step_table);
        scan_idx += 1;
    }

    const scan_marker = HptdcHit{
        .time = -1,
        .channel = 0xff,
        .type = 0xa0,
        .bin = 0x0000,
        .@"align" = 0,
    };
    const step_marker = HptdcHit{
        .time = -1,
        .channel = 0xff,
        .type = 0xb0,
        .bin = 0x0000,
        .@"align" = 0,
    };

    scan_idx = 0;
    var buf: [10]u8 = undefined;

    // Create attribute list
    const name = try allocator.dupeSentinel(u8, ch.name, 0);
    defer allocator.free(name);
    var name_attr = try hdf5.StrAttr.init("name", name);
    defer name_attr.deinit();
    const mode = "HITS";
    var mode_attr = try hdf5.StrAttr.init("mode", mode);
    defer mode_attr.deinit();
    var attrs: [2]hdf5.StrAttr = .{name_attr, mode_attr};

    for (scan_table.scans.items) |step_table| {
        const scan_idx_str = try std.fmt.bufPrintSentinel(&buf, "{d}", .{scan_idx}, 0);

        for (step_table.steps.items) |step| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeStruct(HptdcHit, .little) != step_marker) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < @sizeOf(HptdcHit) or @mod(step.data_size, @sizeOf(HptdcHit)) != 0) continue;

            const n: usize = @intCast(@divExact(step.data_size, @sizeOf(HptdcHit)));

            var hits = try allocator.alloc(HptdcHit, n);
            defer allocator.free(hits);

            for (0..n) |i| {
                hits[i] = try reader.takeStruct(HptdcHit, .little);
            }

            try h5f.writeCompoundDset(HptdcHit, scan_idx_str, step.value, ch.name, hits, &attrs);
        }
        scan_idx += 1;
    }

    _ = &param_table_offset;
    _ = &param_table_size;
    _ = &scan_marker;
}

const ScanTable = struct {
    scans: std.ArrayList(StepTable) = .empty,
    allocator: std.mem.Allocator,

    pub fn append(self: *@This(), step_table: StepTable) !void {
        try self.scans.append(self.allocator, step_table);
    }

    pub fn deinit(self: *@This()) void {
        for (self.scans.items) |*step_table| {
            step_table.deinit();
        }
        self.scans.deinit(self.allocator);
    }
};

const StepTable = struct {
    steps: std.ArrayList(StepEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn append(
        self: *@This(),
        step_val: []const u8,
        data_offset: i64,
        data_size: i64,
    ) !void {
        const len = std.mem.findScalar(u8, step_val, 0) orelse step_val.len;
        try self.steps.append(
            self.allocator,
            .{
                .value = try self.allocator.dupeSentinel(u8, step_val[0..len], 0),
                .data_offset = data_offset,
                .data_size = data_size,
            },
        );
    }

    pub fn clearRetainingCapacity(self: *@This()) void {
        for (self.steps.items) |step| {
            self.allocator.free(step.step_val);
        }
        self.steps.clearRetainingCapacity();
    }

    pub fn deinit(self: *@This()) void {
        for (self.steps.items) |step| {
            self.allocator.free(step.value);
        }
        self.steps.deinit(self.allocator);
    }
};

const StepEntry = struct {
    value: []const u8,
    data_offset: i64,
    data_size: i64,
};

const HptdcHit = packed struct {
    time: i64,
    channel: u8,
    type: u8,
    bin: u16,
    @"align": i32,
};

