const std = @import("std");
const builtin = @import("builtin");

const Scanner = @import("Scanner.zig");
const Parser = @import("Parser.zig");
const Interpreter = @import("Interpreter.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi)
            break :gpa .{ std.heap.wasm_allocator, false };

        switch (builtin.mode) {
            .Debug, .ReleaseSafe => break :gpa .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => break :gpa .{ std.heap.smp_allocator, false },
        }
    };

    defer if (is_debug)
        std.debug.assert(debug_allocator.deinit() == .ok);

    // preallocate room for 8 files should be enough
    var file_list: std.ArrayListUnmanaged(std.fs.File) = try .initCapacity(allocator, 8);
    defer {
        for (file_list.items) |file| {
            file.close();
        }
        defer file_list.deinit(allocator);
    }

    var initial_value: ?u64 = null;

    var entry_point: ?[]const u8 = null;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const arg0 = args.next() orelse
        return error.NoArg0;
    _ = arg0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--value")) {
            if (initial_value != null)
                return error.TooManyValues;

            const value_arg = args.next() orelse
                return error.MissingValueArg;

            initial_value = try std.fmt.parseInt(u64, value_arg, 10);
        } else if (std.mem.eql(u8, arg, "--entry")) {
            if (entry_point != null)
                return error.TooManyEntryPoints;

            const entry_arg = args.next() orelse
                return error.MissingEntryPointArg;

            entry_point = entry_arg;
        } else if (std.mem.eql(u8, arg, "--help")) {} else {
            const file = try std.fs.cwd().openFile(arg, .{});
            try file_list.append(allocator, file);
        }
    }

    if (file_list.items.len == 0)
        return error.NoFilesSpecified;

    initial_value = initial_value orelse 0;

    try run(
        initial_value.?,
        entry_point orelse "main",
        file_list.items,
        allocator,
    );
}

fn run(
    initial_value: u64,
    entry_point: []const u8,
    files: []const std.fs.File,
    allocator: std.mem.Allocator,
) !void {
    const stderr = std.io.getStdErr().writer();

    var scanner: Scanner = .init(allocator);
    defer scanner.deinit();

    var tokens_or_errors = try scanner.scan(files);
    const tokens = switch (tokens_or_errors) {
        .tokens => |tokens| tokens.items,
        .errors => |*errors| {
            for (errors.items) |err| {
                try stderr.print("{}\n\n", .{err});
            }

            return error.ScanError;
        },
    };

    var parser: Parser = .init(allocator, tokens);
    defer parser.deinit();

    const functions_or_errors = try parser.parse();

    const functions: Parser.Functions = switch (functions_or_errors) {
        .errors => |parse_errors| {
            for (parse_errors) |err| {
                try stderr.print("{}\n\n", .{err});
            }

            return error.ParseError;
        },
        .functions => |functions| functions,
    };

    var interpreter: Interpreter = try .init(
        initial_value,
        functions,
        allocator,
    );
    defer interpreter.deinit();

    try interpreter.interpret(entry_point);
}
