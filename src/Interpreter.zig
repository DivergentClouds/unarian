const std = @import("std");
const Parser = @import("Parser.zig");
const common = @import("common.zig");

const Interpreter = @This();

input_stack: std.ArrayListUnmanaged(std.math.big.int.Mutable), // toConst does not transfer all limbs
/// each group entered gets its own item
call_stack: std.ArrayListUnmanaged(StackEntry), // for stack trace builtin
register: ?std.math.big.int.Managed,
functions: Parser.Functions,
allocator: std.mem.Allocator,

const GroupIdentifier = union(enum) {
    function_name: []const u8,
    anon_index: u64,
};

const StackEntry = struct {
    group_identifier: GroupIdentifier,
    initial_value: std.math.big.int.Const,

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
    initial_value: std.math.big.int.Const,
    functions: Parser.Functions,
    allocator: std.mem.Allocator,
) !Interpreter {
    return .{
        .input_stack = try .initCapacity(allocator, capacity),
        .call_stack = try .initCapacity(allocator, capacity),
        .register = try initial_value.toManaged(allocator),
        .functions = functions,
        .allocator = allocator,
    };
}

pub fn deinit(interpreter: *Interpreter) void {
    for (interpreter.call_stack.items) |item| {
        interpreter.allocator.free(item.initial_value.limbs);
    }
    interpreter.call_stack.deinit(interpreter.allocator);

    for (interpreter.input_stack.items) |input_item| {
        interpreter.allocator.free(input_item.limbs);
    }

    interpreter.input_stack.deinit(interpreter.allocator);

    if (interpreter.register) |*register| {
        register.deinit();
    }
}

pub fn interpret(
    interpreter: *Interpreter,
    entry_point: []const u8,
) !void {
    const entry = interpreter.functions.get(entry_point) orelse
        return error.MissingEntryPoint;

    var has_printed = false;
    try interpreter.interpretGroup(
        entry.data.group,
        0,
        &has_printed,
        .{ .function_name = entry_point },
    );

    try interpreter.output();
}

fn interpretGroup(
    interpreter: *Interpreter,
    group: []const Parser.Node,
    path_input_count: usize,
    has_printed: *bool,
    group_identifier: GroupIdentifier,
) !void {
    // cannot enter group when in failed state
    try common.appendEnsureUnusedCapacity(
        StackEntry,
        &interpreter.call_stack,
        .{
            .group_identifier = group_identifier,
            .initial_value = (try interpreter.register.?.clone()).toConst(),
        },
        capacity,
        interpreter.allocator,
    );
    defer interpreter.allocator.free(interpreter.call_stack.pop().?.initial_value.limbs);

    var input_count = path_input_count;
    var group_index: u64 = 0;

    for (group) |node| {
        if (interpreter.register != null) {
            switch (node.data) {
                // we have already verified that all referenced functions exist when parsing
                .call => |name| {
                    var inner_printed = false;

                    try interpreter.interpretGroup(
                        interpreter.functions.get(name).?.data.group,
                        input_count,
                        &inner_printed,
                        .{ .function_name = name },
                    );

                    has_printed.* = has_printed.* or inner_printed;
                },
                .group => |inner_group| {
                    const identifier: GroupIdentifier = .{ .anon_index = group_index };
                    group_index += 1;

                    var inner_printed = false;

                    try interpreter.interpretGroup(
                        inner_group,
                        input_count,
                        &inner_printed,
                        identifier,
                    );

                    has_printed.* = has_printed.* or inner_printed;
                },
                .increment => try interpreter.register.?.addScalar(&interpreter.register.?, 1),
                .decrement => if (interpreter.register.?.eqlZero()) {
                    interpreter.register.?.deinit();
                    interpreter.register = null;
                } else {
                    try interpreter.register.?.addScalar(&interpreter.register.?, -1);
                },
                .alternate => break, // skip the remainder of the group
                .input => {
                    input_count += 1;
                    try interpreter.input(input_count);
                },
                .output => {
                    try interpreter.output();
                    has_printed.* = true;
                },
                .stack_trace => {
                    try interpreter.stackTrace();
                },
            }

            if (has_printed.* and interpreter.register == null) {
                return error.FailureInPrintedPath;
            }
        } else {
            switch (node.data) {
                .alternate => {
                    interpreter.register = try .init(interpreter.allocator);
                    try interpreter.register.?.copy(interpreter.call_stack.getLast().initial_value);

                    input_count = path_input_count;
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

        var input_number: std.math.big.int.Managed = try .init(interpreter.allocator);
        errdefer input_number.deinit();
        try input_number.setString(10, line_list.items);

        try interpreter.input_stack.append(interpreter.allocator, input_number.toMutable());
    }

    try interpreter.register.?.copy(interpreter.input_stack.items[input_count - 1].toConst());
}

pub fn output(interpreter: Interpreter) !void {
    const stdout = std.io.getStdOut().writer();

    if (interpreter.register) |register| {
        try stdout.print("{}\n", .{register});
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
