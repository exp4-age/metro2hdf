const std = @import("std");
const metro = @import("../../metro.zig");
const hdf5 = @import("../../hdf5.zig");
const ScanTable = @import("ScanTable.zig");

const Word = packed struct {
    word1: u32,
    word2: u32,

    pub const scan_marker = Word{
        .word1 = 0,
        .word2 = 160,
    };

    pub const step_marker = Word{
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

pub fn sortEvents(
    file_reader: *std.Io.File.Reader,
    h5f: *hdf5.File,
    scan_table: *ScanTable,
    h5a: *hdf5.AttrList,
    allocator: std.mem.Allocator,
    options: metro.Options,
) !void {
    // Parse or rebuild the scan table
    try scan_table.parseOrRebuild(Word, u32, file_reader);
    var reader = &file_reader.interface;

    // HPTDC channel numbers (currently only one configuration supported)
    const electron_channel: i8 = 1;
    const photon_channel: i8 = 2;

    // Event type P or I for either EP or EI coincidences
    const p2 = options.hptdc_event_type;

    // Maximum number of particles per particle type
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
