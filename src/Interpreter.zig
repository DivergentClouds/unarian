const std = @import("std");
const Parser = @import("Parser.zig");
const common = @import("common.zig");

const Interpreter = @This();

input_stack: std.ArrayListUnmanaged(u64), // toConst does not transfer all limbs
/// each group entered gets its own item
call_stack: std.ArrayListUnmanaged(StackEntry),
register: ?u64,
functions: Parser.Functions,
allocator: std.mem.Allocator,

const GroupIdentifier = union(enum) {
    function_name: []const u8,
    anon_index: u64,
};

const StackEntry = struct {
    group_identifier: GroupIdentifier,

    /// used when alternating upon failure
    initial_value: u64,
    return_group: ?[]const Parser.Node,
    return_index: usize,

    path_has_printed: bool,
    path_input_count: usize,
    /// number of anon groups called from this group, used for constructing GroupIdentifier
    anon_count: usize,

    pub fn format(
        entry: StackEntry,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("entered ", .{});

        switch (entry.group_identifier) {
            .function_name => |name| {
                try writer.print("function {s} ", .{name});
            },
            .anon_index => |index| {
                try writer.print("anonymous group {d} ", .{index});
            },
        }

        try writer.print("with value {}", .{entry.initial_value});
    }
};

const capacity: usize = 64;

pub fn init(
    initial_value: u64,
    functions: Parser.Functions,
    allocator: std.mem.Allocator,
) !Interpreter {
    return .{
        .input_stack = try .initCapacity(allocator, capacity),
        .call_stack = try .initCapacity(allocator, capacity),
        .register = initial_value,
        .functions = functions,
        .allocator = allocator,
    };
}

pub fn deinit(interpreter: *Interpreter) void {
    interpreter.call_stack.deinit(interpreter.allocator);
    interpreter.input_stack.deinit(interpreter.allocator);
}

pub fn interpret(
    interpreter: *Interpreter,
    entry_point: []const u8,
) !void {
    const entry = interpreter.functions.get(entry_point) orelse
        return error.MissingEntryPoint;

    try common.appendEnsureUnusedCapacity(
        StackEntry,
        &interpreter.call_stack,
        .{
            .group_identifier = .{ .function_name = entry_point },
            .initial_value = interpreter.register.?,
            .return_group = null,
            .return_index = undefined, // only meaningful when return_group is non-null
            .path_has_printed = false,
            .path_input_count = 0,
            .anon_count = 0,
        },
        capacity,
        interpreter.allocator,
    );

    try interpreter.interpretInner(entry.data.group);
    try interpreter.output();
}

fn interpretInner(
    interpreter: *Interpreter,
    entry_group: []const Parser.Node,
) !void {
    var current_group = entry_group;
    var current_index: usize = 0;

    var has_printed = false;
    var input_count: u64 = 0;

    var anon_count: usize = 0;

    while (current_index < current_group.len) {
        const node = current_group[current_index];
        current_index += 1;

        if (interpreter.register != null) {
            switch (node.data) {
                .call => |name| {
                    try common.appendEnsureUnusedCapacity(
                        StackEntry,
                        &interpreter.call_stack,
                        .{
                            .group_identifier = .{ .function_name = name },
                            .initial_value = interpreter.register.?,
                            .return_group = current_group,
                            .return_index = current_index,
                            .anon_count = anon_count,
                            .path_has_printed = has_printed,
                            .path_input_count = input_count,
                        },
                        capacity,
                        interpreter.allocator,
                    );

                    // we have already verified that all referenced functions exist when parsing
                    current_group = interpreter.functions.get(name).?.data.group;
                    current_index = 0;
                    anon_count = 0;
                    has_printed = false;
                },
                .group => |inner_group| {
                    try common.appendEnsureUnusedCapacity(
                        StackEntry,
                        &interpreter.call_stack,
                        .{
                            .group_identifier = .{ .anon_index = anon_count },
                            .initial_value = interpreter.register.?,
                            .return_group = current_group,
                            .return_index = current_index,
                            .anon_count = anon_count + 1,
                            .path_has_printed = has_printed,
                            .path_input_count = input_count,
                        },
                        capacity,
                        interpreter.allocator,
                    );

                    current_group = inner_group;
                    current_index = 0;
                    anon_count = 0;
                },
                .increment => interpreter.register.? += 1,
                .decrement => if (interpreter.register.? == 0) {
                    interpreter.register = null;
                } else {
                    interpreter.register.? -= 1;
                },
                .alternate => {
                    // skip the rest of the group
                    current_index = current_group.len - 1;
                },
                .input => {
                    input_count += 1;
                    try interpreter.input(input_count);
                },
                .output => {
                    try interpreter.output();
                    has_printed = true;
                },
                .stack_trace => {
                    try interpreter.stackTrace();
                },
                .end_group => {
                    // exactly 1 end_group per group call
                    const return_data = interpreter.call_stack.pop().?;

                    current_group = return_data.return_group orelse
                        return;
                    current_index = return_data.return_index;

                    has_printed = return_data.path_has_printed or has_printed;
                    input_count = return_data.path_input_count;

                    anon_count = return_data.anon_count;
                },
            }

            if (has_printed and interpreter.register == null) {
                return error.FailureInPrintedPath;
            }
        } else {
            switch (node.data) {
                .alternate => {
                    const called_data = interpreter.call_stack.getLast();
                    interpreter.register = called_data.initial_value;
                    input_count = called_data.path_input_count;
                },
                .end_group => {
                    // exactly 1 end_group per group call
                    const return_data = interpreter.call_stack.pop().?;

                    current_group = return_data.return_group orelse
                        return;
                    current_index = return_data.return_index;

                    has_printed = return_data.path_has_printed or has_printed;
                    input_count = return_data.path_input_count;

                    anon_count = return_data.anon_count;
                },
                else => {},
            }
        }
    }
}

fn input(
    interpreter: *Interpreter,
    input_count: usize,
) !void {
    std.debug.assert(interpreter.register != null);
    std.debug.assert(interpreter.input_stack.items.len + 1 >= input_count);
    std.debug.assert(input_count > 0);

    if (interpreter.input_stack.items.len < input_count) {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        try stdout.writeAll("input> ");

        var line_list: std.ArrayListUnmanaged(u8) = try .initCapacity(
            interpreter.allocator,
            capacity,
        );
        defer line_list.deinit(interpreter.allocator);

        try stdin.streamUntilDelimiter(
            line_list.writer(interpreter.allocator),
            '\n',
            null,
        );

        const input_number = try std.fmt.parseInt(u64, line_list.items, 0);

        try common.appendEnsureUnusedCapacity(
            u64,
            &interpreter.input_stack,
            input_number,
            capacity,
            interpreter.allocator,
        );
    }

    interpreter.register = interpreter.input_stack.items[input_count - 1];
}

pub fn output(interpreter: Interpreter) !void {
    const stdout = std.io.getStdOut().writer();

    if (interpreter.register) |register| {
        try stdout.print("{d}\n", .{register});
    } else {
        try stdout.print("-\n", .{});
    }
}

fn stackTrace(interpreter: Interpreter) !void {
    const stderr = std.io.getStdErr().writer();
    var iterator = std.mem.reverseIterator(interpreter.call_stack.items);

    while (iterator.next()) |stack_entry| {
        try stderr.print("{}\n", .{stack_entry});
    }
    try stderr.writeByte('\n');
}
