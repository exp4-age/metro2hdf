const RunTable = @This();

const std = @import("std");
const glob = @import("../glob.zig");

hm: std.AutoArrayHashMapUnmanaged(u64, Run) = .empty,
allocator: std.mem.Allocator,

pub const Run = @import("Run.zig");
pub const Channel = @import("Channel.zig");

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
    const format = try Channel.FileFormat.parse(ext);

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

pub fn deinit(self: *@This()) void {
    for (self.hm.values()) |*run| {
        for (run.channels.items) |ch| {
            self.allocator.free(ch.path);
        }
        run.deinit(self.allocator);
    }
    self.hm.deinit(self.allocator);
}
