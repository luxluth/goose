const std = @import("std");
const net = std.Io.net;
const core = @import("core.zig");
const message = @import("message_utils.zig");
const common = @import("common.zig");
const dispatcher = @import("dispatcher.zig");
const xml_generator = @import("xml_generator.zig");
const Value = core.value.Value;
const GStr = core.value.GStr;
const GVariant = core.value.GVariant;
const DBusWriter = core.value.DBusWriter;

pub const CallState = enum(u32) {
    pending = 0,
    completed = 1,
    err = 2,
};

pub const PendingCall = struct {
    state: std.atomic.Value(u32) = .init(@backingInt(CallState.pending)),
    reply: ?core.Message = null,
};

pub fn MutexMap(comptime K: type, comptime V: type) type {
    return struct {
        map: std.AutoHashMap(K, V),
        mutex: std.Io.Mutex = .init,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) @This() {
            return .{
                .map = std.AutoHashMap(K, V).init(allocator),
                .io = io,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.map.deinit();
        }

        pub fn put(self: *@This(), key: K, value: V) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.map.put(key, value);
        }

        pub fn get(self: *@This(), key: K) ?V {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.get(key);
        }

        pub fn remove(self: *@This(), key: K) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.remove(key);
        }

        pub fn wakeAllWithError(self: *@This()) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.map.valueIterator();
            while (it.next()) |pending_ptr| {
                pending_ptr.*.state.store(@backingInt(CallState.err), .release);
                self.io.futexWake(u32, &pending_ptr.*.state.raw, 1);
            }
        }
    };
}

pub const MessageQueue = struct {
    list: std.ArrayList(core.Message),
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) @This() {
        return .{
            .list = .empty,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This(), conn: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.list.items) |*msg| {
            conn.freeMessage(msg);
        }
        self.list.deinit(self.allocator);
    }

    pub fn push(self: *@This(), msg: core.Message) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.list.append(self.allocator, msg);
        self.cond.signal(self.io);
    }

    pub fn popOrWait(self: *@This(), is_running: *std.atomic.Value(bool)) ?core.Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.list.items.len == 0) {
            if (!is_running.load(.acquire)) return null;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        return self.list.orderedRemove(0);
    }

    pub fn wakeAll(self: *@This()) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);
    }
};

/// Defines the concurrency/event-loop model for the connection.
pub const Backend = enum {
    threaded,
    poll,
};

/// Specifies the type of D-Bus connection.
pub const BusType = enum {
    /// The session bus (user-specific).
    Session,
    /// The system bus.
    System,
    /// The accessibility bus (AT-SPI).
    Accessibility,
};

pub const SocketReader = struct {
    interface: std.Io.Reader,
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    received_fds: std.ArrayList(std.posix.fd_t),

    pub fn init(fd: std.posix.fd_t, allocator: std.mem.Allocator, io: std.Io, buffer: []u8) !SocketReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .fd = fd,
            .allocator = allocator,
            .mutex = .init,
            .io = io,
            .received_fds = try .initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *SocketReader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.received_fds.items) |fd| {
            _ = std.posix.system.close(fd);
        }
        self.received_fds.deinit(self.allocator);
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [8]std.posix.iovec = undefined;
        const dest_n, const data_size = try io_r.writableVectorPosix(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];

        while (true) {
            const n = self.recvWithIovecs(dest) catch |err| switch (err) {
                error.WouldBlock => return error.ReadFailed,
                error.Interrupted => continue,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;

            if (n > data_size) {
                self.interface.end += n - data_size;
                return data_size;
            }
            return n;
        }
    }

    fn recvWithIovecs(self: *SocketReader, iov: []std.posix.iovec) !usize {
        const MaxFds = 32;
        const cmsg_align = @alignOf(usize);
        const cmsg_hdr_len = comptime std.mem.alignForward(usize, @sizeOf(std.c.cmsghdr), cmsg_align);
        const CmsgSpace = comptime cmsg_hdr_len + std.mem.alignForward(usize, MaxFds * @sizeOf(std.posix.fd_t), cmsg_align);
        var cmsg_buf: [CmsgSpace]u8 align(@alignOf(std.c.cmsghdr)) = undefined;

        var msg = std.posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = iov.ptr,
            .iovlen = iov.len,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };

        const flags: u32 = if (@hasDecl(std.posix.MSG, "CMSG_CLOEXEC")) std.posix.MSG.CMSG_CLOEXEC else 0;
        const rc = std.posix.system.recvmsg(self.fd, &msg, flags);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            if (err == .INTR) return error.Interrupted;
            if (err == .AGAIN) return error.WouldBlock;
            return error.ReadFailed;
        }
        const bytes_read: usize = @intCast(rc);
        if (bytes_read == 0) return 0;

        if (msg.controllen >= @sizeOf(std.c.cmsghdr) and msg.control != null) {
            var offset: usize = 0;
            while (offset + @sizeOf(std.c.cmsghdr) <= msg.controllen) {
                const cmsg: *const std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf[offset]));
                if (cmsg.len < @sizeOf(std.c.cmsghdr) or offset + cmsg.len > msg.controllen) break;

                if (cmsg.level == std.posix.SOL.SOCKET and cmsg.type == std.posix.SCM.RIGHTS) {
                    if (cmsg.len > cmsg_hdr_len) {
                        const data_len = cmsg.len - cmsg_hdr_len;
                        const fd_count = data_len / @sizeOf(std.posix.fd_t);
                        const fds_ptr: [*]const std.posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[offset + cmsg_hdr_len]));
                        self.mutex.lockUncancelable(self.io);
                        defer self.mutex.unlock(self.io);
                        for (0..fd_count) |i| {
                            const fd = fds_ptr[i];
                            if (flags == 0) {
                                _ = std.posix.system.fcntl(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
                            }
                            try self.received_fds.append(self.allocator, fd);
                        }
                    }
                }

                const cmsg_aligned = std.mem.alignForward(usize, cmsg.len, cmsg_align);
                if (cmsg_aligned == 0) break;
                offset += cmsg_aligned;
            }
        }
        return bytes_read;
    }
};

/// Represents a connection to a D-Bus bus (session or system).
/// Manages message sending, receiving, and object registration.
pub const Connection = struct {
    backend: Backend = .threaded,
    supports_unix_fd: bool = false,
    io: std.Io,
    __inner_sock: net.Stream,
    __allocator: std.mem.Allocator,
    __reader_buf: []u8,
    __reader: SocketReader,
    serial_counter: std.atomic.Value(u32) = .init(1),
    write_mutex: std.Io.Mutex = .init,
    pending_calls: MutexMap(u32, *PendingCall),
    dispatch_queue: MessageQueue,
    worker_init_mutex: std.Io.Mutex = .init,
    worker_thread: ?std.Thread = null,
    dispatch_thread: ?std.Thread = null,
    is_running: std.atomic.Value(bool),
    serve_futex: std.atomic.Value(u32),
    is_initialized: bool = false,
    signal_handlers_mutex: std.Io.Mutex = .init,
    signal_handlers: std.ArrayList(common.SignalHandler),
    registered_interfaces: std.ArrayList(common.InterfaceWrapper),

    pub fn nextSerial(self: *Connection) u32 {
        return self.serial_counter.fetchAdd(1, .monotonic);
    }

    /// Returns the underlying socket file descriptor for integration with external event loops.
    pub fn getFd(self: *const Connection) std.posix.fd_t {
        return self.__inner_sock.socket.handle;
    }

    /// Checks if there is pending data to read, either buffered in user-space or ready in the kernel socket.
    pub fn hasDataToRead(self: *Connection) bool {
        if (self.__reader.interface.end > self.__reader.interface.seek) {
            return true;
        }
        var pfd = [1]std.posix.pollfd{.{
            .fd = self.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&pfd, 0) catch return false;
        return n > 0 and (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    }

    /// Dispatches a single pending message if available without blocking.
    /// Returns true if a message was dispatched, false if no data was available.
    pub fn dispatch(self: *Connection) !bool {
        if (!self.hasDataToRead()) {
            return false;
        }

        const msg = try self.readNextMessage();
        if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
            var reply_serial: ?u32 = null;
            for (msg.header.header_fields) |f| {
                if (f.code == .ReplySerial) {
                    reply_serial = f.value.ReplySerial;
                    break;
                }
            }

            if (reply_serial) |serial| {
                if (self.pending_calls.get(serial)) |pending| {
                    pending.reply = msg;
                    pending.state.store(@backingInt(CallState.completed), .release);
                    self.io.futexWake(u32, &pending.state.raw, 1);
                    return true;
                }
            }
            self.freeMessage(@constCast(&msg));
            return true;
        }

        try self.dispatchUnsolicited(msg);
        return true;
    }

    fn sendmsgWithFds(self: *Connection, bytes: []const u8, fds: []const std.posix.fd_t) !void {
        var iov = [1]std.posix.iovec_const{.{
            .base = bytes.ptr,
            .len = bytes.len,
        }};

        const MaxFds = 32;
        if (fds.len > MaxFds) return error.TooManyFileDescriptors;

        const cmsg_align = @alignOf(usize);
        const cmsg_hdr_len = comptime std.mem.alignForward(usize, @sizeOf(std.c.cmsghdr), cmsg_align);
        const total_cmsg = cmsg_hdr_len + fds.len * @sizeOf(std.posix.fd_t);

        const CmsgSpace = comptime cmsg_hdr_len + std.mem.alignForward(usize, MaxFds * @sizeOf(std.posix.fd_t), cmsg_align);
        var cmsg_buf: [CmsgSpace]u8 align(@alignOf(std.c.cmsghdr)) = undefined;

        const cmsg: *std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
        cmsg.len = @intCast(total_cmsg);
        cmsg.level = std.posix.SOL.SOCKET;
        cmsg.type = std.posix.SCM.RIGHTS;

        const fds_dest: [*]std.posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_len]));
        for (fds, 0..) |f, i| {
            fds_dest[i] = f;
        }

        var msg = std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = total_cmsg,
            .flags = 0,
        };

        var sent_total: usize = 0;
        while (sent_total < bytes.len) {
            if (sent_total > 0) {
                msg.control = null;
                msg.controllen = 0;
            }
            iov[0].base = bytes.ptr + sent_total;
            iov[0].len = bytes.len - sent_total;

            const rc = std.posix.system.sendmsg(self.getFd(), &msg, 0);
            const err = std.posix.errno(rc);
            if (err != .SUCCESS) {
                if (err == .INTR) continue;
                if (err == .AGAIN) continue;
                return error.WriteFailed;
            }
            sent_total += @intCast(rc);
        }
    }

    fn writeMessageBytesWithFds(self: *Connection, bytes: []const u8, fds: []const std.posix.fd_t) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        if (fds.len > 0) {
            try self.sendmsgWithFds(bytes, fds);
        } else {
            var writer_buffer: [2048]u8 = undefined;
            var writer = self.__inner_sock.writer(self.io, &writer_buffer);
            var io_writer = &writer.interface;

            try io_writer.writeAll(bytes);
            try io_writer.flush();
        }
    }

    fn writeMessageBytes(self: *Connection, bytes: []const u8) !void {
        try self.writeMessageBytesWithFds(bytes, &.{});
    }

    fn auth(self: *Connection) !void {
        var io_reader = &self.__reader.interface;

        var writer_buffer: [2048]u8 = undefined;
        var writer = self.__inner_sock.writer(self.io, &writer_buffer);
        var io_writer = &writer.interface;

        const uid: u32 = @intCast(std.posix.system.getuid());
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

        try io_writer.print("NEGOTIATE_UNIX_FD\r\n", .{});
        try io_writer.flush();

        const fd_response = try io_reader.takeDelimiterInclusive('\n');
        if (std.mem.startsWith(u8, fd_response, "AGREE_UNIX_FD")) {
            self.supports_unix_fd = true;
        } else {
            self.supports_unix_fd = false;
        }

        try io_writer.print("BEGIN\r\n", .{});
        try io_writer.flush();
    }

    /// Initializes a new connection to the D-Bus bus using the default threaded backend.
    /// `bus_type`: The type of bus to connect to (.Session, .System, or .Accessibility).
    /// `io`: Mandatory [`std.Io`]
    /// `vars`: Environment variables provided from the entry point
    pub fn init(allocator: std.mem.Allocator, bus_type: BusType, io: std.Io, vars: *std.process.Environ.Map) !Connection {
        return initWithBackend(allocator, bus_type, io, vars, .threaded);
    }

    /// Initializes a new connection to the D-Bus bus with the specified backend (.threaded or .poll).
    pub fn initWithBackend(allocator: std.mem.Allocator, bus_type: BusType, io: std.Io, vars: *std.process.Environ.Map, backend: Backend) !Connection {
        var socket_paths: SocketIterator = undefined;
        var unix_addr: net.UnixAddress = undefined;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| allocator.free(p);

        switch (bus_type) {
            .Session => {
                const bus_address = vars.get("DBUS_SESSION_BUS_ADDRESS") orelse
                    return error.EnvVarNotFound;
                socket_paths = .init(bus_address);
            },
            .System => {
                if (vars.get("DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
                    socket_paths = .init(addr);
                } else {
                    socket_paths = .init("unix:path=/var/run/dbus/system_bus_socket");
                }
            },
            .Accessibility => {
                if (vars.get("AT_SPI_BUS_ADDRESS")) |addr| {
                    socket_paths = .init(addr);
                } else {
                    const uid = std.posix.system.getuid();
                    allocated_path = try std.fmt.allocPrint(allocator, "unix:path=/run/user/{d}/at-spi/bus_0", .{uid});
                    socket_paths = .init(allocated_path.?);
                }
            },
        }

        while (socket_paths.next()) |path| {
            unix_addr = net.UnixAddress.init(path) catch continue;
            break;
        } else {
            return error.NoValidAddressFound;
        }

        const reader_buf = try allocator.alloc(u8, 4096 * 10);
        errdefer allocator.free(reader_buf);

        const socket = try unix_addr.connect(io);

        var conn = Connection{
            .backend = backend,
            .supports_unix_fd = false,
            .__inner_sock = socket,
            .__allocator = allocator,
            .__reader_buf = reader_buf,
            .io = io,
            .serial_counter = .init(1),
            .write_mutex = .init,
            .pending_calls = .init(allocator, io),
            .dispatch_queue = .init(allocator, io),
            .worker_init_mutex = .init,
            .worker_thread = null,
            .dispatch_thread = null,
            .is_running = .init(false),
            .serve_futex = .init(0),
            .signal_handlers = try .initCapacity(allocator, 0),
            .registered_interfaces = try .initCapacity(allocator, 0),
            .__reader = try SocketReader.init(socket.socket.handle, allocator, io, reader_buf),
        };

        try conn.auth();

        conn.sayHello() catch |err| {
            conn.close();
            return err;
        };

        conn.is_initialized = true;
        conn.is_running.store(true, .release);
        return conn;
    }

    fn sayHello(self: *Connection) !void {
        const serial = self.nextSerial();

        const header = core.MessageHeader{
            .message_type = core.MessageType.MethodCall,
            .flags = @backingInt(core.MessageFlag.__EMPTY),
            .proto_version = 1,
            .body_length = 0,
            .serial = serial,
            .header_fields = @constCast(&[_]core.HeaderField{
                .{ .code = core.HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
                .{ .code = core.HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
                .{ .code = core.HeaderFieldCode.Member, .value = .{ .Member = "Hello" } },
            }),
        };

        const body = std.ArrayList(u8).empty;

        const msg = core.Message.new(header, body.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
    }

    /// This function closes the underlying socket and terminates background threads.
    pub fn close(self: *Connection) void {
        self.is_running.store(false, .release);
        self.dispatch_queue.wakeAll();

        self.__inner_sock.shutdown(self.io, .recv) catch {};
        self.__inner_sock.close(self.io);

        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }

        if (self.dispatch_thread) |thread| {
            thread.join();
            self.dispatch_thread = null;
        }

        self.serve_futex.store(1, .release);
        self.io.futexWake(u32, &self.serve_futex.raw, std.math.maxInt(u32));

        self.pending_calls.wakeAllWithError();
        self.pending_calls.deinit();
        self.dispatch_queue.deinit(self);

        self.signal_handlers.deinit(self.__allocator);

        for (self.registered_interfaces.items) |*wrapper| {
            wrapper.destroy(wrapper, self.__allocator);
        }
        self.registered_interfaces.deinit(self.__allocator);

        self.__reader.deinit();
        self.__allocator.free(self.__reader_buf);
    }

    const RequestNameFlags = enum(u32) {
        None = 0,
        AllowReplacement = 1,
        ReplaceExisting = 2,
        DoNotQueue = 4,
    };

    /// Requests a well-known name on the bus.
    pub fn requestName(self: *Connection, name: [:0]const u8) !void {
        const Str = Value.String();
        const U32 = Value.Uint32();

        const serial = self.nextSerial();

        var body_arr = try std.ArrayList(u8).initCapacity(self.__allocator, 256);
        defer body_arr.deinit(self.__allocator);

        var dwriter = DBusWriter.init(&body_arr, self.__allocator, .little);

        const flags =
            @backingInt(RequestNameFlags.DoNotQueue) |
            @backingInt(RequestNameFlags.ReplaceExisting);

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
            }),
        };

        const msg = core.Message.new(header, body_arr.items);
        var bytes = try msg.pack(self.__allocator);

        defer bytes.deinit(self.__allocator);
        var response = try self.call(bytes.items, serial);
        defer self.freeMessage(&response);
        if (response.header.message_type == .Error) {
            for (response.header.header_fields) |f| {
                if (f.code == .ErrorName) {
                    std.debug.print("[goose] RequestName failed with ErrorName: {s}\n", .{f.value.ErrorName});
                }
            }
        }
    }

    /// Sends a D-Bus message over the connection.
    pub fn sendMessage(self: *Connection, msg: core.Message) !void {
        var msg_to_pack = msg;
        var header_fields_copy: ?std.ArrayList(core.HeaderField) = null;
        defer if (header_fields_copy) |*hfc| hfc.deinit(self.__allocator);

        if (msg.fds.len > 0) {
            var has_unix_fds = false;
            for (msg.header.header_fields) |f| {
                if (f.code == .UnixFds) {
                    has_unix_fds = true;
                    break;
                }
            }
            if (!has_unix_fds) {
                var fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, msg.header.header_fields.len + 1);
                try fields.appendSlice(self.__allocator, msg.header.header_fields);
                try fields.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(msg.fds.len) } });
                msg_to_pack.header.header_fields = fields.items;
                header_fields_copy = fields;
            }
        }

        var bytes = try msg_to_pack.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);
        try self.writeMessageBytesWithFds(bytes.items, msg.fds);
    }

    /// Registers an object (interface implementation) at a specific path.
    /// The struct T must have an `init` method.
    /// `bus_name`: The well-known name to request on the bus.
    /// `path`: The object path to export this interface at.
    pub fn registerObject(self: *Connection, comptime T: type, bus_name: [:0]const u8, path: [:0]const u8, userData: anytype) !void {
        try self.requestName(bus_name);

        const interface_name = if (@hasDecl(T, "INTERFACE_NAME")) T.INTERFACE_NAME else if (@hasDecl(T, "REQUESTED_NAME")) T.REQUESTED_NAME else bus_name;

        // Instantiate
        var instance_ptr = try self.__allocator.create(T);
        // We assume init signature: fn init(conn: *Connection, userData: anytype) T
        instance_ptr.* = T.init(self, userData);

        // Bind signals
        // We iterate over fields. If a field is a Signal, we set its interface and path.
        const typeinfo = @typeInfo(T).@"struct";
        inline for (typeinfo.field_names, typeinfo.field_types) |field_name, field_type| {
            const FieldType = field_type;
            if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "__is_goose_signal")) {
                var sig = &@field(instance_ptr, field_name);
                sig.interface = interface_name;
                sig.path = path;
            }
        }

        // Generate Introspection XML
        const intro_xml = try xml_generator.generateIntrospectionXml(self.__allocator, T, interface_name);

        // Create wrapper
        const wrapper = common.InterfaceWrapper{
            .instance = @ptrCast(instance_ptr),
            .interface_name = interface_name,
            .path = path,
            .intro_xml = intro_xml,
            .destroy = struct {
                fn destroy(w: *const common.InterfaceWrapper, alloc: std.mem.Allocator) void {
                    const self_ptr = @as(*T, @ptrCast(@alignCast(w.instance)));
                    alloc.destroy(self_ptr);
                    alloc.free(w.intro_xml);
                }
            }.destroy,
            .dispatch = dispatcher.getDispatchFn(T),
        };

        try self.registered_interfaces.append(self.__allocator, wrapper);
    }

    /// Sends a reply to a method call.
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
            try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = try self.__allocator.dupeSentinel(u8, d, 0) } });
        } else {
            std.debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
        }
        try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = try self.__allocator.dupeSentinel(u8, enc.signature(), 0) } });

        const serial = self.nextSerial();
        const reply_h = core.MessageHeader{
            .message_type = .MethodReturn,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(enc.body().len),
            .serial = serial,
            .header_fields = reply_fields.items,
        };
        try self.sendMessage(core.Message.new(reply_h, enc.body()));
    }

    /// Sends a reply to a method call passing file descriptors.
    pub fn sendReplyWithFds(self: *Connection, m: core.Message, enc: message.BodyEncoder, fds: []const std.posix.fd_t) !void {
        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 4);
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
        if (fds.len > 0) {
            try reply_fields.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(fds.len) } });
        }

        const serial = self.nextSerial();
        const reply_h = core.MessageHeader{
            .message_type = .MethodReturn,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(enc.body().len),
            .serial = serial,
            .header_fields = reply_fields.items,
        };
        try self.sendMessage(core.Message.newWithFds(reply_h, enc.body(), fds));
    }

    /// Sends an Error reply to a message.
    pub fn sendError(self: *Connection, m: core.Message, error_name: [:0]const u8, error_msg: [:0]const u8) !void {
        var reply_fields = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 4);
        defer {
            for (reply_fields.items) |f| {
                switch (f.value) {
                    .Destination, .ErrorName, .Signature => |s| self.__allocator.free(s),
                    else => {},
                }
            }
            reply_fields.deinit(self.__allocator);
        }

        try reply_fields.append(self.__allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });
        try reply_fields.append(self.__allocator, .{ .code = .ErrorName, .value = .{ .ErrorName = try self.__allocator.dupeSentinel(u8, error_name, 0) } });

        var dst: ?[:0]const u8 = null;
        for (m.header.header_fields) |f| if (f.code == .Sender) {
            dst = f.value.Sender;
        };
        if (dst) |d| {
            try reply_fields.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = try self.__allocator.dupeSentinel(u8, d, 0) } });
        } else {
            std.debug.print("WARN: No Sender in request, error reply has no Destination!\n", .{});
        }

        var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(error_msg));
        defer encoder.deinit();

        try reply_fields.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = try self.__allocator.dupeSentinel(u8, encoder.signature(), 0) } });

        const serial = self.nextSerial();
        const reply_h = core.MessageHeader{
            .message_type = .Error,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(encoder.body().len),
            .serial = serial,
            .header_fields = reply_fields.items,
        };
        try self.sendMessage(core.Message.new(reply_h, encoder.body()));
    }

    pub fn ensureWorkersStarted(self: *Connection) !void {
        if (self.backend != .threaded) return;
        if (self.worker_thread != null) return;
        self.worker_init_mutex.lockUncancelable(self.io);
        defer self.worker_init_mutex.unlock(self.io);
        if (self.worker_thread == null) {
            self.is_running.store(true, .release);
            const dt = try std.Thread.spawn(.{}, dispatchLoop, .{self});
            errdefer {
                self.is_running.store(false, .release);
                self.dispatch_queue.wakeAll();
                dt.join();
            }
            self.dispatch_thread = dt;

            const wt = try std.Thread.spawn(.{}, workerLoop, .{self});
            self.worker_thread = wt;
        }
    }

    fn dispatchLoop(self: *Connection) void {
        while (self.is_running.load(.acquire)) {
            const msg = self.dispatch_queue.popOrWait(&self.is_running) orelse break;
            self.dispatchUnsolicited(msg) catch {};
        }
    }

    /// Runs the main loop, sleeping securely while background threads handle messages.
    pub fn serve(self: *Connection) !void {
        if (self.backend == .poll) {
            return error.InvalidBackend;
        }
        if (self.is_initialized) {
            try self.ensureWorkersStarted();
        }

        self.serve_futex.store(0, .release);
        while (self.is_running.load(.acquire)) {
            self.io.futexWaitUncancelable(u32, &self.serve_futex.raw, 0);
        }
    }

    fn dispatchUnsolicited(self: *Connection, msg: core.Message) !void {
        defer self.freeMessage(@constCast(&msg));

        if (msg.header.message_type == .Signal) {
            self.signal_handlers_mutex.lockUncancelable(self.io);
            defer self.signal_handlers_mutex.unlock(self.io);
            for (self.signal_handlers.items) |handler| {
                if (msg.isSignal(handler.interface, handler.member)) {
                    handler.callback(handler.ctx, msg);
                }
            }
            return;
        }

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
                var intro_interfaces: std.ArrayList(u8) = .empty;
                defer intro_interfaces.deinit(self.__allocator);

                for (self.registered_interfaces.items) |*w| {
                    // Check path first
                    if (std.mem.eql(u8, w.path, p)) {
                        // Then check interface or Introspectable
                        if (iface) |i| {
                            if (std.mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") and
                                member != null and std.mem.eql(u8, member.?, "Introspect"))
                            {
                                // Introspection needs a little special handling, because there may be multiple
                                // interfaces implemented by the object, and we have to return all of them.

                                if (intro_interfaces.items.len == 0)
                                    // Begin the XML if this is the first interface
                                    try intro_interfaces.appendSlice(self.__allocator, xml_generator.xml_prelude);

                                try intro_interfaces.appendSlice(self.__allocator, w.intro_xml);
                            } else if (std.mem.eql(u8, w.interface_name, i) or
                                std.mem.eql(u8, i, "org.freedesktop.DBus.Properties"))
                            {
                                // Dispatch
                                const dispatch_result = try w.dispatch(w, self, msg);
                                handled = dispatch_result == .dispatched;
                            }
                        } else {
                            // Fallback dispatch
                            const dispatch_result = try w.dispatch(w, self, msg);
                            handled = dispatch_result == .dispatched;
                        }
                    }
                }

                // Handle static introspection
                if (intro_interfaces.items.len != 0) {
                    // Wrap up the XML
                    try intro_interfaces.appendSlice(self.__allocator, xml_generator.xml_postlude);
                    const xml = try intro_interfaces.toOwnedSliceSentinel(self.__allocator, 0);
                    defer self.__allocator.free(xml);

                    var encoder = try message.BodyEncoder.encode(self.__allocator, GStr.new(xml));
                    defer encoder.deinit();
                    try self.sendReply(msg, encoder);
                    handled = true;
                }

                // Handle GetAll when no interfaces match
                if (!handled and
                    iface != null and std.mem.eql(u8, iface.?, "org.freedesktop.DBus.Properties") and
                    member != null and std.mem.eql(u8, member.?, "GetAll"))
                {
                    var dict = std.StringHashMap(GVariant).init(self.__allocator);
                    defer dict.deinit();
                    var encoder = try message.BodyEncoder.encode(self.__allocator, dict);
                    defer encoder.deinit();
                    try self.sendReply(msg, encoder);
                    handled = true;
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
                                                try children_xml.print(self.__allocator, "  <node name=\"{s}\"/>\n", .{child_name});
                                            }
                                        }
                                    }
                                }
                            }

                            // Construct full XML
                            var full_xml = try std.ArrayList(u8).initCapacity(self.__allocator, 1024);
                            defer full_xml.deinit(self.__allocator);
                            try full_xml.appendSlice(self.__allocator, "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
                            try full_xml.appendSlice(self.__allocator, " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
                            try full_xml.appendSlice(self.__allocator, "<node>\n");
                            try full_xml.appendSlice(self.__allocator, children_xml.items);
                            try full_xml.appendSlice(self.__allocator, "</node>\n");

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

    /// Registers interest in specific signals or messages using a D-Bus match rule.
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

    /// Performs a synchronous D-Bus method call.
    pub fn methodCall(
        self: *Connection,
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        member: [:0]const u8,
        signature: ?[:0]const u8,
        body: []const u8,
    ) !core.Message {
        return self.methodCallWithFds(dest, path, iface, member, signature, body, &.{});
    }

    /// Performs a synchronous D-Bus method call passing file descriptors.
    pub fn methodCallWithFds(
        self: *Connection,
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        member: [:0]const u8,
        signature: ?[:0]const u8,
        body: []const u8,
        fds: []const std.posix.fd_t,
    ) !core.Message {
        const serial = self.nextSerial();

        var fields_list = try std.ArrayList(core.HeaderField).initCapacity(self.__allocator, 6);
        defer fields_list.deinit(self.__allocator);

        try fields_list.append(self.__allocator, .{ .code = .Destination, .value = .{ .Destination = dest } });
        try fields_list.append(self.__allocator, .{ .code = .Path, .value = .{ .Path = path } });
        try fields_list.append(self.__allocator, .{ .code = .Interface, .value = .{ .Interface = iface } });
        try fields_list.append(self.__allocator, .{ .code = .Member, .value = .{ .Member = member } });

        if (signature) |sig| {
            try fields_list.append(self.__allocator, .{ .code = .Signature, .value = .{ .Signature = sig } });
        }
        if (fds.len > 0) {
            try fields_list.append(self.__allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(fds.len) } });
        }

        const header = core.MessageHeader{
            .message_type = .MethodCall,
            .flags = 0,
            .proto_version = 1,
            .body_length = @intCast(body.len),
            .serial = serial,
            .header_fields = fields_list.items,
        };

        const msg = core.Message.newWithFds(header, body, fds);
        var bytes = try msg.pack(self.__allocator);
        defer bytes.deinit(self.__allocator);

        return self.callWithFds(bytes.items, serial, fds);
    }

    /// Frees resources associated with a message.
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

        if (msg.allocator != null) {
            for (msg.fds) |fd| {
                if (fd >= 0) {
                    _ = std.posix.system.close(fd);
                }
            }
            if (msg.fds.len > 0) {
                self.__allocator.free(msg.fds);
            }
        }
        msg.fds = &.{};
    }

    /// Registers a callback for a specific D-Bus signal.
    pub fn registerSignalHandler(self: *Connection, interface: []const u8, member: []const u8, callback: *const fn (ctx: ?*anyopaque, msg: core.Message) void, ctx: ?*anyopaque) !void {
        self.signal_handlers_mutex.lockUncancelable(self.io);
        defer self.signal_handlers_mutex.unlock(self.io);
        try self.signal_handlers.append(self.__allocator, .{
            .interface = interface,
            .member = member,
            .callback = callback,
            .ctx = ctx,
        });
    }

    fn workerLoop(self: *Connection) void {
        while (self.is_running.load(.acquire)) {
            const msg = self.readNextMessage() catch |err| {
                if (!self.is_running.load(.acquire)) break;
                std.debug.print("workerLoop read error: {}\n", .{err});
                break;
            };

            if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                var reply_serial: ?u32 = null;
                for (msg.header.header_fields) |f| {
                    if (f.code == .ReplySerial) {
                        reply_serial = f.value.ReplySerial;
                        break;
                    }
                }

                if (reply_serial) |serial| {
                    if (self.pending_calls.get(serial)) |pending| {
                        pending.reply = msg;
                        pending.state.store(@backingInt(CallState.completed), .release);
                        self.io.futexWake(u32, &pending.state.raw, 1);
                    } else {
                        self.freeMessage(@constCast(&msg));
                    }
                } else {
                    self.freeMessage(@constCast(&msg));
                }
            } else {
                self.dispatch_queue.push(msg) catch |push_err| {
                    std.debug.print("workerLoop push error: {}\n", .{push_err});
                    self.freeMessage(@constCast(&msg));
                };
            }
        }

        self.is_running.store(false, .release);
        self.pending_calls.wakeAllWithError();
        self.dispatch_queue.wakeAll();
        self.serve_futex.store(1, .release);
        self.io.futexWake(u32, &self.serve_futex.raw, std.math.maxInt(u32));
    }

    fn readNextMessage(self: *Connection) !core.Message {
        var header_buf: [16]u8 = undefined;

        var io_reader = &self.__reader.interface;
        try io_reader.readSliceAll(&header_buf);

        const endian: std.builtin.Endian = switch (header_buf[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadEndianFlag,
        };
        const mtype: core.MessageType = @fromBackingInt(@intCast(header_buf[1]));
        const flags = header_buf[2];
        const version = header_buf[3];
        const body_len = std.mem.readInt(u32, header_buf[4..8], endian);
        const msg_serial = std.mem.readInt(u32, header_buf[8..12], endian);
        const fields_len = std.mem.readInt(u32, header_buf[12..16], endian);

        const fields_bytes = try self.__allocator.alloc(u8, fields_len);
        defer self.__allocator.free(fields_bytes);
        try io_reader.readSliceAll(fields_bytes);

        // Align stream to 8 bytes
        const current_pos = 16 + fields_len;
        const padding = (8 - (current_pos % 8)) % 8;
        if (padding > 0) {
            try io_reader.discardAll(padding);
        }

        // Read body
        const body = try self.__allocator.alloc(u8, body_len);
        errdefer self.__allocator.free(body);
        try io_reader.readSliceAll(body);

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

        var freader: std.Io.Reader = .fixed(fields_bytes);

        while (freader.seek < fields_len) {
            const padding_f = (8 - (freader.seek % 8)) % 8;
            if (padding_f > 0) {
                try freader.discardAll(padding_f);
            }
            if (freader.seek >= fields_len) break;

            const code_u8 = try freader.takeByte();
            const code: core.HeaderFieldCode = if (code_u8 <= 9) @fromBackingInt(@intCast(code_u8)) else .Invalid;

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

        var unix_fds_count: u32 = 0;
        for (fields_list.items) |f| {
            if (f.code == .UnixFds) {
                unix_fds_count = f.value.UnixFds;
                break;
            }
        }

        const header_fields = try fields_list.toOwnedSlice(self.__allocator);
        errdefer self.__allocator.free(header_fields);

        var msg_fds: []std.posix.fd_t = &.{};
        if (unix_fds_count > 0) {
            msg_fds = try self.__allocator.alloc(std.posix.fd_t, unix_fds_count);
            var fds_taken: usize = 0;
            errdefer {
                for (msg_fds[0..fds_taken]) |fd| {
                    _ = std.posix.system.close(fd);
                }
                self.__allocator.free(msg_fds);
            }
            self.__reader.mutex.lockUncancelable(self.io);
            defer self.__reader.mutex.unlock(self.io);
            for (0..unix_fds_count) |i| {
                if (self.__reader.received_fds.items.len > 0) {
                    msg_fds[i] = self.__reader.received_fds.orderedRemove(0);
                    fds_taken += 1;
                } else {
                    return error.MissingUnixFds;
                }
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
                .header_fields = header_fields,
            },
            .body = body,
            .fds = msg_fds,
            .allocator = self.__allocator,
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
        return self.callWithFds(data, serial, &.{});
    }

    fn callWithFds(self: *Connection, data: []u8, serial: u32, fds: []const std.posix.fd_t) !core.Message {
        var pending = PendingCall{};

        try self.pending_calls.put(serial, &pending);
        defer _ = self.pending_calls.remove(serial);

        if (self.is_initialized) {
            try self.ensureWorkersStarted();
        }

        try self.writeMessageBytesWithFds(data, fds);

        if (self.backend == .poll or self.worker_thread == null) {
            while (true) {
                if (pending.reply) |r| {
                    return r;
                }
                const msg = try self.readNextMessage();
                if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
                    var reply_serial: ?u32 = null;
                    for (msg.header.header_fields) |f| {
                        if (f.code == .ReplySerial) {
                            reply_serial = f.value.ReplySerial;
                            break;
                        }
                    }
                    if (reply_serial != null and reply_serial.? == serial) {
                        return msg;
                    }
                    if (reply_serial) |rserial| {
                        if (self.pending_calls.get(rserial)) |p| {
                            p.reply = msg;
                            p.state.store(@backingInt(CallState.completed), .release);
                            continue;
                        }
                    }
                    self.freeMessage(@constCast(&msg));
                    continue;
                }
                self.dispatchUnsolicited(msg) catch {};
            }
        }

        while (pending.state.load(.acquire) == @backingInt(CallState.pending)) {
            self.io.futexWaitUncancelable(u32, &pending.state.raw, @backingInt(CallState.pending));
        }

        if (pending.state.load(.acquire) == @backingInt(CallState.err)) {
            return error.ConnectionClosed;
        }

        if (pending.reply) |r| {
            return r;
        } else {
            return error.CallFailed;
        }
    }
};

const SocketIterator = struct {
    inner: std.mem.TokenIterator(u8, .scalar),

    fn init(address: []const u8) SocketIterator {
        return .{ .inner = std.mem.tokenizeScalar(u8, address, ';') };
    }

    fn next(self: *SocketIterator) ?[]const u8 {
        const prefix = "unix:";
        const param = "path=";

        while (self.inner.next()) |token| {
            if (!std.mem.startsWith(u8, token, prefix))
                continue;

            var params = std.mem.tokenizeScalar(u8, token[prefix.len..], ',');
            while (params.next()) |pair| {
                if (std.mem.startsWith(u8, pair, param))
                    return pair[param.len..];
            }
        }

        return null;
    }
};
