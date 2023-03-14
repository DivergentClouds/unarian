const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var register = try std.math.big.int.Managed.init(allocator);
    defer register.deinit();

    if (args.len == 0 or args.len > 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Wrong number of arguments\nUsage: {s} <program> [starting number]\n", .{args[0]});
        return error.BadArgs;
    } else if (args.len == 3) { // program, number
        try register.setString(10, args[2]);
    } // else: program, register is inited to 0

    var program_file = try std.fs.cwd().openFile(args[1], .{});
    defer program_file.close();

    const program = try program_file.readToEndAlloc(allocator, (try program_file.metadata()).size());
    defer allocator.free(program);

    try interpret(&program, &register, allocator);
}

fn interpret(program: *[]u8, register: *std.math.big.int.Managed, allocator: std.mem.Allocator) !void {
    var depth: usize = 0;

    _ = allocator;
    _ = register;

    stripComments(program);
    var tokens = &std.mem.tokenize(u8, program.*, std.ascii.whitespace);

    while (tokens.next()) |token| {
        if (depth == 0) {
            if (std.mem.eql(u8, token, "{")) {
                return error.UnnamedTopLevelFunction;
            }
            if (std.mem.eql(u8, token, "}")) {
                return error.UnopenedFunction;
            }
            if (std.mem.eql(u8, token, "|")) {
                return error.UnscopedAlternation;
            }
            if (std.mem.eql(u8, token, "+")) {
                return error.UnscopedIncrement;
            }
            if (std.mem.eql(u8, token, "-")) {
                return error.UnscopedDecrement;
            }
        }
    }
}

fn stripComments(program: *[]u8) void {
    var in_comment = false;

    for (program) |*byte| {
        if (byte.* == '#') {
            in_comment = true;
        }

        if (in_comment and byte.* != '\n') {
            byte.* = ' ';
        } else if (byte.* == '\n') {
            in_comment = false;
        }
    }
}

fn decrement(register: *std.math.big.int.Managed) std.mem.Allocator.Error!?void {
    if (register.*.eqZero) {
        return null;
    }

    try register.addScalar(register, -1);
}

fn increment(register: *std.math.big.int.Managed) std.mem.Allocator.Error!void {
    try register.addScalar(register, 1);
}
