const std = @import("std");

const Options = struct {
    recursive: bool = false,
    interactive: bool = false,
    preserve: bool = false,
    force: bool = false,
};

const FileType = enum {
    file,
    directory,
    other,
};

const CopyError = error{
    SourceNotFound,
    DestinationNotWritable,
    InsufficientPermissions,
    UnsupportedFileType,
    NotADirectory,
    OutOfMemory,
    ReadOnlyFileSystem,
    LinkQuotaExceeded,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.fs.Dir.OpenError;

const ArgsError = error{ UnknownOption, InvalidArgument };
const FileError = error{ UnknownFileType, FileNotFound };
const UserError = error{NotADirectory};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var options: Options = Options{};
    var sources = std.ArrayList([]const u8).init(allocator);
    defer sources.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "-r")) {
                options.recursive = true;
            } else if (std.mem.eql(u8, arg, "-i")) {
                options.interactive = true;
            } else if (std.mem.eql(u8, arg, "-p")) {
                options.preserve = true;
            } else if (std.mem.eql(u8, arg, "-f")) {
                options.force = true;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                return error.InvalidArgument;
            }
        } else {
            try sources.append(arg);
        }
    }

    if (sources.items.len < 2) {
        std.debug.print("Usage: zcp [OPTIONS] SOURCE... DESTINATION\n", .{});
        return error.InvalidArgument;
    }

    const destination = sources.pop();
    const destination_type = try get_file_type(destination);

    if (sources.items.len > 1) {
        if (destination_type == .file) {
            std.debug.print("zcp: target '{s}' is not a directory\n", .{destination});
            return error.NotADirectory;
        } else if (destination_type == .other) {
            std.debug.print("zcp: cannot overwrite non-regular file '{s}'\n", .{destination});
            return error.UnsupportedFileType;
        }
    }

    for (sources.items) |source| {
        const dest_path = switch (destination_type) {
            .directory => try std.fs.path.join(allocator, &[_][]const u8{ destination, std.fs.path.basename(source) }),
            else => destination,
        };
        defer if (destination_type == .directory) allocator.free(dest_path);

        copy_file_or_dir(allocator, source, dest_path, &options) catch |err| {
            switch (err) {
                error.SourceNotFound => std.debug.print("Source not found: {s}\n", .{source}),
                error.DestinationNotWritable => std.debug.print("Destination not writable: {s}\n", .{dest_path}),
                error.InsufficientPermissions => std.debug.print("Insufficient permissions\n", .{}),
                error.UnsupportedFileType => std.debug.print("Unsupported file type: {s}\n", .{source}),
                error.NotADirectory => std.debug.print("Not a directory: {s}\n", .{destination}),
                error.OutOfMemory => std.debug.print("Out of memory\n", .{}),
                error.ReadOnlyFileSystem => std.debug.print("Read-only file system\n", .{}),
                else => {
                    std.debug.print("Unexpected error: {}\n", .{err});
                    return err;
                },
            }
        };
    }
}

fn get_file_type(path: []const u8) !FileType {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return FileType.file; // Assume it's a file if it doesn't exist
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

fn is_directory(path: []const u8) CopyError!bool {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };

    switch (stat.kind) {
        .directory => return true,
        .file => return false,
        else => return false,
    }
}

fn copy_file_or_dir(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *Options) CopyError!void {
    const source_type = try get_file_type(source);

    switch (source_type) {
        .file => try copy_file(allocator, source, destination, options),
        .directory => {
            if (!options.recursive) {
                std.debug.print("zcp: omitting directory '{s}'\n", .{source});
                return;
            }
            try std.fs.cwd().makePath(destination);
            try copy_dir(allocator, source, destination, options);
        },
        .other => return error.UnsupportedFileType,
    }
}

fn copy_file(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *Options) CopyError!void {
    std.debug.assert(source.len > 0);
    std.debug.assert(destination.len > 0);

    const source_file = try std.fs.cwd().openFile(source, .{});
    defer source_file.close();

    const destination_flags: std.fs.File.CreateFlags = if (options.force) .{ .truncate = true } else .{};
    const destination_file = try std.fs.cwd().createFile(destination, destination_flags);
    defer destination_file.close();

    const file_size_bytes = (try source_file.stat()).size;
    const buffer_size_bytes = compute_buffer_size(file_size_bytes);

    const buffer = try allocator.alloc(u8, buffer_size_bytes);
    defer allocator.free(buffer);

    var bytes_remaining: u64 = file_size_bytes;
    while (bytes_remaining > 0) {
        const bytes_to_read = @min(bytes_remaining, buffer_size_bytes);
        const bytes_read = try source_file.read(buffer[0..bytes_to_read]);
        if (bytes_read == 0) break;

        @prefetch(buffer.ptr, .{ .cache = .data, .rw = .read, .locality = 3 });
        try destination_file.writeAll(buffer[0..bytes_read]);
        bytes_remaining -= bytes_read;
    }

    if (options.preserve) {
        try preserve_metadata(source_file, destination_file);
    }
}

fn copy_dir(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *Options) CopyError!void {
    _ = try std.fs.cwd().makePath(destination);

    var dir = try std.fs.cwd().openDir(source, .{});
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const new_source = try std.fs.path.join(allocator, &[_][]const u8{ source, entry.name });
        defer allocator.free(new_source);
        const new_destination = try std.fs.path.join(allocator, &[_][]const u8{ destination, entry.name });
        defer allocator.free(new_destination);
        try copy_file_or_dir(allocator, new_source, new_destination, options);
    }
}

fn compute_buffer_size(file_size: u64) u64 {
    const max_buffer_size = 1024 * 1024 * 16; // 16 MB
    const min_buffer_size = 4096; // 4 KB
    if (file_size <= min_buffer_size) {
        return @intCast(file_size);
    } else if (file_size <= max_buffer_size * 4) {
        const size = @min(@as(u64, @intCast(file_size / 4)), max_buffer_size);
        return size;
    } else {
        return max_buffer_size;
    }
}

fn preserve_metadata(source: std.fs.File, destination: std.fs.File) !void {
    const metadata = try source.metadata();
    try destination.setPermissions(metadata.permissions());
}

fn prompt_for_overwrite(path: []const u8) !bool {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().reader();

    try stdout.print("zcp: overwrite '{s}'?", .{path});

    var buffer: [4]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(buffer[0..], "\n")) |input| {
        return std.ascii.eqlIgnoreCase(input, "y");
    }

    return false;
}
