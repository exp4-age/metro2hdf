const std = @import("std");
const Io = std.Io;

const glob = @import("glob.zig");
const metro = @import("metro.zig");
const hdf5 = @import("hdf5.zig");

const usage =
    \\Usage: metro2hdf [OPTIONS]...
    \\
    \\      --glob=GLOB                 glob string for selecting metro run
    \\                                  files from a recursive walk over the
    \\                                  current working directory
    \\                                  (default: "*")
    \\  -e, --exclude=CHANNEL           exclude matching channels from
    \\                                  processing (can be a glob string)
    \\  -i, --include=CHANNEL           include only matching channels in
    \\                                  the processing
    \\      --help                      show this help and exit
    \\
    \\OUTPUT OPTIONS
    \\  -o, --output-dir=DIR            write hdf5 files into the specified
    \\                                  directory (default: ".")
    \\      --short-names               shorten the output names to num.h5
    \\                                  (if there are multiple runs with
    \\                                  the same run number, only the first
    \\                                  one is processed)
    \\      --replace                   overwrite existing files
    \\
    \\HPTDC OPTIONS
    \\      --hptdc-rebuild-tables      force rebuild of step tables by
    \\                                  searching for scan and step markers
    \\
    \\HPTDC OPTIONS (GRPS mode)
    \\      --hptdc-event-type={EP,EI}  type of recorded particles
    \\                                  (default: "EP")
    \\      --legacy-event-names        use old event names, e.g. EEEP
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

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Get the c allocator because we interface with hdf5
    const allocator = std.heap.c_allocator;

    // Default options for metro2hdf:
    var pattern: [:0]const u8 = "*";
    var output_dir: []const u8 = ".";
    var short_names = false;
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
        errdefer |err| {
            std.log.err("could not parse argument '{s}': {t}", .{ arg, err });
            std.log.info("{s}", .{usage});
        }

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
        } else if (std.mem.eql(u8, arg, "--short-names")) {
            short_names = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        } else if (std.mem.eql(u8, arg, "--hptdc-rebuild-tables")) {
            options.hptdc_rebuild_tables = true;
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EP")) {
            options.hptdc_event_type = 'P';
        } else if (std.mem.eql(u8, arg, "--hptdc-event-type=EI")) {
            options.hptdc_event_type = 'I';
        } else if (std.mem.eql(u8, arg, "--legacy-event-names")) {
            options.legacy_event_names = true;
        } else if (std.mem.startsWith(u8, arg, "--hptdc-hit-filter=")) {
            options.hptdc_hit_filter = try std.fmt.parseInt(u8, arg[19..], 2);
        } else if (std.mem.startsWith(u8, arg, "--hptdc-hit-mcp=")) {
            const channel = try std.fmt.parseInt(u64, arg[16..], 10);
            if (channel > 7) return error.UnsupportedTdcChannel;
            options.hptdc_hit_mcp = @intCast(channel);
        } else if (std.mem.eql(u8, arg, "--help")) {
            stdout_writer.writeAll(usage) catch {};
            stdout_writer.flush() catch {};
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    var summary: metro.Summary = .start_timer(io);
    const parent_progress_node = std.Progress.start(io, .{ .root_name = "metro2hdf" });
    errdefer parent_progress_node.end();

    // Get current working directory for glob'ing input files
    const dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    // Try opening output directory
    const out_dir = try dir.openDir(io, output_dir, .{});
    defer out_dir.close(io);

    // Build a table of runs and channel files
    var run_table: metro.RunTable = .init(allocator);
    defer run_table.deinit();

    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (true) {
        const next = walker.next(io) catch |err| {
            std.log.warn("skipping directory entry: {t}", .{err});
            continue;
        };
        const entry = next orelse break;

        // Skip non files
        if (entry.kind != .file) continue;

        // Skip if the path does not match the glob pattern
        if (!glob.globMatch(pattern, entry.path)) continue;

        summary.matching_run_files += 1;

        // Parse the file name and skip if it fails
        run_table.addChannel(entry.path, exclude.items, include.items) catch |err| {
            if (err != error.ExcludedChannel) {
                std.log.warn("could not parse file name '{s}': {t}", .{ entry.path, err });
            }
            summary.skipped_run_files += 1;
            continue;
        };
    }

    // Sort the run table by num
    run_table.sort();

    // Start processing of runs
    const progress_runs = parent_progress_node.start("runs", run_table.count());
    errdefer progress_runs.end();

    var run_it = run_table.iterator();

    while (run_it.next()) |entry| {
        var run = entry.value_ptr;

        const filename = if (short_names)
            try std.fmt.allocPrint(allocator, "{s}.h5", .{run.num})
        else
            try std.fmt.allocPrint(allocator, "{s}_{s}_{s}_{s}.h5", .{ run.num, run.name, run.date, run.time });
        defer allocator.free(filename);
        const filepath = try std.fs.path.resolve(allocator, &[_][]const u8{ output_dir, filename });
        defer allocator.free(filepath);

        // Show which file is being written
        progress_runs.setName(filename);

        // Check if the file already exists
        if (out_dir.access(io, filename, .{ .read = true, .write = true })) {
            if (!replace) {
                std.log.info("skipping '{s}': file already exists", .{filepath});
                summary.skipped_files += 1;
                continue;
            } else {
                out_dir.deleteFile(io, filename) catch |err| {
                    std.log.warn("could not replace '{s}': {t}", .{ filepath, err });
                    summary.skipped_files += 1;
                    continue;
                };
                summary.replaced_files += 1;
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                summary.new_files += 1;
            },
            else => {
                std.log.warn("could not access '{s}': {t}", .{ filepath, err });
                summary.skipped_files += 1;
            },
        }

        // Create the output hdf5 file
        const path = try allocator.dupeSentinel(u8, filepath, 0);
        defer allocator.free(path);
        var h5f = hdf5.File.create(path) catch |err| {
            std.log.warn("could not create hdf5 file '{s}': {t}", .{ filepath, err });
            continue;
        };
        defer h5f.close();

        // Write run attributes
        run.writeAttrs(&h5f, allocator) catch |err| {
            std.log.warn("could not write attributes for run {s}: {t}", .{ run.num, err });
        };

        // Iterate over all channels
        const progress_channels = progress_runs.start("channels", run.channels.items.len);
        defer progress_channels.end();

        for (run.channels.items) |ch| {
            progress_channels.setName(ch.name);
            progress_channels.completeOne();

            // Open input file
            var file = try dir.openFile(io, ch.path, .{ .mode = .read_only });
            defer file.close(io);

            // Parse data and write to the hdf5 file
            if (ch.parse(&file, &h5f, io, allocator, options)) {
                // Add the size of the parsed file
                if (file.stat(io)) |stat| {
                    summary.input_size += stat.size;
                } else |_| {}
                summary.processed_channels += 1;
            } else |err| switch (err) {
                error.UnknownFormat => {
                    std.log.warn("unsupported format '{}' of channel '{s}' in run '{s}'", .{
                        ch.format,
                        ch.name,
                        run.num,
                    });
                    summary.skipped_channels += 1;
                },
                error.UnsupportedChannel => {
                    std.log.warn("unsupported channel '{s}' in run '{s}'", .{
                        ch.name,
                        run.num,
                    });
                    summary.skipped_channels += 1;
                },
                else => {
                    std.log.warn("failed to parse channel '{s}' in run '{s}': {t}", .{
                        ch.name,
                        run.num,
                        err,
                    });
                    summary.skipped_channels += 1;
                },
            }
        }

        // Try to get the number of written bytes
        summary.output_size += h5f.getSize() catch 0;
    }

    // End progress to clear stderr
    progress_runs.end();
    parent_progress_node.end();

    // Print summary
    summary.write(stdout_writer) catch |err| {
        std.log.warn("could not write stdout summary: {t}", .{err});
    };
}
