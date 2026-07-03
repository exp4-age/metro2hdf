const std = @import("std");
const Io = std.Io;

const glob = @import("glob.zig");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("metro2hdf\n", .{});
    try stdout_writer.flush();

    // Default options for metro2hdf:
    var pattern: []const u8 = "*";
    var output_dir: []const u8 = ".";
    var replace = false;

    // Accessing command line arguments:
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--glob")) {
            pattern = args.next() orelse return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = args.next() orelse return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        }
    }

    // Get current working directory for glob'ing
    const dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    // Try opening output directory
    const out_dir = dir.openDir(io, output_dir, .{}) catch |err| return {
        std.log.info("could not open output directory: {s}", .{output_dir});
        return err;
    };
    std.log.info("saving files to: {s}", .{output_dir});
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
        // std.log.info("found: {s}", .{entry.basename});

        // Parse the file name and skip if it fails
        run_table.addChannel(entry.path) catch |err| {
            std.log.info("skipping {s}: {s}", .{entry.path, @errorName(err)});
            continue;
        };

    }

    while (run_table.next()) |run| {
        try stdout_writer.print("run {s}: ", .{run.num});
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
                    std.log.info("skipping {s}: {s}", .{filepath, @errorName(err)});
                    continue;
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.info("skipping {s}: {s}", .{filepath, @errorName(err)});
            },
        }

        // Create the output hdf5 file
        const path = try arena.dupeSentinel(u8, filepath, 0);
        var h5f = hdf5.File.create(path) catch |err| {
            std.log.info("skipping {s}: {s}", .{filepath, @errorName(err)});
            continue;
        };
        defer h5f.close();

        // Write run attributes
        h5f.writeRootAttrs(run) catch {};

        // Iterate over all channels
        for (run.channels.items) |ch| {
            // Update stdout to indicate the channel that is being processed
            try stdout_writer.print("run {s}: {s}", .{run.num, ch.name});
            try stdout_writer.flush();

            // Parse data and write to the hdf5 file
            ch.parse(&h5f, io, arena) catch |err| {
                try stdout_writer.printAscii("\r\x1b[2K", .{});
                try stdout_writer.flush();
                std.log.warn("skipping {s}: {s}", .{ch.name, @errorName(err)});
                continue;
            };

            // Reset stdout
            try stdout_writer.printAscii("\r\x1b[2K", .{});
            try stdout_writer.flush();
        }

        try stdout_writer.print("run {s}: done\n", .{run.num});
        try stdout_writer.flush();
    }
}
