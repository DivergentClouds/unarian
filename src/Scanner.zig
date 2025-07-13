const std = @import("std");
const common = @import("common.zig");

const Scanner = @This();

list: List,
location: Location,
allocator: std.mem.Allocator,
opened_groups: usize,

pub const Location = struct {
    file_number: usize,
    line: usize,
    column: usize,
    index: usize,

    fn start(file_number: usize) Location {
        return .{
            .file_number = file_number,
            .line = 1,
            .column = 1,
            .index = 0,
        };
    }

    fn newLine(location: *Location) void {
        location.index += 1;
        location.line += 1;
        location.column = 1;
    }

    fn newChar(location: *Location) void {
        location.index += 1;
        location.column += 1;
    }
};

pub const Kind = enum {
    increment,
    decrement,
    open_group,
    close_group,
    alternate,
    input,
    output,
    stack_trace,
    identifier,
    invalid,
};

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    location: Location,

    fn deinit(token: Token, allocator: std.mem.Allocator) void {
        allocator.free(token.lexeme);
    }
};

pub const ScanError = error{
    UnopenedGroup,
    UnclosedGroup,
    EmptySource,
};

const ScanErrorWithPayload = struct {
    payload: Location,
    err: ScanError,

    pub fn format(
        value: ScanErrorWithPayload,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print(
            \\Error in file {d} at {d}:{d}
            \\{s}
        ,
            .{
                value.payload.file_number,
                value.payload.line,
                value.payload.column,
                @errorName(value.err),
            },
        );
    }
};

const TokenOrError = union(enum) {
    token: Token,
    err: ScanErrorWithPayload,
};

pub const List = union(enum) {
    tokens: std.ArrayListUnmanaged(Token),
    errors: std.ArrayListUnmanaged(ScanErrorWithPayload),

    pub fn deinit(list: *List, allocator: std.mem.Allocator) void {
        switch (list.*) {
            .tokens => {
                for (list.tokens.items) |item| {
                    item.deinit(allocator);
                }
                list.tokens.deinit(allocator);
            },
            .errors => list.errors.deinit(allocator),
        }
    }
};
pub fn init(allocator: std.mem.Allocator) Scanner {
    return .{
        .list = .{ .tokens = .empty },
        .location = .start(0),
        .allocator = allocator,
        .opened_groups = 0,
    };
}

pub fn deinit(scanner: *Scanner) void {
    scanner.list.deinit(scanner.allocator);
}

/// returns `scanner.list`
pub fn scan(
    scanner: *Scanner,
    files: []const std.fs.File,
) common.FileError!List {
    var success = true;

    for (files, 0..) |file, file_number| {
        scanner.opened_groups = 0;
        scanner.location = .start(file_number);

        const list = try scanner.scanFile(file);

        switch (list) {
            .tokens => |tokens| {
                if (success) {
                    scanner.list.tokens.appendSlice(
                        scanner.allocator,
                        tokens.items,
                    );
                } else {
                    list.deinit(scanner.allocator);
                }
            },
            .errors => |errors| {
                if (success) {
                    success = false;

                    scanner.list.deinit(scanner.allocator);
                    scanner.list = .{ .errors = .empty };
                }

                scanner.list.errors.appendSlice(
                    scanner.allocator,
                    errors.items,
                );
            },
        }
    }

    if (success and scanner.list.tokens.len == 0) {
        success = false;

        scanner.list.deinit(scanner.allocator);
        scanner.list = .{ .errors = .empty };

        scanner.list.errors.append(scanner.allocator, .{
            .payload = scanner.location,
            .err = ScanError.EmptySource,
        });
    }

    return scanner.list;
}

fn scanFile(
    scanner: *Scanner,
    file: std.fs.File,
) common.FileError!List {
    var list: List = .{
        // preallocate some memory to prevent many reallocations
        .tokens = try .initCapacity(scanner.allocator, 4096),
    };

    errdefer list.deinit(scanner.allocator);

    var success = true;

    list_builder: switch (try scanner.scanToken(file) orelse
        return list) {
        .token => |token| {
            if (success) {
                try list.tokens.append(scanner.allocator, token);
            } else {
                token.deinit(scanner.allocator);
            }

            continue :list_builder try scanner.scanToken(file) orelse
                break :list_builder;
        },
        .err => |err| {
            // this is overkill, since only one error can logically be returned
            // but if more errors are added in the future this could be helpful
            if (success) {
                success = false;

                list.deinit(scanner.allocator);
                list = .{
                    .errors = .empty,
                };
            }

            try list.errors.append(scanner.allocator, err);

            continue :list_builder try scanner.scanToken(file) orelse
                break :list_builder;
        },
    }

    if (scanner.opened_groups > 0) {
        if (success) {
            success = false;

            list.deinit(scanner.allocator);
            list = .{
                .errors = .empty,
            };
        }

        try list.errors.append(scanner.allocator, ScanError.UnclosedGroup);
    }

    return list;
}

fn scanToken(
    scanner: *Scanner,
    file: std.fs.File,
) !?TokenOrError {
    const starting_location = scanner.location;

    var lexeme_byte_list: std.ArrayListUnmanaged(u8) = .initCapacity(
        scanner.allocator,
        128,
    );
    defer lexeme_byte_list.deinit(scanner.allocator);

    const first_byte: u8 = while (try readByteOrEof(file)) |byte| byte: {
        if (std.ascii.isWhitespace(byte)) {
            if (byte == '\n') {
                scanner.location.newLine();
            }
        } else {
            scanner.location.newChar();
            break :byte byte;
        }
    } else return null;

    token_builder: switch (first_byte) {
        ' ',
        '\t',
        '\r',
        std.ascii.control_code.vt,
        std.ascii.control_code.ff,
        => scanner.location.newChar(),
        '\n' => scanner.location.newLine(),
        '#' => try {
            scanner.skipComment(file);
            break :token_builder;
        },
        else => |byte| {
            scanner.location.newChar();
            lexeme_byte_list.append(scanner.allocator, byte);
            continue :token_builder readByteOrEof(file) orelse
                break :token_builder;
        },
    }
    const lexeme = try scanner.allocator.dupe(u8, lexeme_byte_list.items);

    // in case a refactor makes the remainder of the function failable
    errdefer scanner.allocator.free(lexeme);

    var token: Token = .{
        .kind = undefined,
        .lexeme = lexeme,
        .location = starting_location,
    };

    if (lexeme.len == 1) {
        switch (lexeme_byte_list.items[0]) {
            '+' => token.kind = .increment,
            '-' => token.kind = .decrement,
            '{' => {
                token.kind = .open_group;
                scanner.opened_groups += 1;
            },
            '}' => {
                token.kind = .close_group;

                if (scanner.opened_groups == 0) {
                    scanner.allocator.free(lexeme);

                    return TokenOrError{ .err = .{
                        .payload = starting_location,
                        .err = ScanError.UnopenedGroup,
                    } };
                } else scanner.opened_groups -= 1;
            },
            '|' => token.kind = .alternate,
            '?' => token.kind = .input,
            '!' => token.kind = .output,
            '@' => token.kind = .stack_trace,
            else => token.kind = .identifier,
        }
    } else token.kind = .identifier;

    return .{ .token = token };
}

fn skipComment(scanner: *Scanner, file: std.fs.File) !void {
    skip: switch (try scanner.readByteOrEof(file) orelse return) {
        '\n' => scanner.location.newLine(),
        else => {
            scanner.location.newChar();
            continue :skip try scanner.readByteOrEof(file) orelse return;
        },
    }
}

fn readByteOrEof(file: std.fs.File) !?u8 {
    file.reader().readByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
}
