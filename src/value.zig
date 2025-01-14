const std = @import("std");

/// Represent a dbus value
pub const Value = struct {
    pub const Str = []const u8;

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

                if (!info.is_tuple) len += 2;
            },
            .Array => |info| {
                len += 1;
                len += reprLength(info.child);
            },
            .Pointer => |info| {
                if (info.child == u8 and info.size == .Slice and info.is_const and info.is_allowzero == false) {
                    len += 1;
                }
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
            .Array => |info| {
                xs[0] = 'a';
                getRepr(info.child, (xs.len - 1), 0, xs[1..]);
            },
            .Pointer => |info| {
                if (info.child == u8 and info.size == .Slice and info.is_const and info.is_allowzero == false) {
                    xs[real_start] = 's';
                }
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
        };
    }

    /// Tuple is a set of element. The order of appearance is important
    /// `ivv` -> `INT32` `VARIANT` `VARIANT`
    pub fn Tuple(comptime T: type) type {
        switch (@typeInfo(T)) {
            .Struct => |info| {
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

    /// Variant type (the type of the value is part of the value itself)
    pub fn Variant(comptime T: type) type {
        return struct {
            inner: T,
            repr: []const u8,
            const Self = @This();

            pub fn new(any: T) Self {
                return Self{
                    .inner = any,
                    .repr = "v",
                };
            }
        };
    }

    /// **Struct** type code 114 'r' is reserved for use in bindings and implementations
    /// to represent the general concept of a struct, and must not appear in signatures used on D-Bus.
    pub fn Struct(comptime S: type) type {
        if (@typeInfo(S) != .Struct) {
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
        };
    }

    fn StringLike(r: u8) type {
        const repr_len = 1;
        return struct {
            value: []const u8,
            repr: []const u8,
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
        return BasicType(bool);
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
                    .repr = repr_arr,
                };
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

    const Tup = std.meta.Tuple(&[_]type{ i32, i32, f64 });

    const a = Value.Bool().new(false);
    testing.expect(eql(u8, a.repr, "b"));

    const xs = Value.Array(i64).new(&[_]i64{ 1, 2, 3 });
    testing.expect(eql(u8, xs.repr, "ax"));

    const c = Value.Double().new(3.0);
    testing.expect(eql(u8, c.repr, "d"));

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
    testing.expect(eql(u8, t.repr, "(dd(dtb))"));

    const cx = Value.Array(Coord).new(&[_]Coord{coord});
    testing.expect(eql(u8, cx.repr, "a(dd(dtb))"));

    const tup = Value.Tuple(Tup).new(.{ 4, 4, 4 });
    testing.expect(eql(u8, tup.repr, "iid"));

    const va = Value.Variant(Tup).new(.{ 4, 4, 4 });
    testing.expect(eql(u8, va.repr, "v"));

    const dico = Value.Dict(Value.Str, f64, std.StringHashMap(f64)).init(allocator);
    testing.expect(eql(u8, dico.repr, "{sd}"));
}
