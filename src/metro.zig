const std = @import("std");

const tsv = @import("tsv.zig");
const hptdc = @import("hptdc.zig");
const hdf5 = @import("hdf5.zig");

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

    pub fn addChannel(self: *@This(), path: []const u8) !void {
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

        // Parse the file extension
        const format = try FileFormat.parse(ext);

        // Combination of num, name, date and time should uniquely identify a run
        const run_hash = hash.final();

        // Add run to hash map or get the existing one
        const gop = try self.map.getOrPut(run_hash);

        if (!gop.found_existing) {
            // Add new run to the hash map
            gop.value_ptr.* = try .init(idx, num, name, date, time, self.map.allocator);

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
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
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
        return .{
            .idx = idx,
            .num = try allocator.dupeSentinel(u8, num, 0),
            .name = try allocator.dupeSentinel(u8, name, 0),
            .date = try allocator.dupeSentinel(u8, date, 0),
            .time = try allocator.dupeSentinel(u8, time, 0),
            .channels = .empty,
            .allocator = allocator,
        };
    }

    pub fn addChannel(
        self: *@This(),
        path: []const u8,
        channel: []const u8,
        format: FileFormat,
    ) !void {
        const ch = Channel{
            .path = try self.allocator.dupeSentinel(u8, path, 0),
            .name = try self.allocator.dupeSentinel(u8, channel, 0),
            .format = format,
        };
        try self.channels.append(self.allocator, ch);
    }

    pub fn deinit(self: *@This()) void {
        // Free strings
        self.allocator.free(self.num);
        self.allocator.free(self.name);
        self.allocator.free(self.date);
        self.allocator.free(self.time);

        // Free strings in channels
        for (self.channels.items) |ch| {
            self.allocator.free(ch.path);
            self.allocator.free(ch.name);
        }

        // Deinit the array list
        self.channels.deinit(self.allocator);
    }
};

pub const Channel = struct {
    path: []const u8,
    name: []const u8,
    format: FileFormat,

    pub fn parse(
        self: @This(),
        h5f: *hdf5.File,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        // Open input file
        var file = try std.Io.Dir.cwd().openFile(io, self.path, .{.mode=.read_only});
        defer file.close(io);

        // Call the parser based on the file format
        switch (self.format) {
            .txt => {try tsv.parseChannel(self, &file, h5f, io, allocator);},
            .tdc => {try hptdc.parseChannel(self, &file, h5f, io, allocator);},
            else => {return error.UnknownFormat;},
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
