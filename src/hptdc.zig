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
        try scan_table.parse(Hit, &file_reader, scan_table_offset, scan_table_size);
        try parseHits(ch, &file_reader, h5f, &scan_table, &param_table, allocator, options);
    } else if (std.mem.eql(u8, mode, "GRPS")) {
        try scan_table.parse(u32, &file_reader, scan_table_offset, scan_table_size);
        if (options.hptdc_sort_events) {
            try sortEvents(&file_reader, h5f, &scan_table, &param_table, allocator, options);
        } else if (options.hptdc_decode_words) {
            try parseDecode(ch, &file_reader, h5f, &scan_table, &param_table, allocator, options);
        } else {
            try parseRaw(ch, &file_reader, h5f, &scan_table, &param_table, allocator, options);
        }
    } else {
        return error.UnknownHptdcMode;
    }
}

fn parseRaw(
    ch: metro.Channel,
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    param_table: *ParamTable,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    var reader = &file_reader.interface;

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeInt(u32, .little) != 0) return error.MissingMarker;
            if (try reader.takeInt(u32, .little) != 176) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < 4 or @mod(step.data_size, 4) != 0) continue;

            const n: usize = @intCast(@divExact(step.data_size, 4));

            var words = try allocator.alloc(u32, n);
            defer allocator.free(words);

            for (0..n) |i| {
                words[i] = try reader.takeInt(u32, .little);
            }

            try h5f.writeSimpleDset(u32, words, 0, scan_idx, step_idx, step.value, ch.name, param_table.attrs.items, options);
        }
    }
}

fn parseDecode(
    ch: metro.Channel,
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    param_table: *ParamTable,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    var reader = &file_reader.interface;

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeInt(u32, .little) != 0) return error.MissingMarker;
            if (try reader.takeInt(u32, .little) != 176) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < 4 or @mod(step.data_size, 4) != 0) continue;

            const n: usize = @intCast(@divExact(step.data_size, 4));

            var words = try allocator.alloc(DecodedWord, n);
            defer allocator.free(words);

            for (0..n) |i| {
                words[i] = try DecodedWord.decode(try reader.takeInt(u32, .little));
            }

            try h5f.writeCompoundDset(DecodedWord, words, scan_idx, step_idx, step.value, ch.name, param_table.attrs.items, options);
        }
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

    var events: std.AutoHashMap(Particles, std.ArrayList(i32)) = .init(allocator);
    defer {
        var it = events.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        events.deinit();
    }

    // Add default coincidence categories
    try events.putNoClobber(.{ .E = 1, .P = 0 }, .empty);
    try events.putNoClobber(.{ .E = 0, .P = 1 }, .empty);
    try events.putNoClobber(.{ .E = 2, .P = 0 }, .empty);
    try events.putNoClobber(.{ .E = 1, .P = 1 }, .empty);
    try events.putNoClobber(.{ .E = 0, .P = 2 }, .empty);
    try events.putNoClobber(.{ .E = 3, .P = 0 }, .empty);
    try events.putNoClobber(.{ .E = 2, .P = 1 }, .empty);
    try events.putNoClobber(.{ .E = 4, .P = 0 }, .empty);

    // Add coincidence categories added by the user
    for (options.hptdc_other.items) |particles| {
        var e_count: usize = 0;
        var p_count: usize = 0;

        if (std.mem.findScalar(u8, particles, 'E')) |e_idx| {
            var idx: usize = e_idx;
            while (idx > 0 and std.ascii.isDigit(particles[idx - 1])) idx -= 1;
            e_count = try std.fmt.parseInt(usize, particles[idx..e_idx], 10);
        }
        if (std.mem.findScalar(u8, particles, options.hptdc_event_type)) |p_idx| {
            var idx: usize = p_idx;
            while (idx > 0 and std.ascii.isDigit(particles[idx - 1])) idx -= 1;
            p_count = try std.fmt.parseInt(usize, particles[idx..p_idx], 10);
        }
        if (e_count == 0 and p_count == 0) continue;
        if (e_count > 32 or p_count > 32) return error.TooManyParticles;
        try events.put(.{ .E = @intCast(e_count), .P = @intCast(p_count) }, .empty);
    }

    // Keep pointers to the most common coincidence categories
    const ptr_E = events.getPtr(.{ .E = 1, .P = 0 }).?;
    const ptr_P = events.getPtr(.{ .E = 0, .P = 1 }).?;

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeInt(u32, .little) != 0) return error.MissingMarker;
            if (try reader.takeInt(u32, .little) != 176) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < 4 or @mod(step.data_size, 4) != 0) continue;

            // Get the number of words in this step
            const n: usize = @intCast(@divExact(step.data_size, 4));

            // Counters for the electron and photon events per bunch
            var e_count: u8 = 0;
            var p_count: u8 = 0;

            // Buffers for the event times
            var e_buf: [32]i32 = undefined;
            var p_buf: [32]i32 = undefined;

            for (0..n) |_| {
                const raw = try reader.takeInt(u32, .little);
                const decoded = try DecodedWord.decode(raw);
                if ((raw >> 24) == 16) {
                    // Start of new bunch: process last event
                    // Skip the last event if none or too many were found
                    if (e_count == 0 and p_count == 0) continue;

                    // Fast access to common coincidence categories
                    // and use hash otherwise
                    if (e_count == 1 and p_count == 0) {
                        try ptr_E.append(allocator, e_buf[0]);
                    } else if (e_count == 0 and p_count == 1) {
                        try ptr_P.append(allocator, p_buf[0]);
                    } else if (events.getPtr(.{ .E = e_count, .P = p_count })) |ptr| {
                        // Append electron event times first
                        try ptr.appendSlice(allocator, e_buf[0..e_count]);
                        // Append photon event times second
                        try ptr.appendSlice(allocator, p_buf[0..p_count]);
                    }

                    // Reset counters for the next bunch
                    e_count = 0;
                    p_count = 0;
                } else if ((raw >> 30) == 2) {
                    // Discard this bunch if maximum coincidence size is exceeded
                    if (e_count == 32 or p_count == 32) {
                        e_count = 0;
                        p_count = 0;
                        continue;
                    }
                    switch (decoded.arg1) {
                        1 => {
                            // Add electron to event
                            e_buf[e_count] = decoded.arg3;
                            e_count += 1;
                        },
                        2 => {
                            // Add photon to event
                            p_buf[p_count] = decoded.arg3;
                            p_count += 1;
                        },
                        else => {},
                    }
                }
            }

            var it = events.iterator();
            while (it.next()) |entry| {
                // Skip if not events where found for this category
                if (entry.value_ptr.items.len == 0) continue;

                // Event coincidence category
                const ev = entry.key_ptr;

                // Event type P or I for either EP or EI coincidences
                const p2 = options.hptdc_event_type;

                // Create name for the dataset
                var name_buf: [8]u8 = undefined;
                var name = try std.fmt.bufPrint(&name_buf, "{d}E{d}{c}", .{ev.E, ev.P, p2});
                if (ev.P == 0) {
                    name = try std.fmt.bufPrint(&name_buf, "{d}E", .{ev.E});
                } else if (ev.E == 0) {
                    name = try std.fmt.bufPrint(&name_buf, "{d}{c}", .{ev.P, p2});
                }

                // Set shape to 0 for a single particle
                const shape = if (ev.E + ev.P == 1) 0 else ev.E + ev.P;

                // Write the dataset
                try h5f.writeSimpleDset(i32, entry.value_ptr.items, shape, scan_idx, step_idx, step.value, name, attrs, options);

                // Clear the list for the next step
                entry.value_ptr.clearRetainingCapacity();
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

    for (scan_table.scans.items, 0..) |step_table, scan_idx| {
        for (step_table.steps.items, 0..) |step, step_idx| {
            // Go to the step data
            try file_reader.seekTo(@intCast(step.data_offset));

            // Check if we are at a step marker
            if (try reader.takeStruct(Hit, .little) != step_marker) return error.MissingMarker;

            // Skip if there is no data
            if (step.data_size < @sizeOf(Hit) or @mod(step.data_size, @sizeOf(Hit)) != 0) continue;

            const n: usize = @intCast(@divExact(step.data_size, @sizeOf(Hit)));

            var hits = try allocator.alloc(Hit, n);
            defer allocator.free(hits);

            for (0..n) |i| {
                hits[i] = try reader.takeStruct(Hit, .little);
            }

            try h5f.writeCompoundDset(Hit, hits, scan_idx, step_idx, step.value, ch.name, param_table.attrs.items, options);
        }
    }

    _ = &scan_marker;
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
        const value = try self.allocator.dupeSentinel(u8, step_val[0..len], 0);
        errdefer self.allocator.free(value);
        try self.steps.append(
            self.allocator,
            .{
                .value = value,
                .data_offset = data_offset,
                .data_size = data_size,
            },
        );
    }

    pub fn deinit(self: *@This()) void {
        for (self.steps.items) |*step| {
            self.allocator.free(step.value);
        }
        self.steps.deinit(self.allocator);
    }
};

const StepEntry = struct {
    value: [:0]const u8,
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
};

const DecodedWord = extern struct {
    type: [2]u8 = .{ '?', '?' },
    arg1: i8 = 0,
    arg2: i8 = 0,
    arg3: i32 = 0,

    pub fn decode(word: u32) !DecodedWord {
        // FL: type_len=2, type_val=2 (top 2 bits == 0b10)
        if ((word >> 30) == 2) {
            return .{
                .type = .{ 'F', 'L' },
                .arg1 = extractInt(i8, word, 29, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // RS: type_len=2, type_val=3 (top 2 bits == 0b11)
        if ((word >> 30) == 3) {
            return .{
                .type = .{ 'R', 'S' },
                .arg1 = extractInt(i8, word, 29, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // ER: type_len=2, type_val=1 (top 2 bits == 0b01)
        if ((word >> 30) == 1) {
            return .{
                .type = .{ 'E', 'R' },
                .arg1 = extractInt(i8, word, 29, 24),
                .arg2 = extractInt(i8, word, 23, 16),
                .arg3 = extractInt(i32, word, 15, 0),
            };
        }

        // GR: type_len=4, type_val=0 (top 4 bits == 0b0000)
        if ((word >> 28) == 0) {
            return .{
                .type = .{ 'G', 'R' },
                .arg1 = extractInt(i8, word, 27, 24),
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // RL: type_len=8, type_val=16 (top 8 bits == 0b00010000)
        if ((word >> 24) == 16) {
            return .{
                .type = .{ 'R', 'L' },
                .arg3 = extractInt(i32, word, 23, 0),
            };
        }

        // LV: type_len=5, type_val=3 (top 5 bits == 0b00011)
        if ((word >> 27) == 3) {
            return .{
                .type = .{ 'L', 'V' },
                .arg1 = extractInt(i8, word, 26, 21),
                .arg3 = extractInt(i32, word, 20, 0),
            };
        }

        return .{};
    }
};

const Particles = packed struct {
    E: u8,
    P: u8,
};

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
