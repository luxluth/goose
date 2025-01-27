const std = @import("std");
const net = std.net;
pub const core = @import("core.zig");
const Value = @import("value.zig").Value;
const rand = std.crypto.random;
const convertInteger = @import("utils.zig").convertInteger;

pub const Connection = struct {
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Connection {
        const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvVarNotFound;

        const socket_path = try extractUnixSocketPath(bus_address);
        const socket = try net.connectUnixSocket(socket_path);
        std.log.debug(":: Connected to D-Bus at: {s}", .{socket_path});

        return Connection{
            .__inner_sock = socket,
            .__allocator = allocator,
        };
    }

    /// This function closes the underlined socket
    pub fn close(self: *Connection) void {
        self.__inner_sock.close();
    }

    const RequestNameFlags = enum(u32) {
        None = 0,
        AllowReplacement = 1,
        ReplaceExisting = 2,
        DoNotQueue = 4,
    };

    pub fn requestName(self: *Connection, name: [:0]const u8) !void {
        const serial = rand.int(u32);

        var body_arr = std.ArrayList(u8).init(self.__allocator);
        defer body_arr.deinit();

        try body_arr.appendSlice(name);
        const flag = convertInteger(u32, @intFromEnum(RequestNameFlags.DoNotQueue), .big);
        try body_arr.appendSlice(&flag);

        const header = core.MessageHeader{
            .message_type = @intFromEnum(core.MessageType.MethodCall),
            .flags = @intFromEnum(core.MessageFlag.NoAutoStart),
            .proto_version = 1,
            .body_length = @intCast(body_arr.items.len),
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = @intFromEnum(core.HeaderFieldCode.ReplySerial), .value = .{ .ReplySerial = serial } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Member), .value = .{ .Member = "RequestName" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Signature), .value = .{ .Signature = "su" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Destination), .value = .{ .Signature = "org.freedesktop.DBus" } },
            }),
        };

        const message = core.Message.new(header, body_arr.items);
        const bytes = try message.pack(self.__allocator);
        defer bytes.deinit();
        try self.sendBytesAndWaitForAnswer(bytes.items, serial);
    }

    fn sendBytesAndWaitForAnswer(self: *Connection, data: []u8, serial: u32) !void {
        try self.__inner_sock.writeAll(data);
        std.debug.print("[:{d}:SEND] -> {d} o\n", .{ serial, data.len });
        const reader = self.__inner_sock.reader();
        const endian = try reader.readAllAlloc(self.__allocator, 512);
        std.debug.print("{c}", .{endian[0]});
    }
};

fn extractUnixSocketPath(address: []const u8) ![]const u8 {
    const prefix = "unix:path=";
    if (!std.mem.startsWith(u8, address, prefix)) {
        return error.InvalidAddressFormat;
    }
    return address[prefix.len..];
}
