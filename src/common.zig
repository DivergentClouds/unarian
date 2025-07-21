const std = @import("std");

pub const FileError = std.fs.File.ReadError ||
    std.fs.File.SeekError ||
    std.mem.Allocator.Error;

pub const FileAddress = struct {
    file: std.fs.File,
    address: u64,
};

pub fn ScalarIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: usize,

        const Self = @This();

        pub fn init(buffer: []const T) Self {
            return .{
                .buffer = buffer,
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?T {
            const result = self.peek() orelse return null;
            self.index += 1;
            return result;
        }

        pub fn peek(self: Self) ?T {
            if (self.index >= self.buffer.len) return null;
            return self.buffer[self.index];
        }

        pub fn skip(self: *Self) bool {
            if (self.index == self.buffer.len) return false;

            self.index += 1;
            return true;
        }

        pub fn rest(self: Self) []const T {
            return self.buffer[self.index..];
        }

        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        pub fn previous(self: *Self) ?T {
            if (self.index == 0) return null;

            self.index -= 1;
            return self.peek();
        }
    };
}

pub fn scalarIterator(comptime T: type, buffer: []const T) ScalarIterator(T) {
    return .{ .buffer = buffer, .index = 0 };
}

// inlining causes a noticable speedup
/// append to an ArrayListUnmanaged, extending capacity by a set amountf needed
/// asserts that additional_count > 0
pub inline fn appendEnsureUnusedCapacity(
    T: type,
    list: *std.ArrayListUnmanaged(T),
    item: T,
    additional_count: usize,
    allocator: std.mem.Allocator,
) !void {
    std.debug.assert(additional_count > 0);

    if (list.items.len == list.capacity) {
        try list.ensureUnusedCapacity(allocator, additional_count);
    }

    list.appendAssumeCapacity(item);
}
