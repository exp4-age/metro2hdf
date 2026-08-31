const std = @import("std");

const hdf5 = @import("hdf5.zig");
const glob = @import("glob.zig");
const tsv = @import("metro/tsv.zig");
const hptdc = @import("metro/hptdc.zig");

pub const RunTable = struct {
    hm: std.AutoArrayHashMapUnmanaged(u64, Run) = .empty,
    allocator: std.mem.Allocator,

    const SortContext = struct {
        keys: []const u64,

        pub fn lessThan(ctx: SortContext, a_index: usize, b_index: usize) bool {
            return ctx.keys[a_index] < ctx.keys[b_index];
        }
    };

    pub fn init(allocator: std.mem.Allocator) RunTable {
        return .{ .allocator = allocator };
    }

    pub fn count(self: *@This()) usize {
        return self.hm.count();
    }

    pub fn sort(self: *@This()) void {
        self.hm.sort(SortContext{ .keys = self.hm.keys() });
    }

    pub fn iterator(self: *@This()) std.AutoArrayHashMapUnmanaged(u64, Run).Iterator {
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

        // Parse the file extension
        const format = try FileFormat.parse(ext);

        // Skip images like metro screenshots
        if (format == .jpg) return error.ExcludedChannel;

        // Split the filename into segments for parsing
        var it = std.mem.splitScalar(u8, stem, '_');

        // The first segment is the run number
        const num = it.next() orelse return error.MalformedFileName;
        const hash = std.fmt.parseUnsigned(u64, num, 10) catch {
            return error.MissingRunNumber;
        };

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

        // Add run to hash map or get the existing one
        const gop = try self.hm.getOrPut(self.allocator, hash);

        if (gop.found_existing) {
            // Check if run info matches
            if (!std.mem.eql(u8, gop.value_ptr.name, name)) return error.RunNumberConflict;
            if (!std.mem.eql(u8, gop.value_ptr.date, date)) return error.RunNumberConflict;
            if (!std.mem.eql(u8, gop.value_ptr.time, time)) return error.RunNumberConflict;
        } else {
            // Add new run to the hash map
            gop.value_ptr.* = .{ .num = num, .name = name, .date = date, .time = time };
        }

        // Append the channel to the run
        errdefer if (!gop.found_existing) self.hm.swapRemoveAt(gop.index);
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
        if (std.mem.eql(u8, ext, ".tdc")) return .tdc;
        if (std.mem.eql(u8, ext, ".jpg")) return .jpg;
        if (std.mem.eql(u8, ext, ".h5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".hdf5")) return .hdf5;
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
        try w.print("{B:.2} total ({B:.2}/s)\n", .{
            self.input_size,
            std.math.divCeil(u64, self.input_size, elapsed_time_in_s) catch 0,
        });

        try w.printAscii("Write bytes     : ", .{});
        try w.print("{B:.2} total ({B:.2}/s)\n", .{
            self.output_size,
            std.math.divCeil(u64, self.output_size, elapsed_time_in_s) catch 0,
        });

        try w.printAscii("Elapsed time    : ", .{});
        try elapsed_time.format(w);
        try w.printAsciiChar('\n', .{});
        try w.flush();
    }
};

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
