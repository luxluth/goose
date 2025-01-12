const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
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

/// Unsigned 8-bit integer
pub const TByte = struct {
    value: i8,
    __repr: u8 = 'y',
};

/// Boolean value: 0 is false, 1 is true, any other value allowed by the marshalling format is invalid
pub const TBool = struct {
    value: u1,
    __repr: u8 = 'b',
};

/// Signed (two's complement) 16-bit integer
pub const TInt16 = struct {
    value: i16,
    __repr: u8 = 'n',
};

/// Unsigned 16-bit integer
pub const TUint16 = struct {
    value: u16,
    __repr: u8 = 'q',
};

/// Signed (two's complement) 32-bit integer
pub const TInt32 = struct {
    value: i32,
    __repr: u8 = 'i',
};

/// Unsigned 32-bit integer
pub const TUint32 = struct {
    value: u32,
    __repr: u8 = 'u',
};

/// Signed (two's complement) 64-bit integer (mnemonic: x and t are the first
/// characters in "sixty" not already used for something more common)
pub const TInt64 = struct {
    value: i64,
    __repr: u8 = 'x',
};

/// Unsigned 64-bit integer
pub const TUint64 = struct {
    value: u64,
    __repr: u8 = 't',
};

/// IEEE 754 double-precision floating point
pub const TDouble = struct {
    value: f64,
    __repr: u8 = 'd',
};

/// Unsigned 32-bit integer representing an index into an out-of-band array of
/// file descriptors, transferred via some platform-specific mechanism (mnemonic: h for handle)
pub const TUnix_FD = struct {
    value: u32,
    __repr: u8 = 'h',
};

/// String-like types all end with a single zero (NUL) byte
/// _Validity constraints_: No extra constraints
pub const TString = struct {
    value: [:0]const u8,
    __repr: u8 = 's',
};

/// String-like types all end with a single zero (NUL) byte
/// _Validity constraints_: Must be a [syntactically valid object path](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-object-path)
pub const TObjectPath = struct {
    value: [:0]const u8,
    __repr: u8 = 'o',
};

/// String-like types all end with a single zero (NUL) byte
/// Zero or more [single complete types](https://dbus.freedesktop.org/doc/dbus-specification.html#term-single-complete-type)
pub const TSignature = struct {
    value: [:0]const u8,
    __repr: u8 = 'g',
};

pub const Ttype = enum {
    byte,
    bool,
    int16,
    uint16,
    int32,
    uint32,
    int64,
    uint64,
    double,
    unixFd,
    string,
};

pub const Value = union(Ttype) {
    string: TString,
    int: TInt,

    pub fn str(value: [:0]const u8) Value {
        return .{ .string = TString{ .value = value } };
    }

    pub fn int(value: i64) Value {
        return .{ .int = TInt{ .value = value } };
    }
};

pub const TMethod = struct {};

pub const Interface = struct {
    iface: [:0]const u8,
    properties: std.StringHashMap(Value),
    signals: std.StringHashMap(Value),
    methods: std.StringHashMap(Value),

    pub fn create(object: Object, iface: [:0]const u8) Interface {}
};

pub const Object = struct {
    name: [:0]const u8,
    conn: *DBusConnection,
    interfaces: std.StringHashMap(Interface),

    // pub fn addMethod(_: *Object) !void {}
    // pub fn addSignal(_: *Object) !void {}
    pub fn createInterface(self: *Object, iface: [:0]const u8) Interface {}
};

pub const DBusConnection = struct {
    handle: *c.DBusConnection,
    __name: ?[:0]const u8,
    __allocator: Allocator,

    pub const BusType = enum(c.DBusBusType) { Session = c.DBUS_BUS_SESSION, System = c.DBUS_BUS_SYSTEM, Starter = c.DBUS_BUS_STARTER };
    pub const Error = error{ UnableToEstablishConnection, NameAlreadyOwned, DBusConnectionNotConnected, UnableToCreateInterface };

    pub fn init(bus_type: BusType, allocator: Allocator) Error!DBusConnection {
        if (c.dbus_bus_get(@as(c.DBusBusType, @intFromEnum(bus_type)), null)) |conn| {
            return DBusConnection{
                .handle = conn,
                .__name = null,
                .__allocator = allocator,
            };
        } else {
            return Error.UnableToEstablishConnection;
        }
    }

    pub fn requestName(self: *DBusConnection, well_known_name: [:0]const u8) Error!void {
        const ret = c.dbus_bus_request_name(self.handle, well_known_name, c.DBUS_NAME_FLAG_DO_NOT_QUEUE, null);
        if (ret != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            return Error.NameAlreadyOwned;
        }

        self.__name = well_known_name;
    }

    pub fn createObject(self: *DBusConnection, name: [:0]const u8) Object {
        return Object{
            .name = name,
            .conn = self,
            .interfaces = std.StringHashMap(Interface).init(self.__allocator),
        };
    }

    pub fn waitForMessage(self: *DBusConnection) Error!void {
        if (c.dbus_connection_read_write_dispatch(self.handle, -1) == 0) {
            return Error.DBusConnectionNotConnected;
        }
    }

    pub fn deinit(_: *DBusConnection) void {}
};
