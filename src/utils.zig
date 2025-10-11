const std = @import("std");

pub inline fn convertInteger(comptime T: type, x: T, endianess: std.builtin.Endian) [@sizeOf(@TypeOf(x))]u8 {
    comptime switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("convertInteger expects an integer type"),
    };
    return std.mem.toBytes(std.mem.nativeTo(T, x, endianess));
}
