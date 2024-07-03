const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const time = std.time;
const Allocator = std.mem.Allocator;

const FileMetadata = struct {
    name: []const u8,
    size: u64,
    mode: fs.File.Mode,
    modified_time: i128,
};

const Options = struct {
    long_format: bool = false,
    human_readable: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = Options{};
    var path: []const u8 = ".";

    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "-l")) {
            options.long_format = true;
        } else if (mem.eql(u8, arg, "-h")) {
            options.human_readable = true;
        } else if (!mem.startsWith(u8, arg, "-")) {
            path = arg;
        }
    }

    var dir = try fs.cwd().openDir(path, .{});
    defer dir.close();

    var files_metadata = std.ArrayList(FileMetadata).init(allocator);
    defer files_metadata.deinit();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const stat = try dir.statFile(entry.name);
        try files_metadata.append(FileMetadata{
            .name = try allocator.dupe(u8, entry.name),
            .size = stat.size,
            .mode = stat.mode,
            .modified_time = stat.mtime,
        });
    }

    const stdout = io.getStdOut().writer();

    for (files_metadata.items) |info| {
        if (options.long_format) {
            try print_long_format(stdout, info, options.human_readable);
        } else {
            try stdout.print("{s}\n", .{info.name});
        }
    }
}

fn print_long_format(writer: anytype, info: FileMetadata, human_readable: bool) !void {
    const size_str = if (human_readable)
        try format_size(info.size)
    else
        try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{info.size});
    defer if (human_readable) std.heap.page_allocator.free(size_str);

    // @TODO: implement time formatting
    // const time_str = try format_time(info.modified_time);
    try writer.print("{s:>8} {s}\n", .{
        size_str, info.name,
    });
}

fn format_size(size: u64) ![]u8 {
    const units = [_]u8{ 'B', 'K', 'M', 'G', 'T', 'P' };
    var unit_index: usize = 0;
    var adjusted_size: f64 = @as(f64, @floatFromInt(size));

    while (adjusted_size >= 1024 and unit_index < units.len - 1) : (unit_index += 1) {
        adjusted_size /= 1024;
    }

    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "{d:.1}{c}",
        .{ adjusted_size, units[unit_index] },
    );
}

// fn format_time(timestamp: i128) ![20]u8 {
//     var result: [20]u8 = undefined;
//     const seconds = @divFloor(timestamp, std.time.ns_per_s);
//     const nanos = @mod(seconds, std.time.ns_per_s);
//
//     const unix_timestamp = @as(i64, @intCast(seconds));
//
//     const epoch_seconds = std.time.epoch.EpochSeconds(.{ .secs = @max(0, unix_timestamp) });
//
//     //@TODO: implement
//     _ = try std.fmt.bufPrint(
//         &result,
//         "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
//         .{
//             tm.year + 1900, tm.mon + 1, tm.day,
//             tm.hour,        tm.min,     tm.sec,
//         },
//     );
//     return result;
// }
