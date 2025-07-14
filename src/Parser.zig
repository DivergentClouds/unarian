const std = @import("std");
const Scanner = @import("Scanner.zig");
const common = @import("common.zig");

const Parser = @This();

functions: Functions,
called_list: FunctionCallLocations,
token_iterator: common.ScalarIterator(Scanner.Token),
arena: std.heap.ArenaAllocator,

const Functions = std.StringArrayHashMapUnmanaged(Node);

pub fn format(
    parser: Parser,
    _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    var iterator = parser.functions.iterator();
    while (iterator.next()) |entry| {
        try writer.print("{s}:\n", .{entry.key_ptr.*});

        const group: []const Node = switch (entry.value_ptr.data) {
            .group => |group| group,
            else => return error.Unexpected,
        };

        try printGroup(group, 1, writer);
    }
}

fn printGroup(
    group: []const Node,
    depth: usize,
    writer: anytype,
) !void {
    for (group) |node| {
        if (std.meta.activeTag(node.data) != .group) {
            try writer.writeByteNTimes(' ', depth * 2);
        }
        switch (node.data) {
            .group => |inner_group| try printGroup(inner_group, depth + 1, writer),
            .call => |identifier| try writer.print("{s}\n", .{identifier}),
            else => try writer.print("{c}\n", .{try node.data.toChar()}),
        }
    }
}

const FunctionCallLocations = std.StringArrayHashMapUnmanaged(
    std.ArrayListUnmanaged(Scanner.Location),
);

pub const Node = struct {
    data: Data,
    location: Scanner.Location,
};

pub const Kind = enum {
    call,

    group,

    increment,
    decrement,
    alternate,

    input,
    output,
    stack_trace,
};

pub const Data = union(Kind) {
    call: []const u8,

    group: []const Node,

    increment,
    decrement,
    alternate,

    input,
    output,
    stack_trace,

    fn toChar(data: Data) !u8 {
        return switch (data) {
            .call => error.CannotConvertCallToChar,
            .group => error.CannotCovertGroupToChar,
            .increment => '+',
            .decrement => '-',
            .alternate => '|',

            .input => '?',
            .output => '!',
            .stack_trace => '@',
        };
    }
};

const ParseError = error{
    InvalidTopLevelToken,
    UnnamedTopLevelGroup,
    FunctionWithoutGroup,
    DuplicateFunctionDefinition,
    UndefinedFunctionCall,
};

const ParseErrorWithPayload = struct {
    payload: struct {
        location: Scanner.Location,
        lexeme: ?[]const u8 = null,
    },
    err: ParseError,

    pub fn format(
        value: ParseErrorWithPayload,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print(
            \\Error in file {d} at {d}:{d}
            \\
        , .{
            value.payload.location.file_number,
            value.payload.location.line,
            value.payload.location.column,
        });

        try writer.print(
            \\{s}
        , .{switch (value.err) {
            ParseError.InvalidTopLevelToken => "Invalid top level token",
            ParseError.UnnamedTopLevelGroup => "Unnamed top level group",
            ParseError.FunctionWithoutGroup => "Function definition missing group",
            ParseError.DuplicateFunctionDefinition => "Duplicate function definition",
            ParseError.UndefinedFunctionCall => "Attempt to call undefined function",
        }});

        if (value.payload.lexeme) |lexeme| {
            try writer.print(
                \\: {s}
            , .{lexeme});
        }
    }
};

pub const FunctionsOrErrors = union(enum) {
    functions: Functions,
    errors: []const ParseErrorWithPayload,
};

pub fn init(
    allocator: std.mem.Allocator,
    tokens: []const Scanner.Token,
) Parser {
    return .{
        .functions = .empty,
        .called_list = .empty,
        .token_iterator = .init(tokens),
        .arena = .init(allocator),
    };
}

pub fn deinit(parser: Parser) void {
    parser.arena.deinit();
}

pub fn parse(
    parser: *Parser,
) std.mem.Allocator.Error!FunctionsOrErrors {
    var errors: std.ArrayListUnmanaged(ParseErrorWithPayload) = try .initCapacity(
        parser.arena.allocator(),
        16,
    );

    var success = true;

    while (parser.token_iterator.next()) |token| {
        switch (token.kind) {
            .identifier => {
                if (parser.functions.get(token.lexeme) != null) {
                    try errors.append(parser.arena.allocator(), .{
                        .payload = .{
                            .location = token.location,
                            .lexeme = token.lexeme,
                        },
                        .err = ParseError.DuplicateFunctionDefinition,
                    });
                    success = false;
                }

                // parseGroup expects to start after .open_group
                const optional_next_token = parser.token_iterator.peek();

                if (optional_next_token == null or optional_next_token.?.kind != .open_group) {
                    try errors.append(parser.arena.allocator(), .{
                        .payload = .{
                            .location = token.location,
                            .lexeme = token.lexeme,
                        },
                        .err = ParseError.FunctionWithoutGroup,
                    });

                    success = false;
                } else {
                    _ = parser.token_iterator.skip();

                    const group = try parser.parseGroup();

                    try parser.functions.putNoClobber(
                        parser.arena.allocator(),
                        token.lexeme,
                        group,
                    );
                }
            },
            .open_group => {
                try errors.append(parser.arena.allocator(), .{
                    .payload = .{ .location = token.location, .lexeme = token.lexeme },
                    .err = ParseError.UnnamedTopLevelGroup,
                });

                success = false;

                // so that the contents of the group are not treated as top-level
                _ = try parser.parseGroup();
            },
            else => {
                try errors.append(parser.arena.allocator(), .{
                    .payload = .{
                        .location = token.location,
                        .lexeme = token.lexeme,
                    },
                    .err = ParseError.InvalidTopLevelToken,
                });

                success = false;
            },
        }
    }
    const missing_funcs = try parser.missingDefinitions();
    var missing_iterator = missing_funcs.iterator();

    while (missing_iterator.next()) |missing_func| {
        // we want multiple locations in case the programmer made several of the same typo of the name of a defined function
        for (missing_func.value_ptr.items) |location| {
            try errors.append(
                parser.arena.allocator(),
                .{
                    .payload = .{
                        .lexeme = missing_func.key_ptr.*,
                        .location = location,
                    },
                    .err = ParseError.UndefinedFunctionCall,
                },
            );
        }

        success = false;
    }

    if (success)
        return .{ .functions = parser.functions }
    else
        return .{ .errors = errors.items };
}

// asserts previous token was start of group
fn parseGroup(parser: *Parser) std.mem.Allocator.Error!Node {
    var nodes: std.ArrayListUnmanaged(Node) = try .initCapacity(
        parser.arena.allocator(),
        64,
    );

    while (parser.token_iterator.next()) |token| {
        if (nodes.items.len >= nodes.capacity - 1) {
            try nodes.ensureUnusedCapacity(parser.arena.allocator(), 64);
        }

        switch (token.kind) {
            .open_group => {
                const inner = try parser.parseGroup();

                try nodes.append(parser.arena.allocator(), inner);
            },
            .close_group => {
                const result = nodes.items;

                return .{
                    .data = .{ .group = result },
                    .location = token.location,
                };
            },
            .identifier => {
                if (parser.called_list.get(token.lexeme) == null) {
                    try parser.called_list.put(parser.arena.allocator(), token.lexeme, .empty);
                }

                // we know the entry is non-null because it was just assigned
                var called_list_entry = parser.called_list.get(token.lexeme).?;
                try called_list_entry.append(
                    parser.arena.allocator(),
                    token.location,
                );

                try nodes.append(parser.arena.allocator(), .{
                    .data = .{ .call = token.lexeme },
                    .location = token.location,
                });
            },
            .increment => nodes.appendAssumeCapacity(.{
                .data = .increment,
                .location = token.location,
            }),
            .decrement => nodes.appendAssumeCapacity(.{
                .data = .decrement,
                .location = token.location,
            }),
            .alternate => nodes.appendAssumeCapacity(.{
                .data = .alternate,
                .location = token.location,
            }),
            .input => nodes.appendAssumeCapacity(.{
                .data = .input,
                .location = token.location,
            }),
            .output => nodes.appendAssumeCapacity(.{
                .data = .output,
                .location = token.location,
            }),
            .stack_trace => nodes.appendAssumeCapacity(.{
                .data = .stack_trace,
                .location = token.location,
            }),
        }
    }

    // the scanner makes sure all brackets match, and we return on a closing bracket
    unreachable;
}

fn missingDefinitions(parser: *Parser) std.mem.Allocator.Error!FunctionCallLocations {
    var missing: FunctionCallLocations = .empty;

    var called_iterator = parser.called_list.iterator();
    while (called_iterator.next()) |func| {
        if (parser.functions.get(func.key_ptr.*) == null) {
            try missing.put(
                parser.arena.allocator(),
                func.key_ptr.*,
                func.value_ptr.*,
            );
        }
    }

    return missing;
}
