const std = @import("std");

const glob = @import("glob.zig");
const tsv = @import("tsv.zig");
const hptdc = @import("hptdc.zig");
const hdf5 = @import("hdf5.zig");

pub const RunTable = struct {
    hm: std.StringArrayHashMapUnmanaged(Run) = .empty,
    allocator: std.mem.Allocator,

    const SortContext = struct {
        values: []const Run,

        pub fn lessThan(ctx: SortContext, a_index: usize, b_index: usize) bool {
            const a_num = std.fmt.parseInt(u64, ctx.values[a_index].num, 10) catch 0;
            const b_num = std.fmt.parseInt(u64, ctx.values[b_index].num, 10) catch 0;
            return a_num < b_num;
        }
    };

    pub fn init(allocator: std.mem.Allocator) RunTable {
        return .{ .allocator = allocator };
    }

    pub fn count(self: *@This()) usize {
        return self.hm.count();
    }

    pub fn sort(self: *@This()) void {
        self.hm.sort(SortContext{ .values = self.hm.values() });
    }

    pub fn iterator(self: *@This()) std.StringArrayHashMapUnmanaged(Run).Iterator {
        return self.hm.iterator();
    }

    pub fn addChannel(
        self: *@This(),
        file_path: []const u8,
        exclude: [][:0]const u8,
        include: [][:0]const u8,
    ) !void {
        const path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path);

        const stem = std.fs.path.stem(path);
        const ext = std.fs.path.extension(path);

        // Split the filename into segments for parsing
        var it = std.mem.splitScalar(u8, stem, '_');

        // The first segment is the run number
        const num = it.next() orelse return error.MalformedFileName;
        // const idx = try std.fmt.parseUnsigned(usize, num, 10);

        // All following segments are the run name until the date is found
        var name = it.next() orelse return error.MalformedFileName;
        var date: []const u8 = undefined;
        while (it.next()) |segment| {
            if (isDate(segment)) {
                date = segment;
                break;
            }
            const name_start = @intFromPtr(name.ptr) - @intFromPtr(stem.ptr);
            const seg_end = (@intFromPtr(segment.ptr) - @intFromPtr(stem.ptr)) + segment.len;
            name = stem[name_start..seg_end];
        } else return error.MalformedFileName;

        // After the date must come the time
        const time = it.next() orelse return error.MalformedFileName;
        if (!isTime(time)) return error.MalformedFileName;

        // Last is the name of the data channel
        const channel = it.rest();

        // Get null terminated string for glob matching
        const channel0 = try self.allocator.dupeSentinel(u8, channel, 0);
        defer self.allocator.free(channel0);

        // Skip if the channel is not in the include list (if not empty)
        if (include.len > 0) {
            var match = false;
            for (include) |glob_str| {
                if (glob.globMatch(glob_str, channel0)) match = true;
            }
            if (!match) return error.ExcludedChannel;
        }

        // Skip if the channel is in the exclude list
        for (exclude) |glob_str| {
            if (glob.globMatch(glob_str, channel0)) return error.ExcludedChannel;
        }

        // Parse the file extension
        const format = try FileFormat.parse(ext);

        // Found metro screenshot
        if (format == .jpg) return error.ExcludedChannel;

        const string_hash = stem[0 .. stem.len - channel.len - 1];

        // Add run to hash map or get the existing one
        const gop = try self.hm.getOrPut(self.allocator, string_hash);

        if (!gop.found_existing) {
            // Add new run to the hash map
            gop.value_ptr.* = .{ .num = num, .name = name, .date = date, .time = time };
        }

        // Append the channel to the run
        try gop.value_ptr.addChannel(self.allocator, .{ .path = path, .name = channel, .format = format });
    }

    pub fn deinit(self: *@This()) void {
        for (self.hm.values()) |*run| {
            for (run.channels.items) |ch| {
                self.allocator.free(ch.path);
            }
            run.deinit(self.allocator);
        }
        self.hm.deinit(self.allocator);
    }
};

pub const Run = struct {
    num: []const u8,
    name: []const u8,
    date: []const u8,
    time: []const u8,
    channels: std.ArrayList(Channel) = .empty,

    pub fn addChannel(
        self: *@This(),
        allocator: std.mem.Allocator,
        channel: Channel,
    ) !void {
        try self.channels.append(allocator, channel);
    }

    pub fn writeAttrs(self: *@This(), h5f: *hdf5.File, allocator: std.mem.Allocator) !void {
        var h5a = try hdf5.AttrList.init(allocator);
        defer h5a.deinit();

        // Measurement run number
        try h5a.append("number", self.num);

        // Measurement name
        try h5a.append("name", self.name);

        var buf: [10]u8 = undefined;

        // Format and append the date
        const date = try std.fmt.bufPrint(&buf, "{s}-{s}-{s}", .{ self.date[0..2], self.date[2..4], self.date[4..8] });
        try h5a.append("date", date);

        // Format and append the time
        const time = try std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ self.time[0..2], self.time[2..4], self.time[4..6] });
        try h5a.append("time", time);

        // Write the attributes to the root group
        var root = try h5f.openRoot();
        defer root.close();

        try h5a.write(root.id);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.channels.deinit(allocator);
    }
};

pub const Channel = struct {
    path: []const u8,
    name: []const u8,
    format: FileFormat,

    pub fn parse(
        self: @This(),
        file: *std.Io.File,
        h5f: *hdf5.File,
        io: std.Io,
        allocator: std.mem.Allocator,
        options: Options,
    ) !void {
        // Call the parser based on the file format
        switch (self.format) {
            .txt => {
                try tsv.parseChannel(self, file, h5f, io, allocator, options);
            },
            .tdc => {
                try hptdc.parseChannel(self, file, h5f, io, allocator, options);
            },
            else => {
                return error.UnknownFormat;
            },
        }
    }
};

const FileFormat = enum {
    txt,
    hdf5,
    tdc,
    jpg,

    fn parse(ext: []const u8) !FileFormat {
        if (std.mem.eql(u8, ext, ".txt")) return .txt;
        if (std.mem.eql(u8, ext, ".h5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".hdf5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".tdc")) return .tdc;
        if (std.mem.eql(u8, ext, ".jpg")) return .jpg;
        return error.UnknownFormat;
    }
};

pub const Options = struct {
    hptdc_rebuild_tables: bool = false,
    hptdc_event_type: u8 = 'P',
    legacy_event_names: bool = false,
    hptdc_hit_filter: u8 = (@as(u8, 1) << 7) - 1,
    hptdc_hit_mcp: u3 = 6,
};

pub const Summary = struct {
    matching_run_files: usize = 0,
    skipped_run_files: usize = 0,
    new_files: usize = 0,
    replaced_files: usize = 0,
    skipped_files: usize = 0,
    processed_channels: usize = 0,
    skipped_channels: usize = 0,
    input_size: u64 = 0,
    output_size: u64 = 0,
    timer: std.Io.Timestamp,
    io: std.Io,

    pub fn start_timer(io: std.Io) Summary {
        const clock: std.Io.Clock = .real;
        return .{ .timer = clock.now(io), .io = io };
    }

    pub fn write(
        self: *@This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.printAscii("μετρο2hdf summary\n", .{});
        try w.printAscii("Processed files : ", .{});
        try w.print("{d} matching ({d} skipped)\n", .{
            self.matching_run_files,
            self.skipped_run_files,
        });

        try w.printAscii("HDF5 output     : ", .{});
        try w.print("{d} written ({d} new, {d} replaced, {d} skipped)\n", .{
            self.new_files + self.replaced_files,
            self.new_files,
            self.replaced_files,
            self.skipped_files,
        });

        try w.printAscii("Channels        : ", .{});
        try w.print("{d} total ({d} skipped)\n", .{
            self.processed_channels,
            self.skipped_channels,
        });

        const clock: std.Io.Clock = .real;
        const elapsed_time = self.timer.untilNow(self.io, clock);
        const elapsed_time_in_s = @max(elapsed_time.toSeconds(), 1);

        try w.printAscii("Read bytes      : ", .{});
        try formatFilesize(w, self.input_size);
        try w.printAscii(" total (", .{});
        if (std.math.divCeil(u64, self.input_size, elapsed_time_in_s)) |read_speed| {
            try formatFilesize(w, read_speed);
        } else |_| {
            try w.writeByte('?');
        }
        try w.printAscii("/s)\n", .{});

        try w.printAscii("Write bytes     : ", .{});
        try formatFilesize(w, self.output_size);
        try w.printAscii(" total (", .{});
        if (std.math.divCeil(u64, self.output_size, elapsed_time_in_s)) |write_speed| {
            try formatFilesize(w, write_speed);
        } else |_| {
            try w.writeByte('?');
        }
        try w.printAscii("/s)\n", .{});

        try w.printAscii("Elapsed time    : ", .{});
        try elapsed_time.format(w);
        try w.printAsciiChar('\n', .{});
        try w.flush();
    }
};

fn formatFilesize(w: *std.Io.Writer, bytes: u64) std.Io.Writer.Error!void {
    const bytes_remaining = bytes;
    inline for (.{
        .{ .bytes = 1000000000000, .sep = "T" },
        .{ .bytes = 1000000000, .sep = "G" },
        .{ .bytes = 1000000, .sep = "M" },
        .{ .bytes = 1000, .sep = "k" },
    }) |unit| {
        const units = bytes_remaining * 1000 / unit.bytes;
        if (units >= 1000) {
            try w.printInt(units / 1000, 10, .lower, .{});
            const frac = units % 1000;
            if (frac > 0) {
                // Write up to 3 decimal places
                var decimal_buf = [_]u8{ '.', 0, 0, 0 };
                var inner: std.Io.Writer = .fixed(decimal_buf[1..]);
                inner.printInt(frac, 10, .lower, .{ .fill = '0', .width = 3 }) catch unreachable;
                var end: usize = 4;
                while (end > 1) : (end -= 1) {
                    if (decimal_buf[end - 1] != '0') break;
                }
                try w.writeAll(decimal_buf[0..end]);
            }
            return w.writeAll(unit.sep);
        }
    }

    try w.printInt(bytes_remaining, 10, .lower, .{});
    try w.writeAll("bytes");
}

fn isDate(str: []const u8) bool {
    if (str.len != 8) return false;
    for (str) |c| if (c < '0' or c > '9') return false;
    const dd = (str[0] - '0') * 10 + (str[1] - '0');
    const mm = (str[2] - '0') * 10 + (str[3] - '0');
    return dd >= 1 and dd <= 31 and mm >= 1 and mm <= 12;
}

fn isTime(str: []const u8) bool {
    if (str.len != 6) return false;
    for (str) |c| if (c < '0' or c > '9') return false;
    const hh = (str[0] - '0') * 10 + (str[1] - '0');
    const mm = (str[2] - '0') * 10 + (str[3] - '0');
    const ss = (str[4] - '0') * 10 + (str[5] - '0');
    return hh >= 0 and hh < 24 and mm >= 0 and mm < 60 and ss >= 0 and ss < 60;
}
