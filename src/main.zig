const std = @import("std");
const net = std.net;

pub fn main() !void {
    const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
        return error.EnvVarNotFound;

    const socket_path = try extractUnixSocketPath(bus_address);
    std.log.debug(":: Connecting to D-Bus at: {s}", .{socket_path});

    var socket = try std.net.connectUnixSocket(socket_path);
    defer socket.close();

    std.log.debug(":: Connected to D-Bus", .{});

    const message = "Hello, D-Bus!";
    try socket.writer().writeAll(message);

    // Receive response
    var buffer: [1024]u8 = undefined;
    const read_count = try socket.reader().read(&buffer);
    const response = buffer[0..read_count];
    std.log.info("Received: {s}", .{response});
}

fn extractUnixSocketPath(address: []const u8) ![]const u8 {
    const prefix = "unix:path=";
    if (!std.mem.startsWith(u8, address, prefix)) {
        return error.InvalidAddressFormat;
    }
    return address[prefix.len..];
}
