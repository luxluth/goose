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
pub const xml_generator = @import("xml_generator.zig");

const std = @import("std");

/// Signal definition helper.
/// Returns a type that represents a signal carrying a payload of type T.
pub fn Signal(comptime T: type) type {
    return struct {
        name: [:0]const u8,
        interface: ?[:0]const u8 = null,
        path: ?[:0]const u8 = null,
        // Marker to identify this struct
        pub const __is_goose_signal = true;
        pub const PayloadType = T;

        /// Triggers a signal.
        /// `conn`: The connection to send the signal on.
        /// `sig`: The signal field from the interface struct.
        /// `payload`: The payload matching the signal's type.
        pub fn trigger(self: *@This(), conn: *Connection, payload: T) !void {
            const interface = self.interface orelse return error.SignalNotBound;
            const path = self.path orelse return error.SignalNotBound;

            var encoder = try message.BodyEncoder.encode(conn.__allocator, payload);
            defer encoder.deinit();

            const serial = conn.serial_counter;
            conn.serial_counter += 1;

            const header = core.MessageHeader{
                .message_type = .Signal,
                .flags = 0,
                .proto_version = 1,
                .body_length = @intCast(encoder.body().len),
                .serial = serial,
                .header_fields = @constCast(&[_]core.HeaderField{
                    .{ .code = .Path, .value = .{ .Path = path } },
                    .{ .code = .Interface, .value = .{ .Interface = interface } },
                    .{ .code = .Member, .value = .{ .Member = self.name } },
                    .{ .code = .Signature, .value = .{ .Signature = encoder.signature() } },
                }),
            };

            const msg = core.Message.new(header, encoder.body());
            try conn.sendMessage(msg);
        }
    };
}

/// Creates a new signal definition.
pub fn signal(name: [:0]const u8, comptime T: type) Signal(T) {
    return .{ .name = name };
}

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

const InterfaceWrapper = struct {
    instance: *anyopaque,
    dispatch: *const fn (wrapper: *const InterfaceWrapper, conn: *Connection, msg: core.Message) anyerror!void,
    destroy: *const fn (wrapper: *const InterfaceWrapper, allocator: std.mem.Allocator) void,
    interface_name: []const u8, // For matching
    path: []const u8, // For matching
    intro_xml: [:0]const u8,
};

pub const Connection = struct {
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    serial_counter: u32 = 1,
    pending_messages: std.ArrayList(core.Message),
    signal_handlers: std.ArrayList(SignalHandler),
    registered_interfaces: std.ArrayList(InterfaceWrapper),

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
            .registered_interfaces = try std.ArrayList(InterfaceWrapper).initCapacity(allocator, 0),
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

        for (self.registered_interfaces.items) |*wrapper| {
            wrapper.destroy(wrapper, self.__allocator);
        }
        self.registered_interfaces.deinit(self.__allocator);

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

    pub fn sendMessage(self: *Connection, msg: core.Message) !void {
        var bytes = try msg.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);

        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(&writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeAll(bytes.items);
        try io_writer.flush();
    }

    /// Registers an object (interface implementation) at a specific path.
    /// The struct T must have `init`. `INTERFACE_NAME` decl is preferred but optional (falls back to bus_name).
    /// `bus_name`: The well-known name to request on the bus.
    /// `path`: The object path to export this interface at.
    pub fn registerObject(self: *Connection, comptime T: type, bus_name: [:0]const u8, path: [:0]const u8) !usize {
        try self.requestName(bus_name);

        const interface_name = if (@hasDecl(T, "INTERFACE_NAME")) T.INTERFACE_NAME else if (@hasDecl(T, "REQUESTED_NAME")) T.REQUESTED_NAME else bus_name;

        // Instantiate
        var instance_ptr = try self.__allocator.create(T);
        // We assume init signature: fn init(conn: *Connection, userData: anytype) T
        // For now, passing {} as userData.
        instance_ptr.* = T.init(self, {});

        // Bind signals
        // We iterate over fields. If a field is a Signal, we set its interface and path.
        inline for (std.meta.fields(T)) |field| {
            const FieldType = field.type;
            if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "__is_goose_signal")) {
                var sig = &@field(instance_ptr, field.name);
                sig.interface = interface_name;
                sig.path = path;
            }
        }

        // Generate Introspection XML
        const intro_xml = try xml_generator.generateIntrospectionXml(self.__allocator, T, interface_name);

        // Create wrapper
        const wrapper = InterfaceWrapper{
            .instance = @ptrCast(instance_ptr),
            .interface_name = interface_name,
            .path = path,
            .intro_xml = intro_xml,
            .destroy = struct {
                fn destroy(w: *const InterfaceWrapper, alloc: std.mem.Allocator) void {
                    const self_ptr = @as(*T, @ptrCast(@alignCast(w.instance)));
                    alloc.destroy(self_ptr);
                    alloc.free(w.intro_xml);
                }
            }.destroy,
            .dispatch = struct {
                fn dispatch(w: *const InterfaceWrapper, conn: *Connection, msg: core.Message) anyerror!void {
                    const self_obj = @as(*T, @ptrCast(@alignCast(w.instance)));

                    // Find member
                    var member_name: ?[]const u8 = null;
                    var iface_name: ?[]const u8 = null;
                    for (msg.header.header_fields) |f| {
                        switch (f.value) {
                            .Member => |m| member_name = m,
                            .Interface => |i| iface_name = i,
                            else => {},
                        }
                    }
                    const member = member_name orelse return;

                    // Handle Introspect
                    if (iface_name) |iface| {
                        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
                            // Return XML
                            var encoder = try message.BodyEncoder.encode(conn.__allocator, GStr.new(w.intro_xml));
                            defer encoder.deinit();

                            var dest: ?[:0]const u8 = null;
                            for (msg.header.header_fields) |f| if (f.code == .Sender) {
                                dest = f.value.Sender;
                            };

                            var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(conn.__allocator, 3);
                            defer reply_fields.deinit(conn.__allocator);
                            try reply_fields.append(conn.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = msg.header.serial } });
                            if (dest) |d| try reply_fields.append(conn.__allocator, .{ .code = .Destination, .value = .{ .Destination = d } });
                            try reply_fields.append(conn.__allocator, .{ .code = .Signature, .value = .{ .Signature = encoder.signature() } });

                            const reply_h = core.MessageHeader{
                                .message_type = .MethodReturn,
                                .flags = 0,
                                .proto_version = 1,
                                .body_length = @intCast(encoder.body().len),
                                .serial = conn.serial_counter,
                                .header_fields = reply_fields.items,
                            };
                            conn.serial_counter += 1;
                            try conn.sendMessage(core.Message.new(reply_h, encoder.body()));
                            return;
                        }
                    }

                    // Dispatch to method
                    inline for (@typeInfo(T).@"struct".decls) |decl| {
                        const field_val = @field(T, decl.name);
                        const field_type = @TypeOf(field_val);

                        if (@typeInfo(field_type) == .@"fn") {
                            if (!std.mem.eql(u8, decl.name, "init")) {
                                const fn_info = @typeInfo(field_type).@"fn";
                                if (fn_info.params.len > 0 and fn_info.params[0].type == *T) {
                                    if (std.mem.eql(u8, member, decl.name)) {
                                        const result = try @call(.auto, field_val, .{self_obj});
                                        var encoder = try message.BodyEncoder.encode(conn.__allocator, result);
                                        defer encoder.deinit();

                                        var dest: ?[:0]const u8 = null;
                                        for (msg.header.header_fields) |f| if (f.code == .Sender) {
                                            dest = f.value.Sender;
                                        };

                                        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(conn.__allocator, 3);
                                        defer reply_fields.deinit(conn.__allocator);
                                        try reply_fields.append(conn.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = msg.header.serial } });
                                        if (dest) |d| try reply_fields.append(conn.__allocator, .{ .code = .Destination, .value = .{ .Destination = d } });
                                        try reply_fields.append(conn.__allocator, .{ .code = .Signature, .value = .{ .Signature = encoder.signature() } });

                                        const reply_h = core.MessageHeader{
                                            .message_type = .MethodReturn,
                                            .flags = 0,
                                            .proto_version = 1,
                                            .body_length = @intCast(encoder.body().len),
                                            .serial = conn.serial_counter,
                                            .header_fields = reply_fields.items,
                                        };
                                        conn.serial_counter += 1;
                                        try conn.sendMessage(core.Message.new(reply_h, encoder.body()));
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }.dispatch,
        };

        try self.registered_interfaces.append(self.__allocator, wrapper);
        return self.registered_interfaces.items.len - 1;
    }

    pub fn waitOnHandle(self: *Connection, handle: usize) !void {
        if (handle >= self.registered_interfaces.items.len) return error.InvalidHandle;

        while (true) {
            var msg = try self.waitMessage();
            defer self.freeMessage(&msg);

            if (msg.header.message_type == .MethodCall) {
                // Check interface and path
                var iface: ?[]const u8 = null;
                var path: ?[]const u8 = null;
                var member: ?[]const u8 = null;
                for (msg.header.header_fields) |f| {
                    if (f.code == .Interface) iface = f.value.Interface;
                    if (f.code == .Path) path = f.value.Path;
                    if (f.code == .Member) member = f.value.Member;
                }

                if (path) |p| {
                    var handled = false;
                    for (self.registered_interfaces.items) |*wrapper| {
                        // Check path first
                        if (std.mem.eql(u8, wrapper.path, p)) {
                            // Then check interface or Introspectable
                            if (iface) |i| {
                                if (std.mem.eql(u8, wrapper.interface_name, i) or std.mem.eql(u8, i, "org.freedesktop.DBus.Introspectable")) {
                                    // Dispatch
                                    try wrapper.dispatch(wrapper, self, msg);
                                    handled = true;
                                }
                            } else {
                                // Fallback dispatch
                                try wrapper.dispatch(wrapper, self, msg);
                                handled = true;
                            }
                        }
                    }

                    // Dynamic Introspection logic
                    if (!handled) {
                        if (member) |m| {
                            if (std.mem.eql(u8, m, "Introspect") and (iface == null or std.mem.eql(u8, iface.?, "org.freedesktop.DBus.Introspectable"))) {
                                // Check for children
                                var children_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 256);
                                defer children_xml.deinit(self.__allocator);

                                // We need a set to avoid duplicates
                                var seen_children = std.StringHashMap(void).init(self.__allocator);
                                defer seen_children.deinit();

                                for (self.registered_interfaces.items) |*wrapper| {
                                    if (std.mem.startsWith(u8, wrapper.path, p)) {
                                        if (wrapper.path.len > p.len) {
                                            var child_name: []const u8 = "";
                                            if (std.mem.eql(u8, p, "/")) {
                                                // Special case root
                                                if (wrapper.path.len > 1) {
                                                    const sub = wrapper.path[1..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            } else {
                                                // Check if wrapper.path[p.len] == '/'
                                                if (wrapper.path[p.len] == '/') {
                                                    const sub = wrapper.path[p.len + 1 ..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            }

                                            if (child_name.len > 0) {
                                                if (!seen_children.contains(child_name)) {
                                                    try seen_children.put(child_name, {});
                                                    try children_xml.writer(self.__allocator).print("  <node name=\"{s}\"/>\n", .{child_name});
                                                }
                                            }
                                        }
                                    }
                                }

                                if (children_xml.items.len > 0) {
                                    // Construct full XML
                                    var full_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 1024);
                                    defer full_xml.deinit(self.__allocator);
                                    const w = full_xml.writer(self.__allocator);
                                    try w.writeAll("<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
                                    try w.writeAll(" \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
                                    try w.writeAll("<node>\n");
                                    try w.writeAll(children_xml.items);
                                    try w.writeAll("</node>\n");

                                    // Send Reply
                                    const xml_slice = try full_xml.toOwnedSliceSentinel(self.__allocator, 0);
                                    defer self.__allocator.free(xml_slice);

                                    var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(xml_slice));
                                    defer encoder.deinit();

                                    var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 3);
                                    defer reply_fields.deinit(self.__allocator);
                                    try reply_fields.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = msg.header.serial } });

                                    var dest: ?[:0]const u8 = null;
                                    for (msg.header.header_fields) |f| if (f.code == .Sender) {
                                        dest = f.value.Sender;
                                    };
                                    if (dest) |d| try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = d } });
                                    try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = encoder.signature() } });

                                    const reply_h = core.MessageHeader{
                                        .message_type = .MethodReturn,
                                        .flags = 0,
                                        .proto_version = 1,
                                        .body_length = @intCast(encoder.body().len),
                                        .serial = self.serial_counter,
                                        .header_fields = reply_fields.items,
                                    };
                                    self.serial_counter += 1;
                                    try self.sendMessage(core.Message.new(reply_h, encoder.body()));
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Registers interest in specific signals or messages.
    /// `match` is a D-Bus match rule, e.g., "type='signal',interface='org.freedesktop.DBus'".
    pub fn addMatch(self: *Connection, match: [:0]const u8) !void {
        var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(match));
        defer encoder.deinit();
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
