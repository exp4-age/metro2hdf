const std = @import("std");

const hdf5 = @cImport({
    @cInclude("hdf5shim.h");
});

pub const ParseError = error {
    MalformedFileName,
    UnknownFormat,
    MissingAttribute,
    MissingMarker,
    ShapeMismatch,
    ChannelMismatch,
    UnsupportedChannel,
};

pub const H5Error = error {
    OpenFailed,
    FileNotOpen,
    H5I_INVALID_HID,
    WriteFailed,
    InvalidShape,
};

pub const Run = struct {
    path: []const u8,
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

    pub fn create(self: *@This(), path: [:0]const u8) !void {
        if (self.id >= 0) self.close();
        self.id = hdf5.H5Fcreate(path.ptr, hdf5.H5F_ACC_EXCL, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        self.path = path;
        if (self.id < 0) return H5Error.H5I_INVALID_HID;
    }

    pub fn open(self: *@This(), path: [:0]const u8) !void {
        if (self.id >= 0 and std.mem.eql(u8, path, self.path)) return; // already open
        if (self.id >= 0) self.close();
        self.id = hdf5.H5Fopen(path.ptr, hdf5.H5F_ACC_RDWR, hdf5.H5P_DEFAULT);
        self.path = path;
        if (self.id < 0) return H5Error.H5I_INVALID_HID;
    }

    pub fn close(self: *@This()) void {
        if (self.id >= 0) {
            _ = hdf5.H5Fclose(self.id);
            self.id = -1;
            self.path = "";
        }
    }

    pub fn write_dset(
        self: *@This(),
        scan_idx: []const u8,
        step_val: []const u8,
        channel: []const u8,
        data: []const f64,
        shape: usize,
    ) !void {
        // Fail if the file is not open
        if (self.id < 0) return H5Error.FileNotOpen;

        // Create path to dataset
        var buf: [1024]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}/{s}", .{scan_idx, step_val, channel}, 0);

        // Create link creation property list
        const lcpl = hdf5.H5Pcreate(hdf5.shim_H5P_LINK_CREATE());
        if (lcpl < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Pclose(lcpl);

        // create intermediate groups as needed
        if (hdf5.H5Pset_create_intermediate_group(lcpl, 1) < 0) return H5Error.H5I_INVALID_HID;

        // create a 1D dataspace
        var rank: c_int = undefined;
        var dims_1d: [1]hdf5.hsize_t = undefined;
        var dims_2d: [2]hdf5.hsize_t = undefined;

        if (shape == 0) {
            rank = 1;
            dims_1d[0] = @intCast(data.len);
        } else {
            if (data.len % shape != 0) return H5Error.InvalidShape;
            const rows = data.len / shape;
            rank = 2;
            dims_2d[0] = @intCast(rows);
            dims_2d[1] = @intCast(shape);
        }

        const fspace = if (rank == 1)
            hdf5.H5Screate_simple(rank, &dims_1d, null)
        else
            hdf5.H5Screate_simple(rank, &dims_2d, null);

        if (fspace < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(fspace);

        // Create the dataset
        const dset = hdf5.H5Dcreate2(self.id, name, hdf5.zig_h5t_f64(), fspace, lcpl, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (dset < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Dclose(dset);

        // Write dataset
        if (hdf5.H5Dwrite(
            dset,
            hdf5.zig_h5t_f64(),
            hdf5.H5S_ALL,
            hdf5.H5S_ALL,
            hdf5.H5P_DEFAULT,
            data.ptr,
        ) < 0) return H5Error.WriteFailed;
    }

    pub fn write_attrs(self: *@This(), run: Run) !void {
        var buf: [1024]u8 = undefined;

        // Write measurement number
        const num = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.num}, 0);
        try self.write_str_attr("number", num);

        // Write name
        const name = try std.fmt.bufPrintSentinel(&buf, "{s}", .{run.name}, 0);
        try self.write_str_attr("name", name);

        // Write date
        const date = try std.fmt.bufPrintSentinel(&buf, "{s}-{s}-{s}", .{run.date[0..2], run.date[2..4], run.date[4..8]}, 0);
        try self.write_str_attr("date", date);

        // Write time
        const time = try std.fmt.bufPrintSentinel(&buf, "{s}:{s}:{s}", .{run.time[0..2], run.time[2..4], run.time[4..6]}, 0);
        try self.write_str_attr("time", time);
    }

    pub fn write_str_attr(self: *@This(), name: [*:0]const u8, value: [*:0]const u8) !void {
        const value_c: [*c]const u8 = value;
        const buf: ?*const anyopaque = @ptrCast(&value_c);

        // Fail if the file is not open
        if (self.id < 0) return H5Error.FileNotOpen;

        const str_t = hdf5.H5Tcopy(hdf5.zig_h5t_string());
        if (str_t < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Tclose(str_t);

        if (hdf5.H5Tset_size(str_t, hdf5.H5T_VARIABLE) < 0) return H5Error.WriteFailed;
        if (hdf5.H5Tset_cset(str_t, hdf5.H5T_CSET_UTF8) < 0) return H5Error.WriteFailed;
        if (hdf5.H5Tset_strpad(str_t, hdf5.H5T_STR_NULLTERM) < 0) return H5Error.WriteFailed;

        // Open the root group
        const root = hdf5.H5Gopen2(self.id, "/", hdf5.H5P_DEFAULT);
        if (root < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Gclose(root);

        // Overwrite if attribute already exists
        if (hdf5.H5Aexists(root, name) > 0) {
            const attr = hdf5.H5Aopen(root, name, hdf5.H5P_DEFAULT);
            if (attr < 0) return H5Error.H5I_INVALID_HID;
            defer _ = hdf5.H5Aclose(attr);

            // Write attribute
            if (hdf5.H5Awrite(attr, str_t, buf) < 0) return H5Error.WriteFailed;
            return;
        }

        // Create dataspace for the attribute
        const dspace = hdf5.H5Screate(hdf5.H5S_SCALAR);
        if (dspace < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Sclose(dspace);

        // Create attribute
        const attr = hdf5.H5Acreate2(root, name, str_t, dspace, hdf5.H5P_DEFAULT, hdf5.H5P_DEFAULT);
        if (attr < 0) return H5Error.H5I_INVALID_HID;
        defer _ = hdf5.H5Aclose(attr);

        // Write attribute
        if (hdf5.H5Awrite(attr, str_t, buf) < 0) return H5Error.WriteFailed;
    }
};

pub fn parseChannel(dir: std.Io.Dir, run: Run, h5f: *H5File, io: std.Io, allocator: std.mem.Allocator) void {
    switch (run.format) {
        .txt => {
            parseAsciiChannel(dir, run, h5f, io, allocator) catch |err| {
                std.log.info("  skipping: {s}", .{@errorName(err)});
            };
        },
        else => {
            std.log.info("  skipping: {s}", .{@errorName(ParseError.UnknownFormat)});
        },
    }
}

pub fn parseAsciiChannel(dir: std.Io.Dir, run: Run, h5f: *H5File, io: std.Io, allocator: std.mem.Allocator) !void {
    // Try to open the data file
    const file = try dir.openFile(io, run.path, .{.mode=.read_only});

    // Initialize the reader
    const buf_size = 4096;
    var read_buffer: [buf_size]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);

    // Get the channel name
    const name = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, name.?, "# Name: ")) return ParseError.MissingAttribute;
    if (!std.mem.eql(u8, name.?[8..], run.channel)) return ParseError.ChannelMismatch;

    // Get the hint
    const hint = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, hint.?, "# Hint: ")) return ParseError.MissingAttribute;

    // Get the frequency
    const freq = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, freq.?, "# Frequency: ")) return ParseError.MissingAttribute;
    if (!std.mem.startsWith(u8, freq.?[13..], "continuous")) return ParseError.UnsupportedChannel;

    // Get the shape
    const shape_str = try reader.interface.takeDelimiter('\n');
    if (!std.mem.startsWith(u8, shape_str.?, "# Shape: ")) return ParseError.MissingAttribute;
    const shape = try std.fmt.parseInt(u32, shape_str.?[9..], 10);

    // Keep track of scan and step markers in the file
    var scan_marker: [buf_size]u8 = undefined;
    var scan_idx: ?[]u8 = null;
    var step_marker: [buf_size]u8 = undefined;
    var step_val: ?[]u8 = null;

    // Store data in array list
    var data: std.ArrayList(f64) = .empty;
    defer data.deinit(allocator);

    // Allocate a reasonable amount of memory
    const capacity = if (shape == 0) 1024 else 1024 * shape;
    try data.ensureTotalCapacity(allocator, capacity);

    while (true) {
        // Read the next line
        var line = try reader.interface.takeDelimiter('\n');

        // Are we at EOF?
        if (line == null) {
            // Write dataset to hdf5
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }
            break;
        }

        // Try parse as value first
        if (step_val != null) {
            // Append data and continue to next line if parsing is succesful
            if (shape == 0) {
                // Try parse line as a float
                if (std.fmt.parseFloat(f64, line.?)) |val| {
                    try data.append(allocator, val);
                    continue;
                } else |_| {}
            } else {
                // Try parse line as float seperated by tabs
                var it = std.mem.splitScalar(u8, line.?, '\t');
                var n: usize = 0;
                while (it.next()) |col| {
                    if (std.fmt.parseFloat(f64, col)) |val| {
                        try data.append(allocator, val);
                        n += 1;
                    } else |_| {
                        break;
                    }
                }
                if (n == shape) {
                    // Continue to next line if parsing was succesful
                    continue;
                } else if (n != 0 and n < shape) {
                    // Line is partially degraded, skipping...
                    data.shrinkRetainingCapacity(data.items.len - n);
                } else if (n > shape) {
                    return ParseError.ShapeMismatch;
                }
            }
        }

        // Is it a scan marker?
        if (std.mem.startsWith(u8, line.?, "# SCAN ")) {
            // Write dataset to hdf5 before continuing with next scan
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }

            // Update scan index and reset step marker
            @memcpy(scan_marker[0..line.?.len], line.?);
            scan_idx = scan_marker[7..line.?.len];
            step_val = null;
            std.log.info("    scan: {s}", .{scan_idx.?});

            // Already get next line (should be the step marker)
            line = try reader.interface.takeDelimiter('\n');
        }

        // Is it a step marker?
        if (std.mem.startsWith(u8, line.?, "# STEP ")) {
            // Step marker should never come without a scan marker
            if (scan_idx == null) return ParseError.MissingMarker;

            // Write dataset to hdf5 before continuing with next step
            if (step_val != null and data.items.len > 0) {
                try h5f.write_dset(scan_idx.?, step_val.?, run.channel, data.items, shape);
                data.clearRetainingCapacity();
            }

            // Find start of step value in line and update
            if (std.mem.find(u8, line.?, ":")) |idx| {
                @memcpy(step_marker[0..line.?.len], line.?);
                step_val = step_marker[idx+2..line.?.len];
                std.log.info("    step: {s}", .{step_val.?});
            } else return ParseError.MissingMarker;
        }

        // Ahh shibal... something is wrong, try next line...
    }
}

pub fn parseFileName(path: []const u8) ParseError!Run {
    const stem = std.fs.path.stem(path);
    const ext = std.fs.path.extension(path);

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
        .path = path,
        .num = num,
        .name = name,
        .date = date,
        .time = time,
        .channel = channel,
        .format = format,
    };
}

pub fn runHash(run: Run) u64 {
    var hash = std.hash.Wyhash.init(42);
    hash.update(run.num);
    hash.update(run.name);
    hash.update(run.date);
    hash.update(run.time);
    return hash.final();
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
