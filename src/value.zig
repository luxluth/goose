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

    pub fn tuple(of: []const ValueTag, values: []const *Value) Value {
        return .{ .tuple = .{ .of = of, .values = values } };
    }

    pub fn dict(of: [2]ValueTag, values: []const *TDict.Entry) Value {
        return .{ .dict = .{ .of = of, .values = values } };
    }

    pub fn array(of: ValueTag, values: []const *Value) Value {
        return .{ .array = .{ .of = of, .values = values } };
    }

    pub fn variant(value: *Value) Value {
        return .{ .variant = .{ .value = value } };
    }

    pub fn struc(fields: []const *Value) Value {
        return .{ .struc = .{ .fields = fields } };
    }

    pub fn byte(value: u8) Value {
        return .{ .byte = .{ .value = value } };
    }

    pub fn @"bool"(value: bool) Value {
        return .{ .bool = .{ .value = @intFromBool(value) } };
    }

    pub fn int16(value: i16) Value {
        return .{ .int16 = .{ .value = value } };
    }

    pub fn uint16(value: u16) Value {
        return .{ .uint16 = .{ .value = value } };
    }

    pub fn int32(value: i32) Value {
        return .{ .int32 = .{ .value = value } };
    }

    pub fn uint32(value: u32) Value {
        return .{ .uint32 = .{ .value = value } };
    }

    pub fn int64(value: i64) Value {
        return .{ .int64 = .{ .value = value } };
    }

    pub fn uint64(value: u64) Value {
        return .{ .uint64 = .{ .value = value } };
    }

    pub fn double(value: f64) Value {
        return .{ .double = .{ .value = value } };
    }

    pub fn unixFd(value: u32) Value {
        return .{ .unixFd = .{ .value = value } };
    }

    pub fn string(value: [:0]const u8) Value {
        return .{ .string = .{ .value = value } };
    }

    pub fn objectPath(value: [:0]const u8) Value {
        return .{ .objectPath = .{ .value = value } };
    }

    pub fn signature(value: [:0]const u8) Value {
        return .{ .signature = .{ .value = value } };
    }

    pub fn repr(
        self: Value,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(allocator);

        switch (self) {
            .byte => |value| {
                buffer.append(value.__repr);
            },
            .bool => |value| {
                buffer.append(value.__repr);
            },
            .int16 => |value| {
                buffer.append(value.__repr);
            },
            .uint16 => |value| {
                buffer.append(value.__repr);
            },
            .int32 => |value| {
                buffer.append(value.__repr);
            },
            .uint32 => |value| {
                buffer.append(value.__repr);
            },
            .int64 => |value| {
                buffer.append(value.__repr);
            },
            .uint64 => |value| {
                buffer.append(value.__repr);
            },
            .double => |value| {
                buffer.append(value.__repr);
            },
            .unixFd => |value| {
                buffer.append(value.__repr);
            },

            .string => |value| {
                buffer.append(value.__repr);
            },
            .objectPath => |value| {
                buffer.append(value.__repr);
            },
            .signature => |value| {
                buffer.append(value.__repr);
            },

            .struc => |value| {
                buffer.append('(');
                for (value.fields) |field| {
                    const parts = try field.repr(allocator);
                    defer parts.deinit();
                    for (parts.items) |part| buffer.append(part);
                }
                buffer.append(')');
            },
            .variant => |value| {
                buffer.append(value.__repr);
            },
            .array => |ar| {
                // aTYPE -> TYPE: signature of the types in it
                buffer.append('a');
                if (ar.of == ValueTag.array or ar.of == ValueTag.dict or ar.of == ValueTag.tuple or ar.of == ValueTag.struc) {} else {}
                unreachable;
            },
            .dict => |_| {
                unreachable;
                // {kEY_TYPEvALUE_TYPE} -> kEY_TYPE: key of the value,
                // -> vALUE_TYPE: type of the value
            },

            .tuple => |value| {
                for (value.values) |field| {
                    const parts = try field.repr(allocator);
                    defer parts.deinit();
                    for (parts.items) |part| buffer.append(part);
                }
            },
        }

        return buffer;
    }
};
