const std = @import("std");
const net = std.net;
pub const core = @import("core.zig");
const Value = @import("value.zig").Value;
const rand = std.crypto.random;
const convertInteger = @import("utils.zig").convertInteger;

pub const Connection = struct {
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    serial_counter: u32,

    fn auth(socket: net.Stream) !void {
        var reader_buffer: [2048]u8 = undefined;
        var reader = socket.reader(&reader_buffer);
        const io_reader = &reader.interface_state;

        var writer_buffer: [2048]u8 = undefined;
        var writer = socket.writer(&writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeByte(0);
        try io_writer.print("AUTH EXTERNAL 31303031\r\n", .{});
        try io_writer.flush();

        const response = try io_reader.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, response, "OK")) {
            return error.HandShakeFail;
        }
    }

    pub fn init(allocator: std.mem.Allocator) !Connection {
        const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvVarNotFound;

        const socket_path = try extractUnixSocketPath(bus_address);
        const socket = try net.connectUnixSocket(socket_path);
        std.log.debug(":: Connected to D-Bus at: {s}", .{socket_path});

        try auth(socket);

        return Connection{
            .__inner_sock = socket,
            .__allocator = allocator,
            .serial_counter = 1,
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
        const Str = Value.String();
        const U32 = Value.Uint32();
        const serial = self.serial_counter;
        defer self.serial_counter += 1;
        var body_arr = std.ArrayList(u8).init(self.__allocator);
        defer body_arr.deinit();

        try Str.new(name).ser(&body_arr);
        try U32.new(@intFromEnum(RequestNameFlags.DoNotQueue) | @intFromEnum(RequestNameFlags.ReplaceExisting)).ser(&body_arr);

        const header = core.MessageHeader{
            .message_type = @intFromEnum(core.MessageType.MethodCall),
            .flags = @intFromEnum(core.MessageFlag.__EMPTY),
            .proto_version = 1,
            .body_length = @intCast(body_arr.items.len),
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = @intFromEnum(core.HeaderFieldCode.Destination), .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Path), .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Interface), .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.Member), .value = .{ .Member = "RequestName" } },
                .{ .code = @intFromEnum(core.HeaderFieldCode.ReplySerial), .value = .{ .ReplySerial = serial } },
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
    // NOTE: system socket path = /var/run/dbus/system_bus_socket
    const prefix = "unix:path=";
    if (!std.mem.startsWith(u8, address, prefix)) {
        return error.InvalidAddressFormat;
    }
    return address[prefix.len..];
}
