const std = @import("std");

const hdf5 = @cImport({
    @cInclude("hdf5.h");
});

pub const ParseError = error {
    MalformedFileName,
    UnknownFormat,
};

pub const Run = struct {
    num: []const u8,
    name: []const u8,
    date: []const u8,
    time: []const u8,
    channel: []const u8,
    format: FileFormat,
};

pub const H5File = struct {
    id: hdf5.hid_t = -1,
    path: []const u8 = "",

    pub fn open(self: *@This(), path: [:0]const u8) !void {
        if (self.id >= 0 and std.mem.eql(u8, path, self.path)) return; // already open
        if (self.id >= 0) self.close();
        var id = hdf5.H5Fopen(path.ptr, hdf5.H5F_ACC_RDWR, hdf5.H5P_DEFAULT);
        if (id < 0) {
            id = hdf5.H5Fcreate(path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        }
        self.id = id;
        self.path = path;
        if (id < 0) return error.HDF5OpenFailed;
    }

    pub fn close(self: *@This()) void {
        if (self.id >= 0) {
            _ = hdf5.H5Fclose(self.id);
            self.id = -1;
            self.path = "";
        }
    }
};

pub fn parseFileName(basename: []const u8) ParseError!Run {
    const stem = std.fs.path.stem(basename);
    const ext = std.fs.path.extension(basename);

    // Split the filename into segments for parsing
    var it = std.mem.splitScalar(u8, stem, '_');

    // The first segment is the run number
    const num = it.next() orelse return ParseError.MalformedFileName;

    // All following segments are the run name until the date is found
    var name = it.next() orelse return ParseError.MalformedFileName;
    var date: []const u8 = undefined;
    while (it.next()) |segment| {
        if (isDate(segment)) {
            date = segment;
            break;
        }
        const name_start = @intFromPtr(name.ptr) - @intFromPtr(stem.ptr);
        const seg_end = (@intFromPtr(segment.ptr) - @intFromPtr(stem.ptr)) + segment.len;
        name = stem[name_start..seg_end];
    } else return ParseError.MalformedFileName;

    // After the date must come the time
    const time = it.next() orelse return ParseError.MalformedFileName;
    if (!isTime(time)) return ParseError.MalformedFileName;

    // Last is the name of the data channel
    const channel = it.rest();

    // Parse the file extension
    const format = try FileFormat.parse(ext);

    return .{
        .num = num,
        .name = name,
        .date = date,
        .time = time,
        .channel = channel,
        .format = format,
    };
}

const FileFormat = enum {
    txt,
    hdf5,
    tdc,

    fn parse(ext: []const u8) ParseError!FileFormat {
        if (std.mem.eql(u8, ext, ".txt")) return .txt;
        if (std.mem.eql(u8, ext, ".h5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".hdf5")) return .hdf5;
        if (std.mem.eql(u8, ext, ".tdc")) return .tdc;
        return ParseError.UnknownFormat;
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

test "parse simple name" {
    const run = try parseFileName("042_Scan_27062026_143000_photodiode#value.txt");
    try std.testing.expectEqualStrings("042", run.num);
    try std.testing.expectEqualStrings("Scan", run.name);
    try std.testing.expectEqualStrings("27062026", run.date);
    try std.testing.expectEqualStrings("143000", run.time);
    try std.testing.expectEqualStrings("photodiode#value", run.channel);
    try std.testing.expectEqual(.txt, run.format);
}

test "parse name with underscore" {
    const run = try parseFileName("042_Scan_Lya_27062026_143000_photodiode#value.txt");
    try std.testing.expectEqualStrings("042", run.num);
    try std.testing.expectEqualStrings("Scan_Lya", run.name);
    try std.testing.expectEqualStrings("27062026", run.date);
    try std.testing.expectEqualStrings("143000", run.time);
    try std.testing.expectEqualStrings("photodiode#value", run.channel);
    try std.testing.expectEqual(.txt, run.format);
}

test "parse channel with underscore" {
    const run = try parseFileName("042_Scan_27062026_143000_dld_rd#raw.txt");
    try std.testing.expectEqualStrings("042", run.num);
    try std.testing.expectEqualStrings("Scan", run.name);
    try std.testing.expectEqualStrings("27062026", run.date);
    try std.testing.expectEqualStrings("143000", run.time);
    try std.testing.expectEqualStrings("dld_rd#raw", run.channel);
    try std.testing.expectEqual(.txt, run.format);
}

test "parse .tdc extension" {
    const run = try parseFileName("042_Scan_01012000_000000_dld_rd#hits.tdc");
    try std.testing.expectEqual(.tdc, run.format);
}

test "unknown extension" {
    try std.testing.expectError(ParseError.UnknownFormat, parseFileName("042_Scan_27062026_143000.jpg"));
    try std.testing.expectError(ParseError.UnknownFormat, parseFileName("042_Scan_27062026_143000"));
}

test "missing fields" {
    try std.testing.expectError(ParseError.MalformedFileName, parseFileName(".txt"));
    try std.testing.expectError(ParseError.MalformedFileName, parseFileName("Scan_27062026_143000_dld_rd#raw.txt"));
    try std.testing.expectError(ParseError.MalformedFileName, parseFileName("042_27062026_143000_dld_rd#raw.txt"));
    try std.testing.expectError(ParseError.MalformedFileName, parseFileName("042_Scan_143000_dld_rd#raw.txt"));
    try std.testing.expectError(ParseError.MalformedFileName, parseFileName("042_Scan_27062026_dld_rd#raw.txt"));
}
