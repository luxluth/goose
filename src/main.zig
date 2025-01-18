const std = @import("std");
// const net = std.net;
const core = @import("./root.zig").core;
const Value = @import("./value.zig").Value;

pub fn main() !void {
    const a = try std.crypto.ff.Uint(4).fromBytes(@constCast(&[_]u8{ 4, 3, 45 }), .big);
    const kk = Value.Struct(core.MessageHeader).new(.{
        .message_type = @intFromEnum(core.MessageType.MethodCall),
        .flags = @intFromEnum(core.MessageFlag.NoAutoStart),
        .proto_version = 1,
        .body_length = 0,
        .serial = try a.toPrimitive(u32),
        .header_fields = @constCast(&[_]core.HeaderField{}),
    });

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pack = try kk.inner.pack(allocator);

    std.debug.print("{any}\n", .{pack});
}

// pub fn main() !void {
//     const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
//         return error.EnvVarNotFound;
//
//     const socket_path = try extractUnixSocketPath(bus_address);
//     std.log.debug(":: Connecting to D-Bus at: {s}", .{socket_path});
//
//     var socket = try std.net.connectUnixSocket(socket_path);
//     defer socket.close();
//
//     std.log.debug(":: Connected to D-Bus", .{});
//
//     const message = "Hello, D-Bus!";
//     try socket.writer().writeAll(message);
//
//     // Receive response
//     var buffer: [1024]u8 = undefined;
//     const read_count = try socket.reader().read(&buffer);
//     const response = buffer[0..read_count];
//     std.log.info("Received: {s}", .{response});
// }
//
// fn extractUnixSocketPath(address: []const u8) ![]const u8 {
//     const prefix = "unix:path=";
//     if (!std.mem.startsWith(u8, address, prefix)) {
//         return error.InvalidAddressFormat;
//     }
//     return address[prefix.len..];
// }
