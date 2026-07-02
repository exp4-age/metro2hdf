const std = @import("std");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

pub const HptdcError = error {
    UnsupportedVersion,
    BrokenHeader,
};

const HptdcStepEntry = extern struct {
    value: [32]u8,
    data_offset: i64,
    data_size: i64,
};

const HptdcHit = packed struct {
    time: i64,
    channel: u8,
    type: u8,
    bin: u16,
    align_: i32,
};

pub fn parseChannel(
    run: metro.Run,
    file: *std.Io.File,
    h5f: *hdf5.File,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    _ = &h5f;
    _ = &run;

    // Initialize the reader
    const buf_size = 4096;
    var read_buffer: [buf_size]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);

    if (!std.mem.eql(u8, try reader.interface.take(5), "HPTDC")) return HptdcError.BrokenHeader;

    const Header = packed struct {
        size: i32,
        version: i32,
    };

    const header = try reader.interface.takeStruct(Header, .little);
    if (header.size > 4096) return HptdcError.UnsupportedVersion;
    if (header.size < 32) return HptdcError.BrokenHeader;

    const mode = try reader.interface.take(4);
    std.log.info("  hptdc mode: {s}", .{mode});

    const Table = packed struct {
        offset: i64,
        size: i32,
    };

    const scan_table = try reader.interface.takeStruct(Table, .little);
    if (scan_table.offset < header.size + 4) return HptdcError.BrokenHeader;
    const param_table = try reader.interface.takeStruct(Table, .little);
    std.log.info("  param table size: {d}", .{param_table.size});

    // Skip additional header if present
    const remaining_header: usize = @intCast(header.size - 32);
    try reader.interface.discardAll(remaining_header);

    // Next should be 'DATA' in supported version
    if (!std.mem.eql(u8, try reader.interface.take(4), "DATA")) return HptdcError.UnsupportedVersion;

    // Go to scan table start
    const skip_bytes: usize = @intCast(scan_table.offset - header.size - 4);
    try reader.interface.discardAll(skip_bytes);

    const Step = packed struct {
        count: i32,
        table_size: i32,
    };

    var step_tables: std.ArrayList(HptdcStepEntry) = .empty;
    defer step_tables.deinit(allocator);

    while (reader.interface.takeStruct(Step, .little)) |_| {
        while (reader.interface.takeStruct(HptdcStepEntry, .little)) |step_table| {
            if (step_table.data_size < 0 or @mod(step_table.data_size, 14) != 0) {
                step_tables.clearRetainingCapacity();
                break;
            } else {
                try step_tables.append(allocator, step_table);
            }
        } else |_| {}
    } else |_| {}

    if (step_tables.items.len == 0) {
        std.log.info("  rebuild step stable", .{});
    } else {
        std.log.info("  step stable ok", .{});
    }

    const scan_marker = HptdcHit{
        .time = -1,
        .channel = 0xff,
        .type = 0xa0,
        .bin = 0x0000,
        .align_ = 0,
    };
    std.log.info(" scan marker time: {d}", .{scan_marker.channel});
    const step_marker = HptdcHit{
        .time = -1,
        .channel = 0xff,
        .type = 0xb0,
        .bin = 0x0000,
        .align_ = 0,
    };
    std.log.info(" scan marker time: {d}", .{step_marker.type});

    return HptdcError.UnsupportedVersion;
}
