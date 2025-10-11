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
        const io_reader: *std.Io.Reader = reader.interface();

        var writer_buffer: [2048]u8 = undefined;
        var writer = socket.writer(&writer_buffer);
        var io_writer = &writer.interface;

        const uid: u32 = std.posix.getuid();
        var uid_buf: [32]u8 = undefined;
        const uid_str = try std.fmt.bufPrint(&uid_buf, "{}", .{uid});

        var hex_buf: [64]u8 = undefined;
        var out_i: usize = 0;
        for (uid_str) |ch| {
            const hi = "0123456789ABCDEF"[(ch >> 4) & 0xF];
            const lo = "0123456789ABCDEF"[ch & 0xF];
            hex_buf[out_i] = hi;
            hex_buf[out_i + 1] = lo;
            out_i += 2;
        }

        const hex = hex_buf[0..out_i];

        try io_writer.writeByte(0);
        try io_writer.print("AUTH EXTERNAL {s}\r\n", .{hex});
        try io_writer.flush();

        const response = try io_reader.takeDelimiterInclusive('\n');
        std.debug.print("RESPONSE = {s}\n", .{response});
        if (!std.mem.startsWith(u8, response, "OK")) {
            return error.HandshakeFail;
        }

        try io_writer.print("BEGIN\r\n", .{});
    }

    pub fn init(allocator: std.mem.Allocator) !Connection {
        const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvVarNotFound;

        const socket_path = try extractUnixSocketPath(bus_address);
        const socket = try net.connectUnixSocket(socket_path);
        std.log.debug("Connected to D-Bus at: {s}", .{socket_path});

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
        var body_arr = try std.ArrayList(u8).initCapacity(self.__allocator, 256);
        defer body_arr.deinit(self.__allocator);

        try Str.new(name).ser(&body_arr, self.__allocator);
        try U32.new(@intFromEnum(RequestNameFlags.DoNotQueue) | @intFromEnum(RequestNameFlags.ReplaceExisting)).ser(&body_arr, self.__allocator);

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
        var bytes = try message.pack(self.__allocator);
        std.debug.print("{any}\n", .{message});
        defer bytes.deinit(self.__allocator);
        try self.sendBytesAndWaitForAnswer(bytes.items, serial);
    }

    fn sendBytesAndWaitForAnswer(self: *Connection, data: []u8, serial: u32) !void {
        try self.__inner_sock.writeAll(data);
        std.debug.print("[:{d}:SEND] -> {d} o\n", .{ serial, data.len });
        var reader_buf: [4096]u8 = undefined;
        var reader = self.__inner_sock.reader(&reader_buf);
        const io_reader: *std.Io.Reader = reader.interface();
        try io_reader.readSliceAll(&reader_buf);
        std.debug.print("{c}", .{reader_buf[0]});
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
