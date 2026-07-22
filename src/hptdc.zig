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
    var file_reader = file.reader(io, &read_buffer);
    var reader = &file_reader.interface;

    var rebuild_tables = options.hptdc_rebuild_tables;

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
    var buf: [5]u8 = undefined;
    const mode = try std.fmt.bufPrintSentinel(&buf, "{s}", .{try reader.take(4)}, 0);

    // Where and how big is the scan table?
    const scan_table_offset = try reader.takeInt(i64, .little);
    const scan_table_size = try reader.takeInt(i32, .little);
    if (scan_table_offset < header_size + 4) rebuild_tables = true;

    // Where and how big is the parameter table?
    const param_table_offset = try reader.takeInt(i64, .little);
    const param_table_size = try reader.takeInt(i32, .little);

    // Skip additional header if present
    // header_size does not include "HPTDC" and i32 header_size itself,
    // so add 9 bytes
    try file_reader.seekTo(@intCast(header_size + 9));

    // Next should be 'DATA' in supported versions
    if (!std.mem.eql(u8, try reader.take(4), "DATA")) return error.UnsupportedVersion;

    // Create and parse parameter table
    var param_table = ParamTable{ .allocator = allocator };
    defer param_table.deinit();
    param_table.addAttr("name", ch.name) catch {};
    param_table.addAttr("mode", mode) catch {};
    param_table.parse(&file_reader, param_table_offset, param_table_size) catch {};

    // Create the scan table
    var scan_table = ScanTable{ .allocator = allocator };
    defer scan_table.deinit();

    if (std.mem.eql(u8, mode, "HITS")) {
        // Parse the scan table for step marker positions and data sizes
        scan_table.parse(Hit, &file_reader, scan_table_offset, scan_table_size) catch {
            rebuild_tables = true;
        };

        // Rebuild the step tables if parse failed or specifically requested
        if (rebuild_tables) try scan_table.rebuild(Hit, Hit, &file_reader);

        // Parse the hits and group them into events
        try parseHits(ch, &file_reader, h5f, &scan_table, &param_table, allocator, options);
    } else if (std.mem.eql(u8, mode, "GRPS")) {
        // Parse the scan table for step marker positions and data sizes
        scan_table.parse(u32, &file_reader, scan_table_offset, scan_table_size) catch {
            rebuild_tables = true;
        };

        // Rebuild the step tables if parse failed or specifically requested
        if (rebuild_tables) try scan_table.rebuild(Word, u32, &file_reader);

        // Parse and decode the words and sort them into events
        try sortEvents(&file_reader, h5f, &scan_table, &param_table, allocator, options);
    } else {
        return error.UnknownHptdcMode;
    }
}

fn sortEvents(
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    param_table: *ParamTable,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    var reader = &file_reader.interface;
    const attrs = param_table.attrs.items;

    // Event type P or I for either EP or EI coincidences
    const p2 = options.hptdc_event_type;

    // Maximum number of particles per paritcle type
    const max_count: usize = 9;

    var events: [max_count + 1][max_count + 1]std.ArrayList(i32) = undefined;
    for (&events) |*row| {
        for (row) |*ev| ev.* = .empty;
    }
    defer for (&events) |*row| {
        for (row) |*ev| ev.deinit(allocator);
    };

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeInt(u32, .little) != 0) return error.MissingMarkerStep;
            if (try reader.takeInt(u32, .little) != 176) return error.MissingMarkerStep;

            // Skip if there is no data
            if (step.data_size < 4 or @mod(step.data_size, 4) != 0) continue;

            // Get the number of words in this step
            const n: usize = @intCast(@divExact(step.data_size, 4));

            // Counters for the electron and photon events per bunch
            var e_count: usize = 0;
            var p_count: usize = 0;

            // Buffers for the event times
            var e_buf: [max_count]i32 = undefined;
            var p_buf: [max_count]i32 = undefined;

            for (0..n) |_| {
                const word = try DecodedWord.decode(try reader.takeInt(u32, .little));
                switch (word.type) {
                    .RL => {
                        // Start of new bunch: process last event
                        // Skip the last event if none or too many were found
                        if (e_count == 0 and p_count == 0) continue;
                        if (e_count > max_count or p_count > max_count) {
                            e_count = 0;
                            p_count = 0;
                            continue;
                        }

                        const ev = &events[e_count][p_count];
                        try ev.appendSlice(allocator, e_buf[0..e_count]);
                        try ev.appendSlice(allocator, p_buf[0..p_count]);

                        // Reset counters for the next bunch
                        e_count = 0;
                        p_count = 0;
                    },
                    .FL => {
                        switch (word.arg1) {
                            1 => {
                                // Add electron to event
                                if (e_count < max_count) e_buf[e_count] = word.arg3;
                                e_count += 1;
                            },
                            2 => {
                                // Add photon to event
                                if (p_count < max_count) p_buf[p_count] = word.arg3;
                                p_count += 1;
                            },
                            else => {},
                        }
                    },
                    .RS, .ER, .GR, .LV, .@"??" => {},
                }
            }

            for (&events, 0..) |*row, i| {
                for (row, 0..) |*ev, j| {
                    if (i == 0 and j == 0) continue;

                    // Skip if no events where found for this category
                    if (ev.items.len == 0) continue;

                    // Create name for the dataset
                    var name_buf: [8]u8 = undefined;
                    var name = try std.fmt.bufPrint(&name_buf, "{d}E{d}{c}", .{ i, j, p2 });
                    if (j == 0) {
                        name = try std.fmt.bufPrint(&name_buf, "{d}E", .{i});
                    } else if (i == 0) {
                        name = try std.fmt.bufPrint(&name_buf, "{d}{c}", .{ j, p2 });
                    }

                    // Set shape to 0 for a single particle
                    const shape = if (i + j == 1) 0 else i + j;

                    // Write the dataset
                    try h5f.writeSimpleDset(i32, ev.items, shape, scan_idx, step_idx, step.value, name, attrs, options);

                    // Clear the list for the next step
                    ev.clearRetainingCapacity();
                }
            }
        }
    }
}

fn parseHits(
    ch: metro.Channel,
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    param_table: *ParamTable,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    var reader = &file_reader.interface;

    // Get the tdc channel number of the MCP signal
    const mcp_channel: u8 = @intCast(options.hptdc_hit_mcp);

    // Filter events based on which channels triggered using a bit mask
    var mask: u8 = 0;
    const filter = options.hptdc_hit_filter;

    // Accumulate time signals of a single event in an array
    var times: [8]i64 = @splat(0);

    var data: std.ArrayList(i64) = .empty;
    defer data.deinit(allocator);

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeStruct(Hit, .little) != Hit.step_marker) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < @sizeOf(Hit) or @mod(step.data_size, @sizeOf(Hit)) != 0) continue;

            const n: usize = @intCast(@divExact(step.data_size, @sizeOf(Hit)));

            for (0..n) |_| {
                const hit = try reader.takeStruct(Hit, .little);

                if (hit.channel == mcp_channel) {
                    // New MCP signal: process last event
                    if (mask == filter) {
                        try data.appendSlice(allocator, &times);
                    }

                    // Reset times and mask
                    times = @splat(0);
                    mask = 0;
                } else if (hit.channel > 7) {
                    // More than 8 tdc channels are currently not supported
                    continue;
                }

                // Bit mask corresponding to the channel
                const shift: u3 = @intCast(hit.channel);
                const bit: u8 = @as(u8, 1) << shift;

                // Check if this is the first occurence of this channel for this event,
                // if a channel triggered multiple times only the first time is used
                if (~mask & bit != 0) {
                    // Store the time and update the mask
                    times[hit.channel] = hit.time;
                    mask |= bit;
                }
            }

            // Write the dataset to the hdf5 file
            try h5f.writeSimpleDset(i64, data.items, 8, scan_idx, step_idx, step.value, ch.name, param_table.attrs.items, options);

            // Clear the data of this step but keep capacity for the next step
            data.clearRetainingCapacity();
        }
    }
}

const ScanTable = struct {
    scans: std.ArrayList(StepTable) = .empty,
    allocator: std.mem.Allocator,

    pub fn append(self: *@This(), step_table: StepTable) !void {
        try self.scans.append(self.allocator, step_table);
    }

    pub fn parse(
        self: *@This(),
        comptime T: type,
        file_reader: *std.Io.File.Reader,
        offset: i64,
        size: i32,
    ) !void {
        // Go to scan table start
        try file_reader.seekTo(@intCast(offset));

        var reader = &file_reader.interface;
        var scan_idx: i32 = 0;

        while (scan_idx < size) {
            // Create a new step table and deinit on error
            var step_table = StepTable{ .allocator = self.allocator };
            errdefer step_table.deinit();

            const step_count = try reader.takeInt(i32, .little);
            const step_table_size = try reader.takeInt(i32, .little);
            _ = &step_table_size;
            var step_idx: i32 = 0;

            while (step_idx < step_count) {
                const value = try reader.take(32);
                const data_offset = try reader.takeInt(i64, .little);
                const data_size = try reader.takeInt(i64, .little);
                if (data_size < 0 or @mod(data_size, @sizeOf(T)) != 0) {
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

    pub fn rebuild(
        self: *@This(),
        comptime MarkerT: type,
        comptime DataT: type,
        file_reader: *std.Io.File.Reader,
    ) !void {
        comptime {
            if (@hasField(MarkerT, "scan_marker")) {
                @compileError("Field scan_marker required");
            }
            if (@hasField(MarkerT, "step_marker")) {
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
        while (reader.peekStruct(MarkerT, .little)) |marker| {
            // Stop when the first scan marker is found
            if (marker == MarkerT.scan_marker) break;
            // Advance by one byte and try again
            reader.toss(1);
        } else |_| {
            return error.MissingMarkerFirst;
        }

        // Current seek position is at the first scan marker

        while (reader.peekStruct(MarkerT, .little)) |marker| {
            // End of data
            if (marker != MarkerT.scan_marker) break;

            // Advance to the step marker
            reader.toss(@sizeOf(MarkerT));

            // Get the current seek position
            var data_offset: usize = file_reader.logicalPos();

            // Check if next is actually a step marker
            if (try reader.takeStruct(MarkerT, .little) != MarkerT.step_marker) break;

            // Create a new step table and deinit on error
            var step_table = StepTable{ .allocator = self.allocator };
            errdefer step_table.deinit();

            // Keep track of data size
            var data_size: usize = 0;

            while (reader.peekStruct(MarkerT, .little)) |data_or_marker| {
                if (data_or_marker == MarkerT.step_marker) {
                    // Found next step marker: append last step to the table
                    try step_table.append(null, @intCast(data_offset), @intCast(data_size));
                    // Remember position before tossing the marker
                    data_offset = file_reader.logicalPos();
                    data_size = 0;
                    // Advance by size of the marker
                    reader.toss(@sizeOf(MarkerT));
                } else if (data_or_marker == MarkerT.scan_marker) {
                    // Found next scan marker: append last step to the table and break
                    try step_table.append(null, @intCast(data_offset), @intCast(data_size));
                    break;
                } else {
                    // Advance by size of data
                    reader.toss(@sizeOf(DataT));
                    // Increment the data size
                    data_size += @sizeOf(DataT);
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
};

const StepTable = struct {
    steps: std.ArrayList(StepEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn append(
        self: *@This(),
        step_val: ?[]const u8,
        data_offset: i64,
        data_size: i64,
    ) !void {
        if (step_val) |val| {
            const len = std.mem.findScalar(u8, val, 0) orelse val.len;
            const value = try self.allocator.dupeSentinel(u8, val[0..len], 0);
            errdefer self.allocator.free(value);
            try self.steps.append(
                self.allocator,
                .{
                    .value = value,
                    .data_offset = data_offset,
                    .data_size = data_size,
                },
            );
        } else {
            try self.steps.append(
                self.allocator,
                .{
                    .value = null,
                    .data_offset = data_offset,
                    .data_size = data_size,
                },
            );
        }
    }

    pub fn deinit(self: *@This()) void {
        for (self.steps.items) |*step| {
            if (step.value != null) self.allocator.free(step.value.?);
        }
        self.steps.deinit(self.allocator);
    }
};

const StepEntry = struct {
    value: ?[:0]const u8,
    data_offset: i64,
    data_size: i64,
};

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

    pub fn parse(
        self: *@This(),
        file_reader: *std.Io.File.Reader,
        offset: i64,
        size: i32,
    ) !void {
        try file_reader.seekTo(@intCast(offset));
        const table = try file_reader.interface.take(@intCast(size));
        var params = std.mem.splitScalar(u8, table, '\n');
        while (params.next()) |line| {
            var param = std.mem.splitScalar(u8, line, ' ');
            const name = param.next() orelse continue;
            const value = param.next() orelse continue;
            if (param.next() != null) continue;
            try self.addAttr(name, value);
        }
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

const Hit = packed struct {
    time: i64,
    channel: u8,
    type: u8,
    bin: u16,
    @"align": i32,

    const scan_marker = Hit{
        .time = -1,
        .channel = 0xff,
        .type = 0xa0,
        .bin = 0x0000,
        .@"align" = 0,
    };

    const step_marker = Hit{
        .time = -1,
        .channel = 0xff,
        .type = 0xb0,
        .bin = 0x0000,
        .@"align" = 0,
    };
};

const Word = packed struct {
    word1: u32,
    word2: u32,

    const scan_marker = Word{
        .word1 = 0,
        .word2 = 160,
    };

    const step_marker = Word{
        .word1 = 0,
        .word2 = 176,
    };
};

const DecodedWord = struct {
    type: Type = .@"??",
    arg1: i8 = 0,
    arg2: i8 = 0,
    arg3: i32 = 0,

    const Type = enum {
        FL,
        RS,
        ER,
        GR,
        RL,
        LV,
        @"??",
    };

    pub fn decode(word: u32) !DecodedWord {
        // FL: type_len=2, type_val=2 (top 2 bits == 0b10)
        if ((word >> 30) == 2) {
            return .{
                .type = .FL,
                .arg1 = extractInt(i8, word, 29, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // RS: type_len=2, type_val=3 (top 2 bits == 0b11)
        if ((word >> 30) == 3) {
            return .{
                .type = .RS,
                .arg1 = extractInt(i8, word, 29, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // ER: type_len=2, type_val=1 (top 2 bits == 0b01)
        if ((word >> 30) == 1) {
            return .{
                .type = .ER,
                .arg1 = extractInt(i8, word, 29, 24),
                .arg2 = extractInt(i8, word, 23, 16),
                .arg3 = extractInt(i32, word, 15, 0),
            };
        }

        // GR: type_len=4, type_val=0 (top 4 bits == 0b0000)
        if ((word >> 28) == 0) {
            return .{
                .type = .GR,
                .arg1 = extractInt(i8, word, 27, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // RL: type_len=8, type_val=16 (top 8 bits == 0b00010000)
        if ((word >> 24) == 16) {
            return .{
                .type = .RL,
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // LV: type_len=5, type_val=3 (top 5 bits == 0b00011)
        if ((word >> 27) == 3) {
            return .{
                .type = .LV,
                .arg1 = extractInt(i8, word, 26, 21),
                .arg3 = extractInt(i32, word, 20, 0),
            };
        }

        return .{};
    }

    fn extractInt(comptime T: type, word: u32, comptime high: u5, comptime low: u5) T {
        const width: u5 = high - low;
        comptime {
            const info = @typeInfo(T);
            if (info != .int) @compileError("T must be an integer type");
            if (high <= low) @compileError("high must be > low");
            const bitwidth = if (info.int.signedness == .unsigned) info.int.bits else info.int.bits - 1;
            if (width > bitwidth) @compileError("T is too narrow for given width");
        }
        const mask: u32 = @intCast((@as(u64, 1) << width) - 1);
        const value: u32 = (word >> low) & mask;
        return @intCast(value);
    }
};
