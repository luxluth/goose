const std = @import("std");
const net = std.net;
pub const core = @import("core.zig");
const Value = @import("value.zig").Value;
const rand = std.crypto.random;

pub const Connection = struct {
    __inner_sock: net.Stream,

    pub fn new() !Connection {
        const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvVarNotFound;

        const socket_path = try extractUnixSocketPath(bus_address);
        const socket = try net.connectUnixSocket(socket_path);
        std.log.debug(":: Connected to D-Bus at: {s}", .{socket_path});

        return Connection{
            .__inner_sock = socket,
        };
    }

    pub fn close(self: *Connection) void {
        self.__inner_sock.close();
    }

    const requestNameArgs = std.meta.Tuple(&[_]type{ [:0]const u8, u32 });
    const RequestNameFlags = enum(u32) {
        None = 0,
        AllowReplacement = 1,
        ReplaceExisting = 2,
        DoNotQueue = 4,
    };

    pub fn requestName(_: *Connection, name: [:0]const u8) !void {
        const allocator = std.heap.page_allocator;
        const serial = rand.int(u32);
        const header = core.MessageHeader{
            .message_type = @intFromEnum(core.MessageType.MethodCall),
            .flags = @intFromEnum(core.MessageFlag.NoAutoStart),
            .proto_version = 1,
            .body_length = 0,
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{}),
        };

        const inner = Value.Tuple(requestNameArgs).new(requestNameArgs{ name, @intFromEnum(RequestNameFlags.DoNotQueue) }).inner;
        std.debug.print("{any}", .{inner});
        const body = std.mem.toBytes(inner);

        const message = core.Message.new(header, &body);
        const bytes = try message.pack(allocator);
        defer bytes.deinit();

        std.debug.print("{any}\n", .{message});
        std.debug.print("{any}\n", .{bytes.items});
    }

    fn sendBytesAndWaitForAnswer(self: *Connection, data: []u8, _: u32) !void {
        self.__inner_sock.writeAll(data);
    }
};

fn extractUnixSocketPath(address: []const u8) ![]const u8 {
    const prefix = "unix:path=";
    if (!std.mem.startsWith(u8, address, prefix)) {
        return error.InvalidAddressFormat;
    }
    return address[prefix.len..];
}
