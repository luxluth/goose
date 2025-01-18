const std = @import("std");

pub inline fn convertInteger(comptime T: type, x: T, endianess: std.builtin.Endian) [@sizeOf(@TypeOf(x))]u8 {
    return std.mem.toBytes(std.mem.nativeTo(T, x, endianess));
}
