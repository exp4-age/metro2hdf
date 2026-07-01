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

    // Keep track of already touched files
    var run_table = std.AutoHashMap(u64, [:0]const u8).init(arena);
    defer run_table.deinit();
    var last_run: u64 = undefined;

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

        // Create hash with run info
        const hash = metro.runHash(run);

        // Check if a different channel was already processed for this run
        if (hash == last_run) {
            metro.parseChannel(dir, run, &hdf5_file, io, arena);
            continue;
        }

        // Open already created hdf5 file
        if (run_table.get(hash)) |hdf5_path| {
            last_run = hash;
            try hdf5_file.open(hdf5_path);
            metro.parseChannel(dir, run, &hdf5_file, io, arena);
            continue;
        }

        // Construct path for the hdf5 file
        const filename = try std.fmt.allocPrint(arena, "{s}_{s}.h5", .{run.num, run.name});
        const filepath = try std.fs.path.resolve(arena, &[_][]const u8{output_dir, filename});

        // Check if the file already exists
        if (out_dir.access(io, filename, .{.read=true, .write=true})) {
            if (!replace) {
                std.log.info("  skipping: hdf5 file already exists", .{});
                continue;
            }
            try out_dir.deleteFile(io, filename);
        } else |_| {}

        // Add null termination for hdf5
        const hdf5_path = try arena.dupeSentinel(u8, filepath, 0);

        // Update run table and last opened run
        try run_table.putNoClobber(hash, hdf5_path);
        last_run = hash;

        // Create a new hdf5 file
        try hdf5_file.create(hdf5_path);

        // Write run attributes into the root group
        try hdf5_file.write_attrs(run);

        // Parse and write the data
        metro.parseChannel(dir, run, &hdf5_file, io, arena);
    }
}
