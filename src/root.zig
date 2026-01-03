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

pub const Access = enum { Read, Write, ReadWrite };

/// Property definition helper.
pub fn Property(comptime T: type, comptime access_mode: Access) type {
    return struct {
        value: T,
        pub const __is_goose_property = true;
        pub const DataType = T;
        pub const AccessMode = access_mode;
    };
}

/// Creates a new property with initial value and access.
pub fn property(comptime T: type, comptime access: Access, value: T) Property(T, access) {
    return .{ .value = value };
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
    interface_name: [:0]const u8, // For matching
    path: [:0]const u8, // For matching
    intro_xml: [:0]const u8,
};

pub const Connection = struct {
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    __reader_buf: []u8,
    __reader: net.Stream.Reader,
    serial_counter: u32 = 1,
    pending_messages: std.ArrayList(core.Message),
    signal_handlers: std.ArrayList(SignalHandler),
    registered_interfaces: std.ArrayList(InterfaceWrapper),

    fn auth(conn: *Connection) !void {
        const reader: *std.io.Reader = conn.__reader.interface();

        var writer_buffer: [2048]u8 = undefined;
        var writer = conn.__inner_sock.writer(&writer_buffer);
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

        const response = try reader.takeDelimiterInclusive('\n');
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

        const reader_buf = try allocator.alloc(u8, 4096 * 10);
        errdefer allocator.free(reader_buf);

        var conn = Connection{
            .__inner_sock = socket,
            .__allocator = allocator,
            .__reader_buf = reader_buf,
            .__reader = socket.reader(reader_buf),
            .pending_messages = try std.ArrayList(core.Message).initCapacity(allocator, 10),
            .signal_handlers = try std.ArrayList(SignalHandler).initCapacity(allocator, 0),
            .registered_interfaces = try std.ArrayList(InterfaceWrapper).initCapacity(allocator, 0),
        };

        try auth(&conn);

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

        self.__allocator.free(self.__reader_buf);
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

                    // PropUnion Generation
                    const PropUnion = blk: {
                        comptime var fields: []const std.builtin.Type.UnionField = &.{};
                        comptime var enum_fields: []const std.builtin.Type.EnumField = &.{};
                        comptime var count: usize = 0;

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.fields) |f| {
                            const FType = f.type;
                            const type_info = @typeInfo(FType);
                            const DataType = if (type_info == .@"struct" and @hasDecl(FType, "__is_goose_property")) FType.DataType else FType;
                            const is_prop = if (type_info == .@"struct" and @hasDecl(FType, "__is_goose_property")) true else pblk: {
                                const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                const is_conn = std.mem.eql(u8, f.name, "conn");
                                const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                break :pblk !is_signal and !is_conn and !is_ptr;
                            };

                            if (is_prop) {
                                fields = fields ++ &[_]std.builtin.Type.UnionField{.{ .name = f.name, .type = DataType, .alignment = @alignOf(DataType) }};
                                enum_fields = enum_fields ++ &[_]std.builtin.Type.EnumField{.{ .name = f.name, .value = count }};
                                count += 1;
                            }
                        }

                        if (count == 0) break :blk union { _dummy: void };

                        const TagType = @Type(.{ .@"enum" = .{
                            .tag_type = u16,
                            .fields = enum_fields,
                            .decls = &.{},
                            .is_exhaustive = true,
                        } });

                        break :blk @Type(.{ .@"union" = .{
                            .layout = .auto,
                            .tag_type = TagType,
                            .fields = fields,
                            .decls = &.{},
                        } });
                    };

                    if (iface_name != null and std.mem.eql(u8, iface_name.?, "org.freedesktop.DBus.Properties")) {
                        if (std.mem.eql(u8, member, "GetAll")) {
                            var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                            const requested_iface = try decoder.decode(GStr);
                            if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                                const VariantType = Value.Variant(PropUnion);
                                var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                                defer dict.deinit();

                                const struct_info = @typeInfo(T).@"struct";
                                inline for (struct_info.fields) |f| {
                                    const FType = f.type;
                                    const type_info = @typeInfo(FType);
                                    const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                                    const is_prop = is_wrapped or blk: {
                                        const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                        const is_conn = std.mem.eql(u8, f.name, "conn");
                                        const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                        break :blk !is_signal and !is_conn and !is_ptr;
                                    };
                                    const readable = if (is_wrapped) FType.AccessMode != .Write else true;

                                    if (is_prop and readable) {
                                        const val_field = @field(self_obj, f.name);
                                        const val = if (is_wrapped) val_field.value else val_field;
                                        try dict.put(f.name, VariantType.new(@unionInit(PropUnion, f.name, val)));
                                    }
                                }

                                var encoder = try message.BodyEncoder.encode(conn.__allocator, Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict));
                                defer encoder.deinit();
                                try conn.sendReply(msg, encoder);
                            } else {
                                const VariantType = Value.Variant(PropUnion);
                                var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                                defer dict.deinit();
                                var encoder = try message.BodyEncoder.encode(conn.__allocator, Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict));
                                defer encoder.deinit();
                                try conn.sendReply(msg, encoder);
                            }
                            return;
                        } else if (std.mem.eql(u8, member, "Get")) {
                            var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                            const requested_iface = try decoder.decode(GStr);
                            const prop_name = try decoder.decode(GStr);

                            if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                                const VariantType = Value.Variant(PropUnion);
                                var found = false;
                                var val_variant: VariantType = undefined;

                                const struct_info = @typeInfo(T).@"struct";
                                inline for (struct_info.fields) |f| {
                                    if (!found and std.mem.eql(u8, f.name, prop_name.s)) {
                                        const FType = f.type;
                                        const type_info = @typeInfo(FType);
                                        const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                                        const is_prop = is_wrapped or blk: {
                                            const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                            const is_conn = std.mem.eql(u8, f.name, "conn");
                                            const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                            break :blk !is_signal and !is_conn and !is_ptr;
                                        };
                                        const readable = if (is_wrapped) FType.AccessMode != .Write else true;

                                        if (is_prop) {
                                            if (readable) {
                                                const val_field = @field(self_obj, f.name);
                                                const val = if (is_wrapped) val_field.value else val_field;
                                                val_variant = VariantType.new(@unionInit(PropUnion, f.name, val));
                                                found = true;
                                            }
                                        }
                                    }
                                }

                                if (found) {
                                    var encoder = try message.BodyEncoder.encode(conn.__allocator, val_variant);
                                    defer encoder.deinit();
                                    try conn.sendReply(msg, encoder);
                                }
                            }
                            return;
                        } else if (std.mem.eql(u8, member, "Set")) {
                            var decoder = message.BodyDecoder.fromMessage(conn.__allocator, msg);
                            const requested_iface = try decoder.decode(GStr);
                            const prop_name = try decoder.decode(GStr);
                            const val_union = try decoder.decode(PropUnion);

                            if (std.mem.eql(u8, requested_iface.s, w.interface_name)) {
                                var found = false;
                                const struct_info = @typeInfo(T).@"struct";
                                inline for (struct_info.fields) |f| {
                                    if (!found and std.mem.eql(u8, f.name, prop_name.s)) {
                                        const FType = f.type;
                                        const type_info = @typeInfo(FType);
                                        const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_goose_property");
                                        const is_prop = is_wrapped or blk: {
                                            const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_goose_signal"));
                                            const is_conn = std.mem.eql(u8, f.name, "conn");
                                            const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                            break :blk !is_signal and !is_conn and !is_ptr;
                                        };
                                        const writable = if (is_wrapped) FType.AccessMode != .Read else false;

                                        if (is_prop) {
                                            if (writable) {
                                                if (std.meta.activeTag(val_union) == std.meta.stringToEnum(std.meta.Tag(PropUnion), f.name)) {
                                                    const new_val = @field(val_union, f.name);
                                                    if (is_wrapped) {
                                                        @field(self_obj, f.name).value = new_val;
                                                    } else {
                                                        @field(self_obj, f.name) = new_val;
                                                    }
                                                    found = true;

                                                    // Emit PropertiesChanged signal
                                                    {
                                                        const VariantType = Value.Variant(PropUnion);
                                                        var dict = std.StringHashMap(VariantType).init(conn.__allocator);
                                                        defer dict.deinit();

                                                        try dict.put(f.name, VariantType.new(@unionInit(PropUnion, f.name, new_val)));

                                                        const empty_strs = [_]GStr{};
                                                        const args = .{ GStr.new(w.interface_name), Value.Dict(GStr, VariantType, std.StringHashMap(VariantType)).new(dict), Value.Array(GStr).new(&empty_strs) };

                                                        var sig_encoder = try message.BodyEncoder.encode(conn.__allocator, args);
                                                        defer sig_encoder.deinit();

                                                        const serial = conn.serial_counter;
                                                        conn.serial_counter += 1;

                                                        const sig_header = core.MessageHeader{
                                                            .message_type = .Signal,
                                                            .flags = 0,
                                                            .proto_version = 1,
                                                            .body_length = @intCast(sig_encoder.body().len),
                                                            .serial = serial,
                                                            .header_fields = @constCast(&[_]core.HeaderField{
                                                                .{ .code = .Path, .value = .{ .Path = w.path } },
                                                                .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus.Properties" } },
                                                                .{ .code = .Member, .value = .{ .Member = "PropertiesChanged" } },
                                                                .{ .code = .Signature, .value = .{ .Signature = sig_encoder.signature() } },
                                                            }),
                                                        };

                                                        const sig_msg = core.Message.new(sig_header, sig_encoder.body());
                                                        try conn.sendMessage(sig_msg);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                if (found) {
                                    var encoder = try message.BodyEncoder.encode(conn.__allocator, .{}); // Void return;
                                    defer encoder.deinit();
                                    try conn.sendReply(msg, encoder);
                                }
                            }
                            return;
                        }
                    }

                    // Handle Introspect
                    if (iface_name) |iface| {
                        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
                            // Return XML
                            var encoder = try message.BodyEncoder.encode(conn.__allocator, GStr.new(w.intro_xml));
                            defer encoder.deinit();
                            try conn.sendReply(msg, encoder);
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
                                        try conn.sendReply(msg, encoder);
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

    pub fn sendReply(self: *Connection, m: core.Message, enc: message.BodyEncoder) !void {
        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 3);
        defer {
            for (reply_fields.items) |f| {
                switch (f.value) {
                    .Destination, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            reply_fields.deinit(self.__allocator);
        }
        try reply_fields.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });

        var dst: ?[:0]const u8 = null;
        for (m.header.header_fields) |f| if (f.code == .Sender) {
            dst = f.value.Sender;
        };
        if (dst) |d| {
            try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = try self.__allocator.dupeZ(u8, d) } });
        } else {
            std.debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
        }
        try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = try self.__allocator.dupeZ(u8, enc.signature()) } });

        const reply_h = core.MessageHeader{
            .message_type = .MethodReturn,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(enc.body().len),
            .serial = self.serial_counter,
            .header_fields = reply_fields.items,
        };
        self.serial_counter += 1;
        try self.sendMessage(core.Message.new(reply_h, enc.body()));
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
                    for (self.registered_interfaces.items) |*w| {
                        // Check path first
                        if (std.mem.eql(u8, w.path, p)) {
                            // Then check interface or Introspectable
                            if (iface) |i| {
                                if (std.mem.eql(u8, w.interface_name, i) or
                                    std.mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") or
                                    std.mem.eql(u8, i, "org.freedesktop.DBus.Properties"))
                                {
                                    // Dispatch
                                    try w.dispatch(w, self, msg);
                                    handled = true;
                                }
                            } else {
                                // Fallback dispatch
                                try w.dispatch(w, self, msg);
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

                                for (self.registered_interfaces.items) |*w| {
                                    if (std.mem.startsWith(u8, w.path, p)) {
                                        if (w.path.len > p.len) {
                                            var child_name: []const u8 = "";
                                            if (std.mem.eql(u8, p, "/")) {
                                                // Special case root
                                                if (w.path.len > 1) {
                                                    const sub = w.path[1..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            } else {
                                                // Check if w.path[p.len] == '/'
                                                if (w.path[p.len] == '/') {
                                                    const sub = w.path[p.len + 1 ..];
                                                    if (std.mem.indexOfScalar(u8, sub, '/')) |idx| {
                                                        child_name = sub[0..idx];
                                                    } else {
                                                        child_name = sub;
                                                    }
                                                }
                                            }

                                            if (child_name.len > 0) {
                                                if (seen_children.get(child_name) == null) {
                                                    try seen_children.put(child_name, {});
                                                    try children_xml.writer(self.__allocator).print("  <node name=\"{s}\"/>\n", .{child_name});
                                                }
                                            }
                                        }
                                    }
                                }

                                // Construct full XML
                                var full_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 1024);
                                defer full_xml.deinit(self.__allocator);
                                const xw = full_xml.writer(self.__allocator);
                                try xw.writeAll("<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
                                try xw.writeAll(" \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
                                try xw.writeAll("<node>\n");
                                try xw.writeAll(children_xml.items);
                                try xw.writeAll("</node>\n");

                                // Send Reply
                                const xml_slice = try full_xml.toOwnedSliceSentinel(self.__allocator, 0);
                                defer self.__allocator.free(xml_slice);

                                var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(xml_slice));
                                defer encoder.deinit();
                                try self.sendReply(msg, encoder);
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

        const reader: *std.io.Reader = self.__reader.interface();

        try reader.readSliceAll(&header_buf);

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
        try reader.readSliceAll(fields_bytes);

        // Align stream to 8 bytes
        const current_pos = 16 + fields_len;
        const padding = (8 - (current_pos % 8)) % 8;
        if (padding > 0) {
            try reader.discardAll(padding);
        }

        // Read body
        const body = try self.__allocator.alloc(u8, body_len);
        errdefer self.__allocator.free(body);
        try reader.readSliceAll(body);

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

        var freader = std.io.Reader.fixed(fields_bytes);

        while (freader.seek < fields_len) {
            const padding_f = (8 - (freader.seek % 8)) % 8;
            if (padding_f > 0) {
                try freader.discardAll(padding_f);
            }
            if (freader.seek >= fields_len) break;

            const code_u8 = try freader.takeByte();
            const code: core.HeaderFieldCode = if (code_u8 <= 9) @enumFromInt(code_u8) else .Invalid;

            // Variant signature (we assume standard fields have correct types)
            const sig_len = try freader.takeByte();
            try freader.discardAll(sig_len + 1); // sig + null

            switch (code) {
                .ReplySerial => {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const val = try freader.takeInt(u32, endian);
                    try fields_list.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = val } });
                },
                .UnixFds => {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const val = try freader.takeInt(u32, endian);
                    try fields_list.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = val } });
                },
                .Signature => {
                    const s_len = try freader.takeByte();
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readSliceAll(s_owned);
                    try freader.discardAll(1); // null
                    try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = s_owned } });
                },
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender => |c| {
                    const pad4 = (4 - (freader.seek % 4)) % 4;
                    try freader.discardAll(pad4);
                    const s_len = try freader.takeInt(u32, endian);
                    const s_owned = try self.__allocator.allocSentinel(u8, s_len, 0);
                    try freader.readSliceAll(s_owned);
                    try freader.discardAll(1); // null

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
