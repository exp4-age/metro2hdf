const std = @import("std");
const Io = std.Io;

const glob = @import("glob.zig");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

const usage =
    \\Usage: metro2hdf [OPTIONS]...
    \\
    \\  -o, --output-dir=DIR            write hdf5 files into the specified
    \\                                  directory (default: ".")
    \\      --glob=GLOB                 glob string for selecting metro run
    \\                                  files (default: "*")
    \\  -e, --exclude=CHANNEL           exclude matching channels from
    \\                                  processing (can be a glob string)
    \\  -i, --include=CHANNEL           include only matching channels in
    \\                                  the processing
    \\      --replace                   overwrite existing files
    \\      --help                      show this help and exit
    \\
    \\HPTDC OPTIONS
    \\      --hptdc-rebuild-tables      force rebuild of step tables by
    \\                                  searching for scan and step markers
    \\
    \\HPTDC OPTIONS (GRPS mode)
    \\      --hptdc-event-type={EP,EI}  type of recorded particles
    \\                                  (default: "EP")
    \\
    \\HPTDC OPTIONS (HITS mode)
    \\      --hptdc-hit-filter=FILTER   specify a filter for the tdc
    \\                                  channels (default: "01111111")
    \\      --hptdc-hit-mcp=NUM         tdc channel number of the MCP
    \\                                  (default: 6) from 0 to 7
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Track the time
    const clock: Io.Clock = .real;
    const timer_start = clock.now(io);

    // Get the c allocator because we interface with hdf5
    const allocator = std.heap.c_allocator;

    // Default options for metro2hdf:
    var pattern: [:0]const u8 = "*";
    var output_dir: []const u8 = ".";
    var replace = false;
    var exclude: std.ArrayList([:0]const u8) = .empty;
    defer exclude.deinit(allocator);
    var include: std.ArrayList([:0]const u8) = .empty;
    defer include.deinit(allocator);
    var options = metro.Options{};

    // Parse command line arguments
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        // Show usage if argument parsing fails
        errdefer std.log.info("Could not parse argument: {s}", .{arg});
        errdefer std.log.info("{s}", .{usage});

        if (std.mem.startsWith(u8, arg, "--glob=")) {
            pattern = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            output_dir = arg[13..];
        } else if (std.mem.startsWith(u8, arg, "-o=")) {
            output_dir = arg[3..];
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try exclude.append(allocator, arg[10..]);
        } else if (std.mem.startsWith(u8, arg, "-e=")) {
            try exclude.append(allocator, arg[3..]);
        } else if (std.mem.startsWith(u8, arg, "--include=")) {
            try include.append(allocator, arg[10..]);
        } else if (std.mem.startsWith(u8, arg, "-i=")) {
            try include.append(allocator, arg[3..]);
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        } else if (std.mem.eql(u8, arg, "--hptdc-rebuild-tables")) {
            options.hptdc_rebuild_tables = true;
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EP")) {
            options.hptdc_event_type = 'P';
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EI")) {
            options.hptdc_event_type = 'I';
        } else if (std.mem.startsWith(u8, arg, "--hptdc-hit-filter=")) {
            if (std.fmt.parseInt(u8, arg[19..], 2)) |filter| {
                options.hptdc_hit_filter = filter;
            } else |err| {
                return err;
            }
        } else if (std.mem.startsWith(u8, arg, "--hptdc-hit-mcp=")) {
            if (std.fmt.parseInt(u64, arg[16..], 10)) |channel| {
                if (channel > 7) return error.UnsupportedTdcChannel;
                options.hptdc_hit_mcp = @intCast(channel);
            } else |err| {
                return err;
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.log.info("{s}", .{usage});
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const parent_progress_node = std.Progress.start(io, .{ .root_name = "μετρο2hdf" });
    defer parent_progress_node.end();

    // Get current working directory for glob'ing
    const dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    // Try opening output directory
    const out_dir = try dir.openDir(io, output_dir, .{});
    defer out_dir.close(io);

    // Keep track of already touched files
    var run_table = try metro.RunTable.init(allocator);
    defer run_table.deinit();

    // Keep track of some statistics for the print summary
    var matching_run_files: usize = 0;
    var skipped_run_files: usize = 0;

    // Start glob'ing of files
    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip non files
        if (entry.kind != .file) continue;

        // Skip if the path does not match the glob pattern
        if (!glob.globMatch(pattern, entry.path)) continue;

        matching_run_files += 1;

        // Parse the file name and skip if it fails
        run_table.addChannel(entry.path, exclude.items, include.items) catch |err| {
            if (err != error.ExcludedChannel) {
                std.log.warn("skipping {s}: {s}", .{ entry.path, @errorName(err) });
            }
            skipped_run_files += 1;
            continue;
        };
    }

    // Keep track of some statistics for the print summary
    var processed_channels: usize = 0;
    var skipped_channels: usize = 0;
    var new_files: usize = 0;
    var replaced_files: usize = 0;
    var skipped_files: usize = 0;
    var input_size: u64 = 0;
    var output_size: u64 = 0;

    // Start processing of runs
    const progress_runs = parent_progress_node.start("runs", run_table.getLength());
    errdefer progress_runs.end();

    while (run_table.next()) |run| {
        // Construct name and path for the hdf5 file
        const filename = try std.fmt.allocPrint(allocator, "{s}_{s}_{s}_{s}.h5", .{ run.num, run.name, run.date, run.time });
        defer allocator.free(filename);
        const filepath = try std.fs.path.resolve(allocator, &[_][]const u8{ output_dir, filename });
        defer allocator.free(filepath);

        // Check if the file already exists
        if (out_dir.access(io, filename, .{ .read = true, .write = true })) {
            if (!replace) {
                std.log.info("skipping {s}: file already exists", .{filepath});
                skipped_files += 1;
                continue;
            } else {
                out_dir.deleteFile(io, filename) catch |err| {
                    std.log.err("skipping {s}: {s}", .{ filepath, @errorName(err) });
                    skipped_files += 1;
                    continue;
                };
                replaced_files += 1;
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                new_files += 1;
            },
            else => {
                std.log.err("skipping {s}: {s}", .{ filepath, @errorName(err) });
                skipped_files += 1;
            },
        }

        // Create the output hdf5 file
        const path = try allocator.dupeSentinel(u8, filepath, 0);
        defer allocator.free(path);
        var h5f = hdf5.File.create(path) catch |err| {
            std.log.err("skipping {s}: {s}", .{ filepath, @errorName(err) });
            continue;
        };
        defer h5f.close();

        // Write run attributes
        h5f.writeRootAttrs(run, allocator) catch {};

        // Iterate over all channels
        const progress_channels = progress_runs.start("channels", run.channels.items.len);
        defer progress_channels.end();

        for (run.channels.items) |ch| {
            progress_channels.completeOne();

            // Open input file
            var file = try dir.openFile(io, ch.path, .{ .mode = .read_only });
            defer file.close(io);

            // Parse data and write to the hdf5 file
            ch.parse(&file, &h5f, io, allocator, options) catch |err| {
                std.log.err("skipping {s}: {s}", .{ ch.name, @errorName(err) });
                skipped_channels += 1;
                continue;
            };
            processed_channels += 1;

            if (file.stat(io)) |stat| {
                input_size += stat.size;
            } else |_| {}
        }

        output_size += h5f.getSize() catch 0;
    }

    progress_runs.end();

    // Print summary
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.printAscii("μετρο2hdf summary\n", .{});
    try stdout_writer.printAscii("Processed files : ", .{});
    try stdout_writer.print("{d} matching ({d} skipped)\n", .{
        matching_run_files,
        skipped_run_files,
    });

    try stdout_writer.printAscii("HDF5 output     : ", .{});
    try stdout_writer.print("{d} written ({d} new, {d} replaced, {d} skipped)\n", .{
        new_files + replaced_files,
        new_files,
        replaced_files,
        skipped_files,
    });

    try stdout_writer.printAscii("Channels        : ", .{});
    try stdout_writer.print("{d} total ({d} skipped)\n", .{
        processed_channels,
        skipped_channels,
    });

    const elapsed_time = timer_start.untilNow(io, clock);
    const elapsed_time_in_s = @max(elapsed_time.toSeconds(), 1);

    try stdout_writer.printAscii("Read bytes      : ", .{});
    try formatFilesize(stdout_writer, input_size);
    try stdout_writer.printAscii(" total (", .{});
    try formatFilesize(stdout_writer, try std.math.divCeil(u64, input_size, elapsed_time_in_s));
    try stdout_writer.printAscii("/s)\n", .{});

    try stdout_writer.printAscii("Write bytes     : ", .{});
    try formatFilesize(stdout_writer, output_size);
    try stdout_writer.printAscii(" total (", .{});
    try formatFilesize(stdout_writer, try std.math.divCeil(u64, output_size, elapsed_time_in_s));
    try stdout_writer.printAscii("/s)\n", .{});

    try stdout_writer.printAscii("Elapsed time    : ", .{});
    try elapsed_time.format(stdout_writer);
    try stdout_writer.printAsciiChar('\n', .{});
    try stdout_writer.flush();
}

fn formatFilesize(w: *Io.Writer, bytes: u64) Io.Writer.Error!void {
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
                var inner: Io.Writer = .fixed(decimal_buf[1..]);
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
