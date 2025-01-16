const std = @import("std");
const c = @import("c.zig").c;
pub const value = @import("value.zig");

const Value = value.Value;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const DBusError = struct {
    name: ?*const u8, // nullable pointer to a const u8 for the error name
    message: ?*const u8, // nullable pointer to a const u8 for the error message

    // Using a packed struct for bit fields
    packed_bits: packed struct {
        dummy1: u1, // 1-bit field
        dummy2: u1, // 1-bit field
        dummy3: u1, // 1-bit field
        dummy4: u1, // 1-bit field
        dummy5: u1, // 1-bit field
    },

    padding1: ?*anyopaque, // nullable pointer for the placeholder padding
};

pub const Interface = struct {
    iface: [:0]const u8,
    properties: std.StringHashMap(Value),
    signals: std.StringHashMap(Value),
    methods: std.StringHashMap(Value),

    pub fn create(_: Object, _: [:0]const u8) Interface {}
};

pub const Object = struct {
    name: [:0]const u8,
    conn: *Connection,
    interfaces: std.StringHashMap(Interface),

    // pub fn addMethod(_: *Object) !void {}
    // pub fn addSignal(_: *Object) !void {}
    pub fn createInterface(_: *Object, _: [:0]const u8) Interface {}
};

pub const Connection = struct {
    handle: *c.DBusConnection,
    __name: ?[:0]const u8,
    __allocator: Allocator,

    pub const BusType = enum(c.DBusBusType) {
        Session = c.DBUS_BUS_SESSION,
        System = c.DBUS_BUS_SYSTEM,
        Starter = c.DBUS_BUS_STARTER,
    };

    pub const Error = error{
        UnableToEstablishConnection,
        NameAlreadyOwned,
        DBusConnectionNotConnected,
        UnableToCreateInterface,
    };

    pub fn init(allocator: Allocator, bus_type: BusType) Error!Connection {
        if (c.dbus_bus_get(@as(c.DBusBusType, @intFromEnum(bus_type)), null)) |conn| {
            return Connection{
                .handle = conn,
                .__name = null,
                .__allocator = allocator,
            };
        } else {
            return Error.UnableToEstablishConnection;
        }
    }

    pub fn requestName(self: *Connection, well_known_name: [:0]const u8) Error!void {
        const ret = c.dbus_bus_request_name(
            self.handle,
            well_known_name,
            c.DBUS_NAME_FLAG_DO_NOT_QUEUE,
            null,
        );
        if (ret != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            return Error.NameAlreadyOwned;
        }

        self.__name = well_known_name;
    }

    pub fn createObject(self: *Connection, name: [:0]const u8) Object {
        return Object{
            .name = name,
            .conn = self,
            .interfaces = std.StringHashMap(Interface).init(self.__allocator),
        };
    }

    pub fn waitForMessage(self: *Connection) Error!void {
        if (c.dbus_connection_read_write_dispatch(self.handle, -1) == 0) {
            return Error.DBusConnectionNotConnected;
        }
    }

    pub fn deinit(_: *Connection) void {}
};
