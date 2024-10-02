const std = @import("std");

comptime {
    std.testing.refAllDecls(@This());
}

const ReservedTokens = enum(u8) {
    increment = '+',
    decrement = '-',
    start_group = '{',
    end_group = '}',
    alternate = '|',
    comment = '#',
    input = '?', // ignored
    output = '!', // ignored outside of debug mode
    stack_trace = '@', // ignored outside of debug mode
    _,
};

const FileAddress = struct {
    file: std.fs.File,
    address: u64,
};

const CallData = struct {
    /// does not include '{' at start of definition
    depth_at_call: u64,
    /// null for calling entry point
    return_address: ?FileAddress,
    function_name: []const u8,
};

const FileError = std.fs.File.ReadError ||
    std.fs.File.SeekError ||
    std.mem.Allocator.Error;

const ScanError = error{
    InvalidTopLevelToken,
    UnnamedTopLevelGroup,
    UnopenedGroup,
    UnclosedGroup,
    FunctionWithoutGroup,
    DuplicateFunctionName,
} || FileError;

const ExecutionError = error{
    UndefinedFunctionCall,
    UnexpectedReturn,
} || FileError;

const InterpreterError = ScanError || ExecutionError;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var initial_number: std.math.big.int.Managed = try .init(allocator);
    defer initial_number.deinit();

    var optional_entry_name: ?[]const u8 = null;
    defer if (optional_entry_name) |entry_name| {
        allocator.free(entry_name);
    };
    var debug_mode = false;
    var files: std.ArrayList(std.fs.File) = .init(allocator);
    defer {
        for (files.items) |file| {
            file.close();
        }
        files.deinit();
    }

    const arg0 = args.next() orelse
        return error.NoArgs;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--number")) {
            const next_arg = args.next() orelse
                return error.ExpectedArg;
            try initial_number.setString(10, next_arg);
            if (!initial_number.isPositive())
                return error.NegativeInitialValue;
        } else if (std.mem.eql(u8, arg, "--entry")) {
            const next_arg = args.next() orelse
                return error.ExpectedArg;

            if (optional_entry_name == null) {
                optional_entry_name = try allocator.dupe(u8, next_arg);
            }
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else {
            try files.append(try std.fs.cwd().openFile(arg, .{}));
        }
    }

    if (files.items.len == 0) {
        try printHelp(arg0);
        return error.NoInput;
    }

    const stdout = std.io.getStdOut().writer();
    var result = try interpret(
        files.items,
        optional_entry_name orelse "main",
        initial_number.toConst(),
        debug_mode,
        allocator,
    );
    if (result) |*number| {
        defer number.deinit();

        const number_string = try number.toString(allocator, 10, .lower);
        defer allocator.free(number_string);

        try stdout.print("{s}\n", .{number_string});
    } else {
        try stdout.writeAll("-\n");
    }
}

// returns null if unarian code failed
fn interpret(
    input_files: []const std.fs.File,
    entry_function: []const u8,
    input_number: std.math.big.int.Const,
    debug_mode: bool,
    allocator: std.mem.Allocator,
) !?std.math.big.int.Managed {
    var function_map = try scanFunctions(input_files, allocator);
    defer freeFunctionMap(&function_map, allocator);

    var call_stack: std.ArrayList(CallData) = try .initCapacity(allocator, 32);
    defer call_stack.deinit();

    var number_stack: std.ArrayList(std.math.big.int.Managed) = try .initCapacity(allocator, 32);
    defer number_stack.deinit();

    var failed = false;
    var depth: u64 = 0;

    var current_file = callFunction(
        entry_function,
        &call_stack,
        function_map,
        null,
        depth,
        allocator,
    ) catch |err| switch (err) {
        error.UndefinedFunctionCall => return error.EntryPointNotFound,
        else => return err,
    };

    var number = try input_number.toManaged(allocator);
    defer number.deinit();

    while (try readToken(current_file, allocator)) |token| : (allocator.free(token)) {
        if (!failed) {
            if (token.len == 1) {
                const char_token: ReservedTokens = @enumFromInt(token[0]);
                switch (char_token) {
                    .increment => try number.addScalar(&number, 1),
                    .decrement => {
                        if (number.eqlZero()) {
                            failed = true;
                        } else {
                            try number.addScalar(&number, -1);
                        }
                    },
                    .start_group => {
                        try number_stack.append(try number.clone());
                        depth += 1;
                    },
                    .end_group => {
                        depth -= 1;
                        dropNumber(&number_stack);
                        if (depth == call_stack.getLast().depth_at_call) {
                            current_file = try returnFromFunction(&call_stack, allocator) orelse {
                                allocator.free(token);
                                return try number.clone();
                            };
                        }
                    },
                    .alternate => {
                        // we are in success state, so skip alternation
                        try skipUntilEndOfGroup(current_file);
                        // we want to access the end_group token next
                        try current_file.seekBy(-1);
                    },
                    .comment => unreachable, // readToken() cannot return a comment
                    .input => {}, // input is purposefully left unimplemented in this interpreter
                    .output => if (debug_mode) {
                        const stdout = std.io.getStdOut().writer();
                        const number_string = try number.toString(allocator, 10, .lower);
                        defer allocator.free(number_string);

                        try stdout.print("{s}\n", .{number_string});
                    },
                    .stack_trace => if (debug_mode) {
                        const stdout = std.io.getStdOut().writer();
                        try stdout.writeAll("call stack:\n");

                        var call_iterator = std.mem.reverseIterator(call_stack.items);
                        while (call_iterator.next()) |call_entry| {
                            try stdout.print("    {s}\n", .{call_entry.function_name});
                        }
                    },
                    else => {
                        current_file = try callFunction(
                            token,
                            &call_stack,
                            function_map,
                            .{
                                .file = current_file,
                                .address = try current_file.getPos(),
                            },
                            depth,
                            allocator,
                        );
                    },
                }
            } else {
                current_file = try callFunction(
                    token,
                    &call_stack,
                    function_map,
                    .{
                        .file = current_file,
                        .address = try current_file.getPos(),
                    },
                    depth,
                    allocator,
                );
            }
        } else if (std.mem.eql(
            u8,
            token,
            &.{@intFromEnum(ReservedTokens.alternate)},
        )) {
            number.deinit();
            number = try number_stack.getLast().clone(); // there is always at least 1 function on call stack
            failed = false;
        } else if (std.mem.eql(
            u8,
            token,
            &.{@intFromEnum(ReservedTokens.start_group)}, // skip groups when failed
        )) {
            // this will be an anonymous group, because functions cannot be called when failed
            try skipUntilEndOfGroup(current_file);
        } else if (std.mem.eql(
            u8,
            token,
            &.{@intFromEnum(ReservedTokens.end_group)}, // skip groups when failed
        )) {
            depth -= 1;
            dropNumber(&number_stack);

            if (depth == call_stack.getLast().depth_at_call) {
                current_file = try returnFromFunction(&call_stack, allocator) orelse {
                    allocator.free(token);
                    return null;
                };
            }
        }
    }

    return try number.clone();
}

fn readToken(
    file: std.fs.File,
    allocator: std.mem.Allocator,
) FileError!?[]const u8 {
    const reader = file.reader();
    var byte_list: std.ArrayList(u8) = try .initCapacity(allocator, 16);
    errdefer byte_list.deinit();

    while (reader.readByte() catch null) |byte| {
        if (byte == @intFromEnum(ReservedTokens.comment)) {
            try reader.skipUntilDelimiterOrEof('\n');

            if (byte_list.items.len > 0) break;
        } else if (std.ascii.isWhitespace(byte)) {
            if (byte_list.items.len > 0) break;
        } else {
            if (byte_list.items.len == byte_list.capacity)
                try byte_list.ensureUnusedCapacity(16);
            byte_list.appendAssumeCapacity(byte);
        }
    }

    if (byte_list.items.len == 0) {
        byte_list.deinit();
        return null;
    }
    return try byte_list.toOwnedSlice();
}

/// asserts at least 1 number is on the stack
fn dropNumber(
    number_stack: *std.ArrayList(std.math.big.int.Managed),
) void {
    var number = number_stack.pop();
    number.deinit();
}

/// Returns executing file
fn callFunction(
    function_name: []const u8,
    call_stack: *std.ArrayList(CallData),
    function_map: std.StringHashMap(FileAddress),
    return_address: ?FileAddress,
    depth_at_call: u64,
    allocator: std.mem.Allocator,
) ExecutionError!std.fs.File {
    const function_address = function_map.get(function_name) orelse
        return error.UndefinedFunctionCall;

    var new_file = function_address.file;
    try new_file.seekTo(function_address.address);

    const duped_function_name = try allocator.dupe(u8, function_name);
    errdefer allocator.free(duped_function_name);

    try call_stack.append(.{
        .depth_at_call = depth_at_call,
        .return_address = return_address,
        .function_name = duped_function_name,
    });

    return new_file;
}

/// return null if return from entry point
fn returnFromFunction(
    call_stack: *std.ArrayList(CallData),
    allocator: std.mem.Allocator,
) ExecutionError!?std.fs.File {
    const call_data = call_stack.pop();

    allocator.free(call_data.function_name);

    const return_address = call_data.return_address orelse
        return null;

    var new_file = return_address.file;
    try new_file.seekTo(return_address.address);

    return new_file;
}

fn scanFunctions(
    input_files: []const std.fs.File,
    allocator: std.mem.Allocator,
) ScanError!std.StringHashMap(FileAddress) {
    var function_map: std.StringHashMap(FileAddress) = .init(allocator);
    errdefer freeFunctionMap(&function_map, allocator);

    for (input_files, 0..) |file, fileno| {
        var in_definition = false;

        while (try readToken(file, allocator)) |token| : (allocator.free(token)) {
            // TODO: better error handling
            errdefer {
                const stderr = std.io.getStdErr().writer();

                stderr.print(
                    "error at index {d} in file {d} on token {s}\n",
                    .{
                        file.getPos() catch std.debug.panic("could not get file position during error\n", .{}),
                        fileno,
                        token,
                    },
                ) catch {};
            }
            if (token.len == 1) {
                const char_token: ReservedTokens = @enumFromInt(token[0]);
                switch (char_token) {
                    .increment,
                    .stack_trace,
                    .input,
                    .output,
                    .decrement,
                    .alternate,
                    => return ScanError.InvalidTopLevelToken,
                    .start_group => {
                        if (!in_definition)
                            return ScanError.UnnamedTopLevelGroup;

                        try skipUntilEndOfGroup(file);
                        in_definition = false;
                    },
                    .end_group => return ScanError.UnopenedGroup,
                    .comment => unreachable,
                    _ => {
                        try putInFunctionMap(
                            token,
                            &function_map,
                            .{ .file = file, .address = try file.getPos() },
                            &in_definition,
                            allocator,
                        );
                    },
                }
            } else {
                try putInFunctionMap(
                    token,
                    &function_map,
                    .{ .file = file, .address = try file.getPos() },
                    &in_definition,
                    allocator,
                );
            }
        }

        if (in_definition) {
            return ScanError.FunctionWithoutGroup;
        }
    }

    return function_map;
}

fn freeFunctionMap(
    function_map: *std.StringHashMap(FileAddress),
    allocator: std.mem.Allocator,
) void {
    var key_iterator = function_map.keyIterator();

    while (key_iterator.next()) |key| {
        allocator.free(key.*);
    }

    function_map.deinit();
}

fn putInFunctionMap(
    name: []const u8,
    function_map: *std.StringHashMap(FileAddress),
    file_position: FileAddress,
    in_definition: *bool,
    allocator: std.mem.Allocator,
) ScanError!void {
    if (in_definition.*)
        return ScanError.FunctionWithoutGroup;

    const duped_name = try allocator.dupe(u8, name);
    errdefer allocator.free(duped_name);

    if (function_map.get(name) == null) {
        try function_map.put(
            duped_name,
            file_position,
        );
    } else {
        return ScanError.DuplicateFunctionName;
    }

    in_definition.* = true;
}

/// Assumes group has started
fn skipUntilEndOfGroup(file: std.fs.File) (FileError || ScanError)!void {
    const reader = file.reader();
    var depth: u64 = 0;

    while (reader.readByte() catch null) |byte| {
        const char_token: ReservedTokens = @enumFromInt(byte);

        switch (char_token) {
            .start_group => depth += 1,
            .end_group => {
                if (depth == 0) break;
                depth -= 1;
            },
            .comment => try reader.skipUntilDelimiterOrEof('\n'),
            else => {},
        }
    } else {
        return error.UnclosedGroup;
    }
}

fn printHelp(arg0: []const u8) !void {
    const help_message =
        \\usage: {s} <files...> [--entry <function_name>] [--number <inital number] [--debug]
        \\
    ;

    try std.io.getStdErr().writer().print(help_message, .{arg0});
}
