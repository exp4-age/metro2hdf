const std = @import("std");

const glob = @import("glob.zig");
const tsv = @import("tsv.zig");
const hptdc = @import("hptdc.zig");
const hdf5 = @import("hdf5.zig");

pub const Options = struct {
    hptdc_event_type: u8 = 'P',
    hptdc_hit_filter: u8 = (@as(u8, 1) << 7) - 1,
    hptdc_hit_mcp: u3 = 6,
};

pub const RunTable = struct {
    map: std.AutoHashMap(u64, Run),
    sorting: std.ArrayList(u64),
    idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !RunTable {
        return .{
            .map = .init(allocator),
            .sorting = .empty,
        };
    }

    pub fn addChannel(
        self: *@This(),
        path: []const u8,
        exclude: [][:0]const u8,
        include: [][:0]const u8,
    ) !void {
        const stem = std.fs.path.stem(path);
        const ext = std.fs.path.extension(path);

        // Create a unique hash with the run information
        var hash = std.hash.Wyhash.init(42);

        // Split the filename into segments for parsing
        var it = std.mem.splitScalar(u8, stem, '_');

        // The first segment is the run number
        const num = it.next() orelse return error.MalformedFileName;
        const idx = try std.fmt.parseUnsigned(usize, num, 10);
        hash.update(num);

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

        // Update the hash with name and date
        hash.update(name);
        hash.update(date);

        // After the date must come the time
        const time = it.next() orelse return error.MalformedFileName;
        if (!isTime(time)) return error.MalformedFileName;
        hash.update(time);

        // Last is the name of the data channel
        const channel = it.rest();

        // Get null terminated string for glob matching
        const channel0 = try self.map.allocator.dupeSentinel(u8, channel, 0);
        defer self.map.allocator.free(channel0);

        // Skip if the channel is not in the include list (if not empty)
        if (include.len > 0) {
            var match = false;
            for (include) |glob_str| {
                if (glob.globMatch(glob_str, channel0)) match = true;
            }
            if (!match) return;
        }

        // Skip if the channel is in the exclude list
        for (exclude) |glob_str| {
            if (glob.globMatch(glob_str, channel0)) return;
        }

        // Parse the file extension
        const format = try FileFormat.parse(ext);

        // Found metro screenshot: skip without error
        if (format == .jpg) return;

        // Combination of num, name, date and time should uniquely identify a run
        const run_hash = hash.final();

        // Add run to hash map or get the existing one
        const gop = try self.map.getOrPut(run_hash);

        if (!gop.found_existing) {
            errdefer self.map.removeByPtr(gop.key_ptr);

            // Add new run to the hash map
            gop.value_ptr.* = try .init(idx, num, name, date, time, self.map.allocator);
            errdefer gop.value_ptr.deinit();

            var sorted_idx: usize = 0;
            for (self.sorting.items) |h| {
                if (self.map.get(h)) |item| {
                    if (idx > item.idx) {
                        sorted_idx += 1;
                    } else {
                        break;
                    }
                }
            }
            try self.sorting.insert(self.map.allocator, sorted_idx, run_hash);
            errdefer _ = self.sorting.orderedRemove(sorted_idx);
        }

        // Append the channel to the run
        try gop.value_ptr.addChannel(path, channel, format);
    }

    pub fn next(self: *@This()) ?Run {
        if (self.idx >= self.sorting.items.len) {
            self.idx = 0;
            return null;
        }
        const run = self.map.get(self.sorting.items[self.idx]);
        self.idx += 1;
        if (run == null) {
            return null;
        }
        return run.?;
    }

    pub fn deinit(self: *@This()) void {
        var it = self.map.iterator();
        while (it.next()) |*entry| {
            entry.value_ptr.deinit();
        }
        self.sorting.deinit(self.map.allocator);
        self.map.deinit();
    }
};

pub const Run = struct {
    idx: usize,
    num: []const u8,
    name: []const u8,
    date: []const u8,
    time: []const u8,
    channels: std.ArrayList(Channel),
    allocator: std.mem.Allocator,

    pub fn init(
        idx: usize,
        num: []const u8,
        name: []const u8,
        date: []const u8,
        time: []const u8,
        allocator: std.mem.Allocator,
    ) !Run {
        const num0 = try allocator.dupe(u8, num);
        errdefer allocator.free(num0);
        const name0 = try allocator.dupe(u8, name);
        errdefer allocator.free(name0);
        const date0 = try allocator.dupe(u8, date);
        errdefer allocator.free(date0);
        const time0 = try allocator.dupe(u8, time);
        errdefer allocator.free(time0);
        return .{
            .idx = idx,
            .num = num0,
            .name = name0,
            .date = date0,
            .time = time0,
            .channels = .empty,
            .allocator = allocator,
        };
    }

    pub fn addChannel(
        self: *@This(),
        path: []const u8,
        name: []const u8,
        format: FileFormat,
    ) !void {
        var ch: Channel = try .init(path, name, format, self.allocator);
        errdefer ch.deinit();
        try self.channels.append(self.allocator, ch);
    }

    pub fn deinit(self: *@This()) void {
        // Free strings
        self.allocator.free(self.num);
        self.allocator.free(self.name);
        self.allocator.free(self.date);
        self.allocator.free(self.time);

        // Deinit channels
        for (self.channels.items) |*ch| {
            ch.deinit();
        }

        // Deinit the array list
        self.channels.deinit(self.allocator);
    }
};

pub const Channel = struct {
    path: []const u8,
    name: []const u8,
    format: FileFormat,
    allocator: std.mem.Allocator,

    pub fn init(
        path: []const u8,
        name: []const u8,
        format: FileFormat,
        allocator: std.mem.Allocator,
    ) !Channel {
        const path0 = try allocator.dupe(u8, path);
        errdefer allocator.free(path0);
        const name0 = try allocator.dupe(u8, name);
        errdefer allocator.free(name0);
        return .{ .path = path0, .name = name0, .format = format, .allocator = allocator };
    }

    pub fn parse(
        self: @This(),
        h5f: *hdf5.File,
        io: std.Io,
        allocator: std.mem.Allocator,
        options: Options,
    ) !void {
        // Open input file
        var file = try std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .read_only });
        defer file.close(io);

        // Call the parser based on the file format
        switch (self.format) {
            .txt => {
                try tsv.parseChannel(self, &file, h5f, io, allocator, options);
            },
            .tdc => {
                try hptdc.parseChannel(self, &file, h5f, io, allocator, options);
            },
            else => {
                return error.UnknownFormat;
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
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
