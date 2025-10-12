const std = @import("std");

const goose = @import("goose");
const core = @import("goose").core;
const Value = core.value.Value;
const DBusWriter = core.value.DBusWriter;
const Connection = goose.Connection;

pub fn main() !void {
    // const V = Value.Variant(core.HeaderFieldValue);
    // std.debug.print("{any}\n", .{V});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    // defer buffer.deinit(allocator);
    //
    // var writer = DBusWriter.init(&buffer, allocator, .big, 0);
    //
    // try Value.Int32().new(69).ser(&writer);
    // std.debug.print("{any}\n", .{writer});

    //
    // try Value.String().new("Hello world").ser(&arr);
    // try Value.Double().new(13.45).ser(&arr);
    // std.debug.print("{any}\n", .{arr.items});
    // try Value.Bool().new(false).ser(&arr);
    // std.debug.print("{any}\n", .{arr.items});

    var conn = try Connection.init(allocator);
    defer conn.close();

    try conn.requestName("dev.goose.zig");
}
