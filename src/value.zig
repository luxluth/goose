const std = @import("std");
const convertIntegrer = @import("utils.zig").convertInteger;

// String wrapper
pub const GStr = struct {
    s: [:0]const u8,
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

// ObjectPath wrapper
pub const GPath = struct {
    s: [:0]const u8,
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

// Signature wrapper
pub const GSig = struct {
    s: [:0]const u8,
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

// Unix fd wrapper
pub const GUFd = struct {
    fd: u32,
    pub fn new(fd: u32) @This() {
        return .{ .fd = fd };
    }
};

/// Represent a dbus value
pub const Value = struct {
    fn doesImplementSer(comptime T: type) bool {
        if (std.meta.hasMethod(T, "ser")) {
            const Args = std.meta.ArgsTuple(@TypeOf(T.ser));
            const fx = std.meta.fields(Args);
            return (fx.len == 2 and fx[0].type == T and fx[1].type == *std.ArrayList(u8));
        }

        return false;
    }

    fn reprLength(comptime T: type) comptime_int {
        var len = 0;
        if (T == GStr or T == GPath or T == GSig or T == GUFd) return 1;
        switch (@typeInfo(T)) {
            .int => |_| {
                len = 1;
            },
            .bool => {
                len = 1;
            },
            .float => |info| {
                if (info.bits != 64) {
                    @compileError("Only f64 are legible for the D-Bus data specification");
                }
                len = 1;
            },
            .@"struct" => |info| {
                for (info.fields) |field| {
                    len += reprLength(field.type);
                }

                if (!info.is_tuple) len += 2;
            },
            .@"union" => |_| {
                len = 1;
            },
            .array => |info| {
                len += 1 + reprLength(info.child);
            },
            .pointer => |info| {
                len += 1 + reprLength(info.child);
            },
            else => {
                @compileLog(@typeInfo(T));
                @compileError("connot get the signature length of this type");
            },
        }
        return len;
    }

    fn getRepr(comptime T: type, len: comptime_int, start: comptime_int, xs: *[len]u8) void {
        var real_start = start;

        if (T == GStr) {
            xs[real_start] = 's';
            return;
        } else if (T == GPath) {
            xs[real_start] = 'o';
            return;
        } else if (T == GSig) {
            xs[real_start] = 'g';
            return;
        } else if (T == GUFd) {
            xs[real_start] = 'h';
            return;
        }

        switch (@typeInfo(T)) {
            .comptime_int => {
                @compileError("unable to evaluate the size of a comptime_int");
            },
            .int => |info| {
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
            .float => {
                xs[real_start] = 'd';
            },
            .bool => {
                xs[real_start] = 'b';
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    xs[real_start] = '(';
                    real_start += 1;
                    xs[len - 1] = ')';
                }
                for (info.fields) |field| {
                    const ll = reprLength(field.type);
                    getRepr(field.type, ll, 0, xs[real_start..(real_start + ll)]);
                    real_start += ll;
                }
            },
            .array => |info| {
                xs[0] = 'a';
                getRepr(info.child, (xs.len - 1), 0, xs[1..]);
            },
            .pointer => |info| {
                xs[0] = 'a';
                getRepr(info.child, (xs.len - 1), 0, xs[1..]);
            },
            .@"union" => |_| {
                xs[real_start] = 'v';
            },
            else => {
                @compileError("unable to create a signature for this type");
            },
        }
    }

    /// Array
    pub fn Array(comptime T: type) type {
        // NOTE: using [1]T instead of []T because []T is a pointer
        const repr_len = reprLength([1]T);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr([1]T, repr_len, 1, &repr_arr);

        const rr = repr_arr;

        return struct {
            inner: []const T,
            repr: []const u8,
            const Self = @This();

            pub fn new(xs: []const T) Self {
                return Self{
                    .inner = xs,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, buffer: *std.ArrayList(u8)) !void {
                const array_data_length = @sizeOf(T) * self.inner.len;
                if (array_data_length > std.math.pow(u32, 2, 26))
                    return error.ArraySizeExceeded;
                const alignment = @alignOf(T);
                const padded_length = alignUp(array_data_length, alignment);
                const new_array = try buffer.addManyAsSlice(@sizeOf(u32) + padded_length);
                const len = new_array[0..4];
                len.* = &convertIntegrer(u32, array_data_length, .big);
            }

            fn alignUp(value: usize, alignment: usize) usize {
                return (value + alignment - 1) & ~(alignment - 1);
            }
        };
    }

    /// Tuple is a set of element. The order of is important
    /// `ivv` -> `INT32` `VARIANT` `VARIANT`
    pub fn Tuple(comptime T: type) type {
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("this structure is not a tuple");
                }
            },
            else => {
                @compileError("unexpected input type");
            },
        }

        const repr_len = reprLength(T);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr(T, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            inner: T,
            repr: []const u8,
            const Self = @This();

            pub fn new(structure: T) Self {
                return Self{
                    .inner = structure,
                    .repr = &rr,
                };
            }
        };
    }

    /// **CONTAINER**
    /// Entry in a dict or map (array of key-value pairs). Type code 101 'e' is
    /// reserved for use in bindings and implementations to represent the general
    /// concept of a dict or dict-entry, and must not appear in signatures used on D-Bus.
    pub fn Dict(comptime K: type, comptime V: type, comptime M: type) type {
        const key_repr_len = reprLength(K);
        const value_repr_len = reprLength(V);

        const total_len = value_repr_len + key_repr_len + 2;
        var rr = [_]u8{0} ** total_len;
        rr[0] = '{';
        rr[total_len - 1] = '}';

        getRepr(K, key_repr_len, 0, rr[1 .. key_repr_len + 1]);
        getRepr(V, value_repr_len, 0, rr[key_repr_len + 1 .. (total_len - 1)]);

        const repr_arr = rr;
        return struct {
            inner: M,
            repr: []const u8,
            const Self = @This();

            pub fn init(allocator: std.mem.Allocator) Self {
                return Self{
                    .repr = &repr_arr,
                    .inner = M.init(allocator),
                };
            }

            pub fn new(inner: M) Self {
                return Self{
                    .repr = &repr_arr,
                    .inner = inner,
                };
            }
        };
    }

    /// **CONTAINER**
    /// Variant type (the type of the value is part of the value itself)
    /// Only unions are accepted
    pub fn Variant(comptime T: type) type {
        switch (@typeInfo(T)) {
            .@"union" => |_| {
                if (!doesImplementSer(T)) {
                    @compileError("pub fn ser(" ++ @typeName(T) ++ ", *std.ArrayList(u8)) !void --- not found on " ++ @typeName(T) ++ " union.");
                }
                return struct {
                    inner: T,
                    repr: [:0]const u8,
                    const Self = @This();

                    pub fn new(any: T) Self {
                        return Self{
                            .inner = any,
                            .repr = "v",
                        };
                    }

                    pub fn ser(self: Self, buffer: *std.ArrayList(u8)) !void {
                        try self.inner.ser(buffer);
                    }
                };
            },
            else => @compileError("expected union as variant argument but found " ++ @typeName(T)),
        }
    }

    /// **CONTAINER**
    /// **Struct** type code 114 'r' is reserved for use in bindings and implementations
    /// to represent the general concept of a struct, and must not appear in signatures used on D-Bus.
    pub fn Struct(comptime S: type) type {
        if (@typeInfo(S) != .@"struct") {
            @compileError("unexpected input type");
        }
        const repr_len = reprLength(S);
        var repr_arr = [_]u8{0} ** (repr_len);
        getRepr(S, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            inner: S,
            repr: []const u8,
            const Self = @This();

            pub fn new(structure: S) Self {
                return Self{
                    .inner = structure,
                    .repr = &rr,
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
            repr: []const u8,
            const Self = @This();

            pub fn new(value: T) Self {
                return Self{
                    .value = value,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, list: *std.ArrayList(u8)) !void {
                switch (@typeInfo(T)) {
                    .int => {
                        const slice = convertIntegrer(T, self.value, .big);
                        try list.appendSlice(&slice);
                    },
                    else => {
                        try list.appendSlice(&std.mem.toBytes(self.value));
                    },
                }
            }
        };
    }

    fn StringLike(r: u8) type {
        const repr_len = 1;
        return struct {
            value: [:0]const u8,
            repr: []const u8,
            const Self = @This();

            pub fn new(value: [:0]const u8) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = r;
                return Self{
                    .value = value,
                    .repr = &repr_arr,
                };
            }

            pub fn ser(self: Self, list: *std.ArrayList(u8)) !void {
                const len: u32 = @intCast(self.value.len);
                switch (r) {
                    's' => {
                        try list.appendSlice(&convertIntegrer(u32, len, .big));
                        try list.appendSlice(self.value);
                        try list.append(0);
                    },
                    'o' => {
                        // TODO: check if is valid object path
                        try list.appendSlice(&convertIntegrer(u32, len, .big));
                        try list.appendSlice(self.value);
                        try list.append(0);
                    },
                    'g' => {
                        try list.append(@as(u8, @truncate(len)));
                        try list.appendSlice(self.value);
                        try list.append(0);
                    },
                    else => unreachable,
                }
            }
        };
    }

    /// Signed (two's complement) 16-bit integer
    pub fn Int16() type {
        return BasicType(i16);
    }

    /// Unsigned 16-bit integer
    pub fn Uint16() type {
        return BasicType(u16);
    }

    /// Signed (two's complement) 32-bit integer
    pub fn Int32() type {
        return BasicType(i32);
    }

    /// Unsigned 32-bit integer
    pub fn Uint32() type {
        return BasicType(u32);
    }

    /// Signed (two's complement) 64-bit integer (mnemonic: x and t are the first
    /// characters in "sixty" not already used for something more common)
    pub fn Int64() type {
        return BasicType(i64);
    }

    /// Unsigned 64-bit integer
    pub fn Uint64() type {
        return BasicType(u64);
    }

    /// IEEE 754 double-precision floating point
    pub fn Double() type {
        return BasicType(f64);
    }

    /// Unsigned 8-bit integer
    pub fn Byte() type {
        return BasicType(u8);
    }

    /// Boolean value: 0 is false, 1 is true, any other value allowed by the marshalling format is invalid
    /// It representation in the protocol is a `UINT32`
    pub fn Bool() type {
        const repr_len = reprLength(bool);
        var repr_arr = [_]u8{0} ** repr_len;
        getRepr(bool, repr_len, 0, &repr_arr);
        const rr = repr_arr;
        return struct {
            value: bool,
            repr: []const u8,
            const Self = @This();

            pub fn new(value: bool) Self {
                return Self{
                    .value = value,
                    .repr = &rr,
                };
            }

            pub fn ser(self: Self, list: *std.ArrayList(u8)) !void {
                const x: u32 = @intFromBool(self.value);
                try list.appendSlice(&convertIntegrer(u32, x, .big));
            }
        };
    }

    /// Unsigned 32-bit integer representing an index into an out-of-band array of
    /// file descriptors, transferred via some platform-specific mechanism (mnemonic: h for handle)
    pub fn UnixFd() type {
        const repr_len = reprLength(u32);
        return struct {
            handle: u32,
            repr: []const u8,
            const Self = @This();

            pub fn new(handle: u32) Self {
                var repr_arr = [_]u8{0} ** repr_len;
                repr_arr[0] = 'h';
                return Self{
                    .handle = handle,
                    .repr = &repr_arr,
                };
            }

            pub fn ser(self: Self, list: *std.ArrayList(u8)) !void {
                const slice = convertIntegrer(u32, self.value, .big);
                try list.appendSlice(&slice);
            }
        };
    }

    /// String-like types all end with a single zero (NUL) byte
    /// UTF-8 string (must be valid UTF-8)
    /// _Validity constraints_: No extra constraints
    pub fn String() type {
        return StringLike('s');
    }

    /// String-like types all end with a single zero (NUL) byte
    /// Name of an object instance
    /// _Validity constraints_: Must be a [syntactically valid object path](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-object-path)
    pub fn ObjectPath() type {
        return StringLike('o');
    }

    /// String-like types all end with a single zero (NUL) byte
    /// A type signature
    /// _Validity constraints_: Zero or more [single complete types](https://dbus.freedesktop.org/doc/dbus-specification.html#term-single-complete-type)
    pub fn Signature() type {
        return StringLike('g');
    }
};

pub const Serializer = struct {
    fn trySerialize(comptime T: type, data: T, buffer: *std.ArrayList(u8)) !void {
        if (T == GStr) {
            try Value.String().new(data).ser(buffer);
        } else if (T == GPath) {
            try Value.ObjectPath().new(data).ser(buffer);
        } else if (T == GSig) {
            try Value.Signature().new(data).ser(buffer);
        } else if (T == GUFd) {
            try Value.UnixFd().new(data).ser(buffer);
        } else {
            switch (@typeInfo(T)) {
                .int => |info| {
                    if (info.bits == 16) {
                        if (info.signedness == .signed) {
                            try Value.Int16().new(data).ser(buffer);
                        } else {
                            try Value.Uint16().new(data).ser(buffer);
                        }
                    } else if (info.bits == 32) {
                        if (info.signedness == .signed) {
                            try Value.Int32().new(data).ser(buffer);
                        } else {
                            try Value.Uint32().new(data).ser(buffer);
                        }
                    } else if (info.bits == 64) {
                        if (info.signedness == .signed) {
                            try Value.Int64().new(data).ser(buffer);
                        } else {
                            try Value.Uint64().new(data).ser(buffer);
                        }
                    } else if (info.bits == 8) {
                        if (info.signedness == .unsigned) {
                            try Value.Byte().new(data).ser(buffer);
                        } else {
                            return error.I8CannotBeSerialized;
                        }
                    }
                },
                .Float => |info| {
                    if (info.bits != 64) {
                        return error.F32CannotBeSerialized;
                    }
                    try Value.Double().new(data).ser(buffer);
                },
                .Bool => {
                    try Value.Bool().new(data).ser(buffer);
                },
            }
        }
    }
};

test "Signature Generation test" {
    const testing = std.testing;
    const allocator = std.testing.allocator;
    const eql = std.mem.eql;

    const Speed = struct {
        vel: f64,
        acc: u64,
        stopped: bool,
    };

    const Coord = struct {
        x: f64,
        y: f64,
        speed: Speed,
    };

    const TTag = enum { oneValue, twoValue, threeValue };
    const MulTup = union(TTag) {
        oneValue: std.meta.Tuple(&[_]type{i32}),
        twoValue: std.meta.Tuple(&[_]type{ i32, i32 }),
        threeValue: std.meta.Tuple(&[_]type{ i32, i32, i32 }),
    };

    const a = Value.Bool().new(false);
    try testing.expect(eql(u8, a.repr, "b"));

    const xs = Value.Array(i64).new(&[_]i64{ 1, 2, 3 });
    try testing.expect(eql(u8, xs.repr, "ax"));

    const c = Value.Double().new(3.0);
    try testing.expect(eql(u8, c.repr, "d"));

    const coord = Coord{
        .x = 98,
        .y = 199,
        .speed = .{
            .acc = 23,
            .stopped = false,
            .vel = 455,
        },
    };

    const t = Value.Struct(Coord).new(coord);
    try testing.expect(eql(u8, t.repr, "(dd(dtb))"));

    const cx = Value.Array(Coord).new(&[_]Coord{coord});
    try testing.expect(eql(u8, cx.repr, "a(dd(dtb))"));

    const tup = Value.Tuple(std.meta.Tuple(&[_]type{ f64, f64, f64 })).new(.{ 4, 4, 4 });
    try testing.expect(eql(u8, tup.repr, "ddd"));

    const va = Value.Variant(MulTup).new(.{ .threeValue = .{ 4, 4, 4 } });
    try testing.expect(eql(u8, va.repr, "v"));

    const dico = Value.Dict([:0]const u8, f64, std.StringHashMap(f64)).init(allocator);
    try testing.expect(eql(u8, dico.repr, "{sd}"));
}
