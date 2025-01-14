const std = @import("std");

/// Unsigned 8-bit integer
pub const TByte = struct {
    value: u8,
    __repr: u8 = 'y',
};

/// Boolean value: 0 is false, 1 is true, any other value allowed by the marshalling format is invalid
pub const TBool = struct {
    value: u32,
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
/// UTF-8 string (must be valid UTF-8)
/// _Validity constraints_: No extra constraints
pub const TString = struct {
    value: [:0]const u8,
    __repr: u8 = 's',
};

/// String-like types all end with a single zero (NUL) byte
/// Name of an object instance
/// _Validity constraints_: Must be a [syntactically valid object path](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-object-path)
pub const TObjectPath = struct {
    value: [:0]const u8,
    __repr: u8 = 'o',
};

/// String-like types all end with a single zero (NUL) byte
/// A type signature
/// _Validity constraints_: Zero or more [single complete types](https://dbus.freedesktop.org/doc/dbus-specification.html#term-single-complete-type)
pub const TSignature = struct {
    value: [:0]const u8,
    __repr: u8 = 'g',
};

pub const ValueTag = enum {
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
    objectPath,
    signature,

    struc,
    variant,
    array,
    dict,

    tuple,
};

/// **Struct** type code 114 'r' is reserved for use in bindings and implementations
/// to represent the general concept of a struct, and must not appear in signatures used on D-Bus.
pub const TStruct = struct {
    fields: []const *Value,
};

/// Variant type (the type of the value is part of the value itself)
pub const TVariant = struct {
    value: *Value,
    __repr: u8 = 'v',
};

/// Array
pub const TArray = struct {
    values: []const *Value,
    of: ValueTag,
    __repr: u8 = 'a',
};

/// Entry in a dict or map (array of key-value pairs). Type code 101 'e' is
/// reserved for use in bindings and implementations to represent the general
/// concept of a dict or dict-entry, and must not appear in signatures used on D-Bus.
pub const TDict = struct {
    pub const Entry = struct {
        key: Value,
        value: Value,
    };

    of: [2]ValueTag,
    pairs: []const *Entry,
};

/// Tuple is a set of element. The order of appearance is important
/// `ivv` -> `INT32` `VARIANT` `VARIANT`
pub const TTuple = struct {
    of: []const ValueTag,
    values: []const *Value,
};

/// Represent a dbus value
pub const Value = union(ValueTag) {
    byte: TByte,
    bool: TBool,
    int16: TInt16,
    uint16: TUint16,
    int32: TInt32,
    uint32: TUint32,
    int64: TInt64,
    uint64: TUint64,
    double: TDouble,
    unixFd: TUnix_FD,

    string: TString,
    objectPath: TObjectPath,
    signature: TSignature,

    struc: TStruct,
    variant: TVariant,
    array: TArray,
    dict: TDict,

    tuple: TTuple,

    fn reprLength(comptime T: type) comptime_int {
        var len = 0;
        switch (@typeInfo(T)) {
            .Int => |_| {
                len = 1;
            },
            .Bool => {
                len = 1;
            },
            .Float => |info| {
                if (info.bits != 64) {
                    @compileError("Only f64 are legible for the D-Bus data specification");
                }
                len = 1;
            },
            .Struct => |info| {
                for (info.fields) |field| {
                    len += reprLength(field.type);
                }
                len += 2;
            },
            else => {
                @compileError("connot get the signature length of this type");
            },
        }
        return len;
    }

    fn getRepr(comptime T: type, len: comptime_int, start: comptime_int, xs: *[len]u8) void {
        var real_start = start;
        switch (@typeInfo(T)) {
            .ComptimeInt => {
                @compileError("unable to evaluate the size of a comptime_int");
            },
            .Int => |info| {
                switch (info.bits) {
                    1 => {
                        @compileError("if you want to create a boolean value, use a bool instead of i1");
                    },
                    8 => {
                        xs[real_start] = switch (info.signedness) {
                            .unsigned => 'y',
                            else => @compileError("i8 is not part of the D-Bus data specification"),
                        };
                    },
                    16 => {
                        xs[real_start] = switch (info.signedness) {
                            .unsigned => 'q',
                            .signed => 'n',
                        };
                    },
                    32 => {
                        xs[real_start] = switch (info.signedness) {
                            .unsigned => 'u',
                            .signed => 'i',
                        };
                    },
                    64 => {
                        xs[real_start] = switch (info.signedness) {
                            .unsigned => 't',
                            .signed => 'x',
                        };
                    },
                    else => {
                        @compileError("unsupported data type by the D-Bus specification");
                    },
                }
            },
            .Float => {
                xs[real_start] = 'd';
            },
            .Bool => {
                xs[real_start] = 'b';
            },
            .Struct => |info| {
                xs[real_start] = '(';
                real_start += 1;
                xs[len - 1] = ')';
                for (info.fields) |field| {
                    const ll = reprLength(field.type);
                    getRepr(field.type, ll, 0, xs[real_start..(real_start + ll)]);
                    real_start += ll;
                }
            },
            else => {
                @compileError("unable to create a signature for this type");
            },
        }
    }

    pub fn Array(comptime T: type) type {
        const repr_len = reprLength(T);
        var repr_arr = [_]u8{0} ** (repr_len + 1);
        repr_arr[0] = 'a';
        getRepr(T, repr_len + 1, 1, &repr_arr);

        const rr = repr_arr;

        return struct {
            inner: []const T,
            repr: [repr_len + 1]u8,
            const Self = @This();

            pub fn new(xs: []const T) Self {
                return Self{
                    .inner = xs,
                    .repr = rr,
                };
            }
        };
    }

    // pub fn Tuple(comptime T: type) type {
    //     return .{ .tuple = .{ .of = of, .values = values } };
    // }

    // pub fn Dict(of: [2]ValueTag, values: []const *TDict.Entry) Value {
    //     return .{ .dict = .{ .of = of, .values = values } };
    // }
    //
    // pub fn Variant(value: *Value) Value {
    //     return .{ .variant = .{ .value = value } };
    // }
    //
    pub fn Struct(comptime S: type) type {
        const repr_len = reprLength(S);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr(S, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            inner: S,
            repr: [repr_len]u8,
            const Self = @This();

            pub fn new(structure: S) Self {
                return Self{
                    .inner = structure,
                    .repr = rr,
                };
            }
        };
    }

    fn BasicType(comptime T: type) type {
        const repr_len = reprLength(T);
        var repr_arr = [_]u8{0} ** repr_len;
        getRepr(T, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            value: T,
            repr: [repr_len]u8,
            const Self = @This();

            pub fn new(value: T) Self {
                return Self{
                    .value = value,
                    .repr = rr,
                };
            }
        };
    }

    fn StringLike(r: u8) type {
        const repr_len = 1;
        return struct {
            value: [:0]const u8,
            repr: [repr_len]u8,
            const Self = @This();

            pub fn new(value: [:0]const u8) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = r;
                return Self{
                    .value = value,
                    .repr = repr_arr,
                };
            }
        };
    }

    pub fn Int16() type {
        return BasicType(i16);
    }

    pub fn Uint16() type {
        return BasicType(u16);
    }

    pub fn Int32() type {
        return BasicType(i32);
    }

    pub fn Uint32() type {
        return BasicType(u32);
    }

    pub fn Int64() type {
        return BasicType(i64);
    }

    pub fn Uint64() type {
        return BasicType(u64);
    }

    pub fn Double() type {
        return BasicType(f64);
    }

    pub fn Byte() type {
        return BasicType(u8);
    }

    pub fn Bool() type {
        return BasicType(bool);
    }

    pub fn UnixFd() type {
        const repr_len = reprLength(u32);
        return struct {
            handle: u32,
            repr: [repr_len]u8,
            const Self = @This();

            pub fn new(handle: u32) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = 'h';
                return Self{
                    .handle = handle,
                    .repr = repr_arr,
                };
            }
        };
    }

    pub fn String() type {
        return StringLike('s');
    }

    pub fn ObjectPath() type {
        return StringLike('o');
    }

    pub fn Signature() type {
        return StringLike('g');
    }
};
