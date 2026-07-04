const std = @import("std");
const Io = std.Io;

const glob = @import("glob.zig");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

const usage =
    \\Usage: metro2hdf [OPTIONS]...
    \\
    \\  -o, --output-dir DIR            write hdf5 files into the specified
    \\                                  directory (default: ".")
    \\      --glob GLOB                 glob string for selecting metro run
    \\                                  files (default: "*")
    \\      --replace                   overwrite existing files
    \\      --help                      show this help and exit
    \\
    \\HDF5 OPTIONS
    \\      --compress [LEVEL]          use gzip compression with optionally
    \\                                  specified level (default: 4)
    \\
    \\HPTDC OPTIONS
    \\      --hptdc-chunk-size SIZE     number of data elements to read,
    \\                                  convert and store at a time
    \\                                  (default: 1e5)
    \\      --hptdc-ignore-tables       ignore scan and step tables in the
    \\                                  TDC file and rebuild them by
    \\                                  searching for the markers
    \\      --hptdc-decode-words        decode words generated in certain
    \\                                  operation modes (4 bytes per word)
    \\                                  into its type and argument
    \\                                  (8 bytes per word)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Default options for metro2hdf:
    var pattern: []const u8 = "*";
    var output_dir: []const u8 = ".";
    var replace = false;

    // Parse command line arguments
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--glob")) {
            if (args.next()) |val| {
                pattern = val;
                continue;
            }
        } else if (std.mem.eql(u8, arg, "--output-dir") or std.mem.eql(u8, arg, "-o")) {
            if (args.next()) |val| {
                output_dir = val;
                continue;
            }
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--compress")) {
            return error.NotImplemented;
        } else if (std.mem.eql(u8, arg, "--hptdc-chunk-size")) {
            return error.NotImplemented;
        } else if (std.mem.eql(u8, arg, "--hptdc-ignore-tables")) {
            return error.NotImplemented;
        } else if (std.mem.eql(u8, arg, "--hptdc-decode-words")) {
            return error.NotImplemented;
        }
        try stdout_writer.printAscii(usage, .{});
        try stdout_writer.flush();
        return;
    }

    // Get current working directory for glob'ing
    const dir = try Io.Dir.cwd().openDir(io, ".", .{.iterate=true});
    defer dir.close(io);

    // Try opening output directory
    const out_dir = dir.openDir(io, output_dir, .{}) catch |err| {
        std.log.err("could not open output directory {s}: {s}", .{output_dir, @errorName(err)});
        try stdout_writer.printAscii(usage, .{});
        try stdout_writer.flush();
        return;
    };
    defer out_dir.close(io);

    // Keep track of already touched files
    var run_table = try metro.RunTable.init(arena);
    defer run_table.deinit();

    var walker = try Io.Dir.walk(dir, arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip non files
        if (entry.kind != .file) continue;

        // Skip if the path does not match the glob pattern
        if (!glob.globMatch(pattern, entry.path)) continue;

        // Parse the file name and skip if it fails
        run_table.addChannel(entry.path) catch |err| {
            std.log.info("skipping {s}: {s}", .{entry.path, @errorName(err)});
            continue;
        };
    }

    while (run_table.next()) |run| {
        try stdout_writer.print("run {s}:\n", .{run.num});
        try stdout_writer.flush();

        // Construct name and path for the hdf5 file
        const filename = try std.fmt.allocPrint(
            arena, "{s}_{s}_{s}_{s}.h5", .{run.num, run.name, run.date, run.time}
        );
        const filepath = try std.fs.path.resolve(arena, &[_][]const u8{output_dir, filename});

        // Check if the file already exists
        if (out_dir.access(io, filename, .{.read=true, .write=true})) {
            if (!replace) {
                std.log.info("skipping {s}: file already exists", .{filepath});
                continue;
            } else {
                out_dir.deleteFile(io, filename) catch |err| {
                    std.log.err("skipping {s}: {s}", .{filepath, @errorName(err)});
                    continue;
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.err("skipping {s}: {s}", .{filepath, @errorName(err)});
            },
        }

        // Create the output hdf5 file
        const path = try arena.dupeSentinel(u8, filepath, 0);
        var h5f = hdf5.File.create(path) catch |err| {
            std.log.err("skipping {s}: {s}", .{filepath, @errorName(err)});
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
            ch.parse(&h5f, io, arena) catch |err| {
                try stdout_writer.print("skipping: {s}\n", .{@errorName(err)});
                try stdout_writer.flush();
                continue;
            };

            try stdout_writer.printAscii("done\n", .{});
            try stdout_writer.flush();
        }
    }
}
