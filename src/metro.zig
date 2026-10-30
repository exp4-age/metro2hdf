const std = @import("std");

pub const Channel = @import("metro/Channel.zig");
pub const Run = @import("metro/Run.zig");
pub const RunTable = @import("metro/RunTable.zig");

pub const Options = struct {
    hptdc_rebuild_tables: bool = false,
    hptdc_event_type: u8 = 'P',
    legacy_event_names: bool = false,
    hptdc_hit_filter: u8 = (@as(u8, 1) << 7) - 1,
    hptdc_hit_mcp: u3 = 6,
    chunk_size: usize = 0,
};

pub const Summary = struct {
    matching_run_files: usize = 0,
    skipped_run_files: usize = 0,
    new_files: usize = 0,
    replaced_files: usize = 0,
    skipped_files: usize = 0,
    processed_channels: usize = 0,
    skipped_channels: usize = 0,
    input_size: u64 = 0,
    output_size: u64 = 0,
    timer: std.Io.Timestamp,
    io: std.Io,

    pub fn start_timer(io: std.Io) Summary {
        const clock: std.Io.Clock = .real;
        return .{ .timer = clock.now(io), .io = io };
    }

    pub fn write(
        self: *@This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.printAscii("μετρο2hdf summary\n", .{});
        try w.printAscii("Processed files : ", .{});
        try w.print("{d} matching ({d} skipped)\n", .{
            self.matching_run_files,
            self.skipped_run_files,
        });

        try w.printAscii("HDF5 output     : ", .{});
        try w.print("{d} written ({d} new, {d} replaced, {d} skipped)\n", .{
            self.new_files + self.replaced_files,
            self.new_files,
            self.replaced_files,
            self.skipped_files,
        });

        try w.printAscii("Channels        : ", .{});
        try w.print("{d} total ({d} skipped)\n", .{
            self.processed_channels,
            self.skipped_channels,
        });

        const clock: std.Io.Clock = .real;
        const elapsed_time = self.timer.untilNow(self.io, clock);
        const elapsed_time_in_s = @max(elapsed_time.toSeconds(), 1);

        try w.printAscii("Read bytes      : ", .{});
        try w.print("{B:.2} total ({B:.2}/s)\n", .{
            self.input_size,
            std.math.divCeil(u64, self.input_size, elapsed_time_in_s) catch 0,
        });

        try w.printAscii("Write bytes     : ", .{});
        try w.print("{B:.2} total ({B:.2}/s)\n", .{
            self.output_size,
            std.math.divCeil(u64, self.output_size, elapsed_time_in_s) catch 0,
        });

        try w.printAscii("Elapsed time    : ", .{});
        try elapsed_time.format(w);
        try w.printAsciiChar('\n', .{});
        try w.flush();
    }
};
