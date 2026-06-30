const std = @import("std");
const Io = std.Io;

const glob = @import("glob");
const metro = @import("metro");

const UsageError = error {
    MissingValue,
};

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
            pattern = args.next() orelse return UsageError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = args.next() orelse return UsageError.MissingValue;
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

    // Create an HDF5 file manager
    var hdf5_file = metro.H5File{};
    defer hdf5_file.close();

    var walker = try Io.Dir.walk(dir, arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip non files
        if (entry.kind != .file) continue;

        // Skip if the path does not match the glob pattern
        if (!glob.globMatch(pattern, entry.path)) continue;
        std.log.info("found: {s}", .{entry.basename});

        // Parse the file name and skip if it fails
        const run = metro.parseFileName(entry.path) catch |err| {
            std.log.info("  skipping: {s}", .{@errorName(err)});
            continue;
        };

        const filename = try std.fmt.allocPrint(arena, "{s}_{s}.h5", .{run.num, run.name});
        const filepath = try std.fs.path.resolve(arena, &[_][]const u8{output_dir, filename});
        const c_path = try arena.dupeSentinel(u8, filepath, 0);

        try hdf5_file.open(c_path);
        try hdf5_file.write_attrs(run);
        // const input_file = try dir.openFile(io, entry.path, .{.mode=.read_only});
        // defer input_file.close(io);

        try metro.parseAsciiChannel(run, dir, io, arena);
    }
}
