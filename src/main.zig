const std = @import("std");
// const net = std.net;
// const core = @import("./root.zig").core;
// const Value = @import("./value.zig").Value;

const goose = @import("root.zig");
const Connection = goose.Connection;

pub fn main() !void {
    var conn = try Connection.new();
    defer conn.close();

    try conn.requestName("dev.goose.zig");
}
