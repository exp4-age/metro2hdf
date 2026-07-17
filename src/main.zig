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
    \\  -e, --exclude=CHANNEL           exclude channel from processing
    \\                                  (can be a glob string)
    \\      --replace                   overwrite existing files
    \\      --help                      show this help and exit
    \\
    \\HDF5 OPTIONS (only affects specific channels)
    \\      --chunk-size=SIZE           chunk size (bytes) used when
    \\                                  writing compressed datasets
    \\                                  (default: 1e5)
    \\      --compress=LEVEL            use gzip compression with specified
    \\                                  level (default: 4) from 0 to 9
    \\                                  (no compression to max compression)
    \\
    \\HPTDC OPTIONS (GRPS mode only)
    \\      --hptdc-decode-words        decode words generated in certain
    \\                                  operation modes (4 bytes per word)
    \\                                  into its type and argument
    \\                                  (8 bytes per word)
    \\      --hptdc-sort-events         decode words and sort events
    \\      --hptdc-event-type={EP,EI}  type of recorded particles
    \\                                  (default: "EP")
    \\      --other=PARTICLES           add a coincedence category to the
    \\                                  sorting of events, e.g. 3E1P, 5E
    \\                                  (may be specified more than once)
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Default options for metro2hdf:
    var pattern: []const u8 = "*";
    var output_dir: []const u8 = ".";
    var replace = false;
    var exclude: std.ArrayList([]const u8) = .empty;
    defer exclude.deinit(allocator);
    var options = metro.Options{};
    defer options.deinit(allocator);

    // Parse command line arguments
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--glob=")) {
            pattern = arg[7..];
            continue;
        } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            output_dir = arg[13..];
            continue;
        } else if (std.mem.startsWith(u8, arg, "-o=")) {
            output_dir = arg[3..];
            continue;
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try exclude.append(allocator, arg[10..]);
            continue;
        } else if (std.mem.startsWith(u8, arg, "-e=")) {
            try exclude.append(allocator, arg[3..]);
            continue;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
            continue;
        } else if (std.mem.startsWith(u8, arg, "--chunk-size=")) {
            if (std.fmt.parseInt(usize, arg[13..], 10)) |chunk_size| {
                options.chunk_size = chunk_size;
                continue;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--compress=")) {
            if (std.fmt.parseInt(usize, arg[11..], 10)) |compress| {
                if (compress >= 0 and compress < 10) {
                    options.compress = compress;
                    continue;
                }
            } else |_| {}
        } else if (std.mem.eql(u8, arg, "--hptdc-decode-words")) {
            options.hptdc_decode_words = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--hptdc-sort-events")) {
            options.hptdc_sort_events = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EP")) {
            options.hptdc_event_type = 'P';
            continue;
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EI")) {
            options.hptdc_event_type = 'I';
            continue;
        } else if (std.mem.startsWith(u8, arg, "--other=")) {
            options.hptdc_sort_events = true;
            try options.hptdc_other.append(allocator, arg[8..]);
            continue;
        }
        try stdout_writer.printAscii(usage, .{});
        try stdout_writer.flush();
        return;
    }

    // Get current working directory for glob'ing
    const dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    // Try opening output directory
    const out_dir = dir.openDir(io, output_dir, .{}) catch |err| {
        std.log.err("could not open output directory {s}: {s}", .{ output_dir, @errorName(err) });
        try stdout_writer.printAscii(usage, .{});
        try stdout_writer.flush();
        return;
    };
    defer out_dir.close(io);

    // Keep track of already touched files
    var run_table = try metro.RunTable.init(allocator);
    defer run_table.deinit();

    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip non files
        if (entry.kind != .file) continue;

        // Skip if the path does not match the glob pattern
        if (!glob.globMatch(pattern, entry.path)) continue;

        // Parse the file name and skip if it fails
        run_table.addChannel(entry.path, exclude.items) catch |err| {
            std.log.info("skipping {s}: {s}", .{ entry.path, @errorName(err) });
            continue;
        };
    }

    while (run_table.next()) |run| {
        try stdout_writer.print("run {s}:\n", .{run.num});
        try stdout_writer.flush();

        // Construct name and path for the hdf5 file
        const filename = try std.fmt.allocPrint(allocator, "{s}_{s}_{s}_{s}.h5", .{ run.num, run.name, run.date, run.time });
        defer allocator.free(filename);
        const filepath = try std.fs.path.resolve(allocator, &[_][]const u8{ output_dir, filename });
        defer allocator.free(filepath);

        // Check if the file already exists
        if (out_dir.access(io, filename, .{ .read = true, .write = true })) {
            if (!replace) {
                std.log.info("skipping {s}: file already exists", .{filepath});
                continue;
            } else {
                out_dir.deleteFile(io, filename) catch |err| {
                    std.log.err("skipping {s}: {s}", .{ filepath, @errorName(err) });
                    continue;
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.err("skipping {s}: {s}", .{ filepath, @errorName(err) });
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
        h5f.writeRootAttrs(run) catch {};

        // Iterate over all channels
        for (run.channels.items) |ch| {
            // Update stdout to indicate the channel that is being processed
            try stdout_writer.print("  {s} ... ", .{ch.name});
            try stdout_writer.flush();

            // Parse data and write to the hdf5 file
            ch.parse(&h5f, io, allocator, options) catch |err| {
                try stdout_writer.print("skipping: {s}\n", .{@errorName(err)});
                try stdout_writer.flush();
                continue;
            };

            try stdout_writer.printAscii("done\n", .{});
            try stdout_writer.flush();
        }
    }
}
