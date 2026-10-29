const std = @import("std");
const metro = @import("../metro.zig");
const hdf5 = @import("../hdf5.zig");

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
        appendParamTable(&h5a, &file_reader, param_table_offset, param_table_size) catch {};
    }

    var scan_table: ScanTable = .{ .allocator = allocator };
    defer scan_table.deinit();

    switch (mode) {
        .HITS => {
            // Parse or rebuild the scan table
            try scan_table.parseOrRebuild(
                Hit,
                Hit,
                &file_reader,
                scan_table_offset,
                scan_table_size,
                old_style,
                rebuild_tables,
            );

            // Parse the hits and group them into events
            try parseHits(ch, &file_reader, h5f, &scan_table, &h5a, allocator, options);
        },
        .GRPS => {
            // Parse or rebuild the scan table
            try scan_table.parseOrRebuild(
                Word,
                u32,
                &file_reader,
                scan_table_offset,
                scan_table_size,
                old_style,
                rebuild_tables,
            );

            // Parse and decode the words and sort them into events
            try sortEvents(&file_reader, h5f, &scan_table, &h5a, allocator, options);
        },
    }
}

fn sortEvents(
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    var reader = &file_reader.interface;

    // HPTDC channel numbers (currently only one configuration supported)
    const electron_channel: i8 = 1;
    const photon_channel: i8 = 2;

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

            // Counters for the electron and photon events per bunch
            var e_count: usize = 0;
            var p_count: usize = 0;

            // Buffers for the event times
            var e_buf: [max_count]i32 = undefined;
            var p_buf: [max_count]i32 = undefined;

            // Decode the words and sort by event category
            const n: usize = @intCast(@divExact(step.data_size, 4));
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

                        // Append row to the dataset of the event category
                        const ev = &events[e_count][p_count];
                        try ev.appendSlice(allocator, e_buf[0..e_count]);
                        try ev.appendSlice(allocator, p_buf[0..p_count]);

                        // Reset counters for the next bunch
                        e_count = 0;
                        p_count = 0;
                    },
                    .FL => {
                        // Detected a particle: switch on which tdc channel
                        switch (word.arg1) {
                            electron_channel => {
                                if (e_count < max_count) e_buf[e_count] = word.arg3;
                                e_count += 1;
                            },
                            photon_channel => {
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
                    // Skip if no events where found for this category
                    if (ev.items.len == 0) continue;

                    // Create name for the dataset
                    var name_buf: [18]u8 = undefined;
                    var name = try std.fmt.bufPrint(&name_buf, "{d}E{d}{c}", .{ i, j, p2 });
                    if (options.legacy_event_names) {
                        for (0..i) |buf_idx| name_buf[buf_idx] = 'E';
                        for (i..j + i) |buf_idx| name_buf[buf_idx] = p2;
                        name = name_buf[0 .. i + j];
                    } else {
                        if (j == 0) {
                            name = try std.fmt.bufPrint(&name_buf, "{d}E", .{i});
                        } else if (i == 0) {
                            name = try std.fmt.bufPrint(&name_buf, "{d}{c}", .{ j, p2 });
                        }
                    }

                    // Set shape to 0 for a single particle
                    const shape = if (i + j == 1) 0 else i + j;

                    // Write the dataset
                    const path = try allocator.printSentinel("{d}/by_idx/{d}/{s}", .{ scan_idx, step_idx, name }, 0);
                    defer allocator.free(path);
                    var h5d: hdf5.FixedDset(i32) = try .create(h5f.id, path, shape, ev.items);
                    defer h5d.close();

                    // Write attributes
                    h5a.write(h5d.id) catch {};
                    // Create step value link
                    if (step.value) |step_val| {
                        const target = try allocator.printSentinel("{d}/by_idx/{d}", .{ scan_idx, step_idx }, 0);
                        defer allocator.free(target);
                        const link = try allocator.printSentinel("{d}/{s}", .{ scan_idx, step_val }, 0);
                        defer allocator.free(link);
                        h5f.createLink(target, link) catch {};
                    }

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
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
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
            // Write dataset
            try h5d.flush();
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

const Mode = enum {
    HITS,
    GRPS,
};

const ScanTable = struct {
    scans: std.ArrayList(StepTable) = .empty,
    allocator: std.mem.Allocator,

    fn parseOrRebuild(
        self: *@This(),
        comptime Marker: type,
        comptime Datum: type,
        file_reader: *std.Io.File.Reader,
        offset: i64,
        size: i32,
        old_style: bool,
        rebuild_tables: bool,
    ) !void {
        if (rebuild_tables) {
            try self.rebuild(Marker, Datum, file_reader);
        } else if (old_style) {
            self.parse(i32, Datum, file_reader, offset, size) catch {
                try self.rebuild(Marker, Datum, file_reader);
            };
        } else {
            self.parse(i64, Datum, file_reader, offset, size) catch {
                try self.rebuild(Marker, Datum, file_reader);
            };
        }
    }

    fn append(self: *@This(), step_table: StepTable) !void {
        try self.scans.append(self.allocator, step_table);
    }

    fn parse(
        self: *@This(),
        comptime Entry: type,
        comptime Datum: type,
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

    fn rebuild(
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

    fn deinit(self: *@This()) void {
        for (self.scans.items) |*step_table| {
            step_table.deinit();
        }
        self.scans.deinit(self.allocator);
    }
};

const StepTable = struct {
    steps: std.ArrayList(StepEntry) = .empty,
    allocator: std.mem.Allocator,

    const StepEntry = struct {
        value: ?[:0]const u8,
        data_offset: i64,
        data_size: i64,
    };

    fn append(
        self: *@This(),
        step_val: ?[]const u8,
        data_offset: i64,
        data_size: i64,
    ) !void {
        if (step_val) |val| {
            const value = try self.allocator.dupeSentinel(u8, std.mem.trim(u8, val, &.{0}), 0);
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

    fn deinit(self: *@This()) void {
        for (self.steps.items) |*step| {
            if (step.value != null) self.allocator.free(step.value.?);
        }
        self.steps.deinit(self.allocator);
    }
};

fn appendParamTable(
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

    fn decode(word: u32) !DecodedWord {
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
