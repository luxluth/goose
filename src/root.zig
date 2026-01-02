const net = std.net;
const rand = std.crypto.random;

pub const core = @import("core.zig");
const Value = core.value.Value;
const GStr = core.value.GStr;
const DBusWriter = core.value.DBusWriter;
const readInteger = core.utils.readInteger;
const convertInteger = core.utils.convertInteger;
pub const message = @import("message_utils.zig");
pub const proxy = @import("proxy.zig");
pub const introspection = @import("introspection.zig");
pub const generator = @import("generator.zig");

const std = @import("std");
const DBusReader = struct {
    pos: usize = 0,
    reader: *std.Io.Reader,

    fn readByte(self: *DBusReader) !u8 {
        const byte = try self.reader.takeByte();
        self.pos += 1;
        return byte;
    }

    fn readU32(self: *DBusReader, endian: std.builtin.Endian) !u32 {
        try self.alignToBoundary(4);
        const value = try self.reader.takeInt(u32, endian);
        self.pos += 4;
        return value;
    }

    fn alignToBoundary(self: *DBusReader, alignment: usize) !void {
        const next_pos = std.mem.alignForward(usize, self.pos, alignment);
        try self.reader.discardAll(next_pos - self.pos);
        self.pos = next_pos;
    }
};

pub const SignalHandler = struct {
    interface: []const u8,
    member: []const u8,
    callback: *const fn (ctx: ?*anyopaque, msg: core.Message) void,
    ctx: ?*anyopaque,
};

pub const Connection = struct {
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    serial_counter: u32 = 1,
    pending_messages: std.ArrayList(core.Message),
    signal_handlers: std.ArrayList(SignalHandler),

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
        if (!std.mem.startsWith(u8, response, "OK")) {
            return error.HandshakeFail;
        }

        try io_writer.print("BEGIN\r\n", .{});
        try io_writer.flush();
    }

    pub fn init(allocator: std.mem.Allocator) !Connection {
        const bus_address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvVarNotFound;

        const socket_path = try extractUnixSocketPath(bus_address);
        const socket = try net.connectUnixSocket(socket_path);

        try auth(socket);

        var conn = Connection{
            .__inner_sock = socket,
            .__allocator = allocator,
            .pending_messages = try std.ArrayList(core.Message).initCapacity(allocator, 10),
            .signal_handlers = try std.ArrayList(SignalHandler).initCapacity(allocator, 0),
        };

        try conn.sayHello();

        return conn;
    }

    fn sayHello(self: *Connection) !void {
        const serial = self.serial_counter;
        defer self.serial_counter += 1;

        const header = core.MessageHeader{
            .message_type = core.MessageType.MethodCall,
            .flags = @intFromEnum(core.MessageFlag.__EMPTY),
            .proto_version = 1,
            .body_length = 0,
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "Hello" } },
                // .{ .code = core.HeaderFieldCode.Signature, .value = .{ .Signature = "()" } },
            }),
        };

        const body = std.ArrayList(u8).empty;

        const msg = core.Message.new(header, body.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
    }

    /// This function closes the underlined socket
    pub fn close(self: *Connection) void {
        for (self.pending_messages.items) |*msg| {
            self.freeMessage(msg);
        }
        self.pending_messages.deinit(self.__allocator);
        self.signal_handlers.deinit(self.__allocator);
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
            .flags = flags,
            .proto_version = 1,
            .body_length = @intCast(body_arr.items.len),
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "RequestName" } },
                .{ .code = core.HeaderFieldCode.Signature, .value = .{ .Signature = "su" } },
                // .{ .code = core.HeaderFieldCode.ReplySerial, .value = .{ .ReplySerial = serial } },
            }),
        };

        const msg = core.Message.new(header, body_arr.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
    }

    /// Registers interest in specific signals or messages.
    /// `match` is a D-Bus match rule, e.g., "type='signal',interface='org.freedesktop.DBus'".
    pub fn addMatch(self: *Connection, match: [:0]const u8) !void {
        const encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(match));
        // We don't care about the return value usually for AddMatch
        var reply = try self.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            encoder.signature(),
            encoder.body(),
        );
        self.freeMessage(&reply);
    }

    pub fn methodCall(
        self: *Connection,
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        member: [:0]const u8,
        signature: ?[:0]const u8,
        body: []const u8,
    ) !core.Message {
        const serial = self.serial_counter;
        defer self.serial_counter += 1;

        var fields_list = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 5);
        defer fields_list.deinit(self.__allocator);

        try fields_list.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = dest } });
        try fields_list.append(self.__allocator, .{ .code = .Path, .value = .{ .Path = path } });
        try fields_list.append(self.__allocator, .{ .code = .Interface, .value = .{ .Interface = iface } });
        try fields_list.append(self.__allocator, .{ .code = .Member, .value = .{ .Member = member } });

        if (signature) |sig| {
            try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = sig } });
        }

        const header = core.MessageHeader{
            .message_type = .MethodCall,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(body.len),
            .serial = serial,
            .header_fields = fields_list.items,
        };

        const msg = core.Message.new(header, body);
        var bytes = try msg.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);

        return self.call(bytes.items, serial);
    }

    pub fn freeMessage(self: *Connection, msg: *core.Message) void {
        self.__allocator.free(msg.body);
        for (msg.header.header_fields) |f| {
            switch (f.value) {
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| {
                    self.__allocator.free(s);
                },
                else => {},
            }
        }
        self.__allocator.free(msg.header.header_fields);
    }

    pub fn registerSignalHandler(self: *Connection, interface: []const u8, member: []const u8, callback: *const fn (ctx: ?*anyopaque, msg: core.Message) void, ctx: ?*anyopaque) !void {
        try self.signal_handlers.append(self.__allocator, .{
            .interface = interface,
            .member = member,
            .callback = callback,
            .ctx = ctx,
        });
    }

    /// Blocks until a message is received and returns it.
    /// This will return messages from the pending queue first.
    /// Signals that match a registered handler will be dispatched automatically and NOT returned.
    pub fn waitMessage(self: *Connection) !core.Message {
        while (true) {
            const msg = if (self.pending_messages.items.len > 0)
                self.pending_messages.orderedRemove(0)
            else
                try self.readNextMessage();

            if (msg.header.message_type == .Signal) {
                var dispatched = false;
                for (self.signal_handlers.items) |handler| {
                    if (msg.isSignal(handler.interface, handler.member)) {
                        handler.callback(handler.ctx, msg);
                        dispatched = true;
                    }
                }
                if (dispatched) {
                    self.freeMessage(@constCast(&msg));
                    continue;
                }
            }

            return msg;
        }
    }

    fn readNextMessage(self: *Connection) !core.Message {
        var header_buf: [16]u8 = undefined;
        try readExact(self.__inner_sock, &header_buf);

        const endian: std.builtin.Endian = switch (header_buf[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadEndianFlag,
        };
        const mtype: core.MessageType = @enumFromInt(header_buf[1]);
        const flags = header_buf[2];
        const version = header_buf[3];
        const body_len = std.mem.readInt(u32, header_buf[4..8], endian);
        const msg_serial = std.mem.readInt(u32, header_buf[8..12], endian);
        const fields_len = std.mem.readInt(u32, header_buf[12..16], endian);

        const fields_bytes = try self.__allocator.alloc(u8, fields_len);
        defer self.__allocator.free(fields_bytes);
        try readExact(self.__inner_sock, fields_bytes);

        // Align stream to 8 bytes
        const current_pos = 16 + fields_len;
        const padding = (8 - (current_pos % 8)) % 8;
        if (padding > 0) {
            var pad_buf: [8]u8 = undefined;
            try readExact(self.__inner_sock, pad_buf[0..padding]);
        }

        // Read body
        const body = try self.__allocator.alloc(u8, body_len);
        errdefer self.__allocator.free(body);
        try readExact(self.__inner_sock, body);

        // Parse fields
        var fields_list = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 4);
        errdefer {
            for (fields_list.items) |f| {
                switch (f.value) {
                    .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            fields_list.deinit(self.__allocator);
        }

        var fstream = std.io.fixedBufferStream(fields_bytes);
        var freader = fstream.reader();
        var fpos: usize = 0;

        while (fpos < fields_len) {
            const padding_f = (8 - (fpos % 8)) % 8;
            if (padding_f > 0) {
                try freader.skipBytes(padding_f, .{});
                fpos += padding_f;
            }
            if (fpos >= fields_len) break;

            const code_u8 = try freader.readByte();
            fpos += 1;
            const code: core.HeaderFieldCode = if (code_u8 <= 9) @enumFromInt(code_u8) else .Invalid;

            // Variant signature (we assume standard fields have correct types)
            const sig_len = try freader.readByte();
            fpos += 1;
            try freader.skipBytes(sig_len + 1, .{}); // sig + null
            fpos += sig_len + 1;

            switch (code) {
                .ReplySerial => {
                    const pad4 = (4 - (fpos % 4)) % 4;
                    try freader.skipBytes(pad4, .{});
                    fpos += pad4;
                    const val = try freader.readInt(u32, endian);
                    fpos += 4;
                    try fields_list.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = val } });
                },
                .UnixFds => {
                    const pad4 = (4 - (fpos % 4)) % 4;
                    try freader.skipBytes(pad4, .{});
                    fpos += pad4;
                    const val = try freader.readInt(u32, endian);
                    fpos += 4;
                    try fields_list.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = val } });
                },
                .Signature => {
                    const s_len = try freader.readByte();
                    fpos += 1;
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readNoEof(s_owned);
                    fpos += s_len;
                    try freader.skipBytes(1, .{}); // null
                    fpos += 1;
                    try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = s_owned } });
                },
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender => |c| {
                    const pad4 = (4 - (fpos % 4)) % 4;
                    try freader.skipBytes(pad4, .{});
                    fpos += pad4;
                    const s_len = try freader.readInt(u32, endian);
                    fpos += 4;
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readNoEof(s_owned);
                    fpos += s_len;
                    try freader.skipBytes(1, .{}); // null
                    fpos += 1;

                    const hfv: core.HeaderFieldValue = switch (c) {
                        .Path => .{ .Path = s_owned },
                        .Interface => .{ .Interface = s_owned },
                        .Member => .{ .Member = s_owned },
                        .ErrorName => .{ .ErrorName = s_owned },
                        .Destination => .{ .Destination = s_owned },
                        .Sender => .{ .Sender = s_owned },
                        else => unreachable,
                    };
                    try fields_list.append(self.__allocator, .{ .code = c, .value = hfv });
                },
                else => {
                    // Unknown field, cannot safely skip without parsing signature.
                    // For now, assume it consumes nothing more or panic?
                    // We risk desync here.
                    std.debug.print("WARN: Unknown Header Field Code {d}\n", .{code_u8});
                    return error.UnknownHeaderField;
                },
            }
        }

        return core.Message{
            .header = .{
                .endianess = endian,
                .message_type = mtype,
                .flags = flags,
                .proto_version = version,
                .body_length = body_len,
                .serial = msg_serial,
                .header_fields = try fields_list.toOwnedSlice(self.__allocator),
            },
            .body = body,
        };
    }

    fn readExact(stream: net.Stream, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try stream.read(buf[got..]);
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

    fn printData(data: []u8) void {
        for (data) |x| {
            if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
                std.debug.print("{c}", .{x});
            } else {
                std.debug.print("\\{o}", .{x});
            }
        }
        std.debug.print("\n", .{});
    }

    fn call(self: *Connection, data: []u8, serial: u32) !core.Message {
        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(&writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeAll(data);
        try io_writer.flush();

        while (true) {
            // Check pending messages first
            for (self.pending_messages.items, 0..) |*msg, i| {
                if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                    for (msg.header.header_fields) |f| {
                        if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                            const found = self.pending_messages.orderedRemove(i);
                            return found;
                        }
                    }
                }
            }

            // Read new message
            const msg = try self.readNextMessage();

            // Check if it is the reply
            var is_reply = false;
            if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                for (msg.header.header_fields) |f| {
                    if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                        is_reply = true;
                        break;
                    }
                }
            }

            if (is_reply) {
                return msg;
            } else {
                try self.pending_messages.append(self.__allocator, msg);
            }
        }
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
