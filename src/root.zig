const std = @import("std");
const net = std.net;
const rand = std.crypto.random;

pub const core = @import("core.zig");

const Value = core.value.Value;
const DBusWriter = core.value.DBusWriter;
const readInteger = core.utils.readInteger;
const convertInteger = core.utils.convertInteger;

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

        var dwriter = DBusWriter.init(&body_arr, self.__allocator, .little);

        const flags =
            @intFromEnum(RequestNameFlags.DoNotQueue) |
            @intFromEnum(RequestNameFlags.ReplaceExisting);

        try Str.new(name).ser(&dwriter);
        try U32.new(flags).ser(&dwriter);

        const header = core.MessageHeader{
            .message_type = core.MessageType.MethodCall,
            .flags = @intFromEnum(core.MessageFlag.__EMPTY),
            .proto_version = 1,
            .body_length = @intCast(body_arr.items.len),
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "RequestName" } },
                .{ .code = core.HeaderFieldCode.Signature, .value = .{ .Signature = "su" } },
            }),
        };

        const message = core.Message.new(header, body_arr.items);
        var bytes = try message.pack(self.__allocator);
        // const tt = Value.Struct(core.MessageHeader).new(header);
        // std.debug.print("{s} ~ {any}\n", .{ tt.repr, message });
        std.debug.print("{any}\n", .{header.header_fields});
        defer bytes.deinit(self.__allocator);
        try self.sendBytesAndWaitForAnswer(bytes.items, serial);
    }

    fn readExact(r: *std.Io.Reader, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try r.readSliceShort(buf[got..]);
            if (n == 0) return error.UnexpectedEof;
            got += n;
        }
    }

    fn readPadding(r: *std.Io.Reader, current_offset: *usize, @"align": usize) !void {
        const rem = current_offset.* % @"align";
        if (rem == 0) return;
        var tmp: [8]u8 = undefined;
        const need = @"align" - rem;
        try readExact(r, tmp[0..need]);
        current_offset.* += need;
    }

    fn sendBytesAndWaitForAnswer(self: *Connection, data: []u8, serial: u32) !void {
        try self.__inner_sock.writeAll(data);
        std.debug.print("[:{d}:SEND] -> {d} bytes\n", .{ serial, data.len });

        var rbuf: [8192]u8 = undefined;
        var reader = self.__inner_sock.reader(&rbuf);
        const io_reader: *std.Io.Reader = reader.interface();

        var hdr4: [4]u8 = undefined;
        try readExact(io_reader, hdr4[0..4]); // byte order, type, flags, version
        const endian: std.builtin.Endian = switch (hdr4[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadEndianFlag,
        };

        const mtype: u8 = hdr4[1];
        _ = hdr4[2]; // flags
        _ = hdr4[3]; // version

        var u32b: [4]u8 = undefined;
        try readExact(io_reader, u32b[0..4]); // body_length
        const body_len: u32 = readInteger(u32, &u32b, endian);
        try readExact(io_reader, u32b[0..4]); // serial
        const msg_serial: u32 = readInteger(u32, &u32b, endian);

        // offset counts from start of message body (we’re reading header at offset 0)
        var off: usize = 12;
        // --- header fields array: pad to 4, read len, pad to 8, read payload ---
        try readPadding(io_reader, &off, 4);
        try readExact(io_reader, u32b[0..4]);
        const fields_len: u32 = readInteger(u32, &u32b, endian);
        off += 4;

        try readPadding(io_reader, &off, 8);

        const fields_bytes = try self.__allocator.alloc(u8, fields_len);
        defer self.__allocator.free(fields_bytes);
        try readExact(io_reader, fields_bytes);
        off += fields_len;

        // --- pad header to 8, then read body ---
        try readPadding(io_reader, &off, 8);

        const body = try self.__allocator.alloc(u8, body_len);
        defer self.__allocator.free(body);
        if (body_len > 0) try readExact(io_reader, body);

        // TODO: parse fields_bytes to find ReplySerial and ensure it matches `serial`.
        // For a production client, loop reading messages until you find:
        //   mtype in {MethodReturn, Error} AND header.ReplySerial == serial

        std.debug.print("RECV type={d} serial={d} body_len={d}\n", .{ mtype, msg_serial, body_len });
        // TODO: decode body according to header Signature if you need the return value
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
