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
}
