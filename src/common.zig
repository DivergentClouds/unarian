const std = @import("std");

pub const FileError = std.fs.File.ReadError ||
    std.fs.File.SeekError ||
    std.mem.Allocator.Error;

pub const FileAddress = struct {
    file: std.fs.File,
    address: u64,
};
