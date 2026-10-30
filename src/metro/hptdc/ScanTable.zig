const ScanTable = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

scans: std.ArrayList(StepTable) = .empty,
allocator: std.mem.Allocator,
offset: i64,
size: i32,
old_style: bool,
rebuild: bool,

pub const StepTable = @import("StepTable.zig");

pub fn init(
    allocator: Allocator,
    offset: i64,
    size: i32,
    old_style: bool,
    rebuild: bool,
) ScanTable {
    return .{
        .allocator = allocator,
        .offset = offset,
        .size = size,
        .old_style = old_style,
        .rebuild = rebuild,
    };
}

pub fn parseOrRebuild(
    self: *ScanTable,
    comptime Marker: type,
    comptime Datum: type,
    file_reader: *std.Io.File.Reader,
) !void {
    if (self.rebuild) {
        try self.rebuild_table(Marker, Datum, file_reader);
    } else if (self.old_style) {
        self.parse_table(i32, Datum, file_reader) catch {
            try self.rebuild_table(Marker, Datum, file_reader);
        };
    } else {
        self.parse_table(i64, Datum, file_reader) catch {
            try self.rebuild_table(Marker, Datum, file_reader);
        };
    }
}

fn append(self: *@This(), step_table: StepTable) !void {
    try self.scans.append(self.allocator, step_table);
}

fn parse_table(
    self: *@This(),
    comptime Entry: type,
    comptime Datum: type,
    file_reader: *std.Io.File.Reader,
) !void {
    // Go to scan table start
    try file_reader.seekTo(@intCast(self.offset));

    var reader = &file_reader.interface;
    var scan_idx: i32 = 0;

    while (scan_idx < self.size) {
        // Create a new step table and deinit on error
        var step_table = StepTable{ .allocator = self.allocator };
        errdefer step_table.deinit();

        const step_count = try reader.takeInt(i32, .little);
        const step_table_size = try reader.takeInt(i32, .little);
        _ = &step_table_size;
        var step_idx: i32 = 0;

        while (step_idx < step_count) {
            const value = try reader.take(32);
            const data_offset = try reader.takeInt(Entry, .little);
            const data_size = try reader.takeInt(Entry, .little);
            if (data_size < 0 or @mod(data_size, @sizeOf(Datum)) != 0) {
                return error.CorruptedStepTable;
            } else {
                try step_table.append(value, data_offset, data_size);
            }
            step_idx += 1;
        }
        try self.append(step_table);
        scan_idx += 1;
    }
}

fn rebuild_table(
    self: *@This(),
    comptime Marker: type,
    comptime Datum: type,
    file_reader: *std.Io.File.Reader,
) !void {
    comptime {
        if (@hasField(Marker, "scan_marker")) {
            @compileError("Field scan_marker required");
        }
        if (@hasField(Marker, "step_marker")) {
            @compileError("Field step_marker required");
        }
    }
    // Clear any step tables added during parsing
    for (self.scans.items) |*step_table| {
        step_table.deinit();
    }
    self.scans.clearRetainingCapacity();

    // Go to the beginning of the file
    try file_reader.seekTo(5);

    var reader = &file_reader.interface;

    // Find the first scan marker
    while (reader.peekStruct(Marker, .little)) |marker| {
        // Stop when the first scan marker is found
        if (marker == Marker.scan_marker) break;
        // Advance by one byte and try again
        reader.toss(1);
    } else |_| {
        return error.MissingMarkerFirst;
    }

    // Current seek position is at the first scan marker

    while (reader.peekStruct(Marker, .little)) |marker| {
        // End of data
        if (marker != Marker.scan_marker) break;

        // Advance to the step marker
        reader.toss(@sizeOf(Marker));

        // Get the current seek position
        var data_offset: usize = file_reader.logicalPos();

        // Check if next is actually a step marker
        if (try reader.takeStruct(Marker, .little) != Marker.step_marker) break;

        // Create a new step table and deinit on error
        var step_table = StepTable{ .allocator = self.allocator };
        errdefer step_table.deinit();

        // Keep track of data size
        var data_size: usize = 0;

        while (reader.peekStruct(Marker, .little)) |data_or_marker| {
            if (data_or_marker == Marker.step_marker) {
                // Found next step marker: append last step to the table
                try step_table.append(null, @intCast(data_offset), @intCast(data_size));
                // Remember position before tossing the marker
                data_offset = file_reader.logicalPos();
                data_size = 0;
                // Advance by size of the marker
                reader.toss(@sizeOf(Marker));
            } else if (data_or_marker == Marker.scan_marker) {
                // Found next scan marker: append last step to the table and break
                try step_table.append(null, @intCast(data_offset), @intCast(data_size));
                break;
            } else {
                // Advance by size of data
                reader.toss(@sizeOf(Datum));
                // Increment the data size
                data_size += @sizeOf(Datum);
            }
        } else |_| {
            // EndOfStream or ReadFailed
            try step_table.append(null, @intCast(data_offset), @intCast(data_size));
        }
        // Append the step table
        try self.append(step_table);
    } else |_| {}
}

pub fn deinit(self: *@This()) void {
    for (self.scans.items) |*step_table| {
        step_table.deinit();
    }
    self.scans.deinit(self.allocator);
}
