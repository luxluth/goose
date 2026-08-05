const std = @import("std");
const core = @import("core.zig");
const Value = core.value.Value;
const GVariant = core.value.GVariant;
const DBusWriter = core.value.DBusWriter;
const Serializer = core.value.Serializer;
const dbusAlignOf = core.value.dbusAlignOf;

/// Helper to encode a set of values into a D-Bus message body.
pub const BodyEncoder = struct {
    allocator: std.mem.Allocator,
    body_list: std.ArrayList(u8),
    signature_list: std.ArrayList(u8),
    endian: std.builtin.Endian,

    /// Encodes a single value or a tuple of values into a new BodyEncoder.
    pub fn encode(allocator: std.mem.Allocator, values: anytype) !BodyEncoder {
        var self = BodyEncoder{
            .allocator = allocator,
            .body_list = try std.ArrayList(u8).initCapacity(allocator, 256),
            .signature_list = try std.ArrayList(u8).initCapacity(allocator, 32),
            .endian = .little,
        };
        errdefer self.deinit();

        const T = @TypeOf(values);
        const type_info = @typeInfo(T);

        if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
            inline for (values) |v| {
                try self.appendValue(v);
            }
        } else {
            try self.appendValue(values);
        }

        // Ensure signature is null-terminated
        try self.signature_list.append(allocator, 0);

        return self;
    }

    /// Releases resources used by the encoder.
    pub fn deinit(self: *BodyEncoder) void {
        self.body_list.deinit(self.allocator);
        self.signature_list.deinit(self.allocator);
    }

    fn appendValue(self: *BodyEncoder, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == void) return;
        const sig_len = Value.reprLength(T);
        var sig_buf: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, sig_buf[0..sig_len]);
        try self.signature_list.appendSlice(self.allocator, sig_buf[0..sig_len]);

        var writer = DBusWriter.init(&self.body_list, self.allocator, self.endian);
        try writer.padTo(dbusAlignOf(T));
        try Serializer.trySerialize(T, value, &writer);
    }

    /// Returns the encoded body bytes.
    pub fn body(self: BodyEncoder) []const u8 {
        return self.body_list.items;
    }

    /// Returns the generated signature string.
    pub fn signature(self: BodyEncoder) [:0]const u8 {
        return self.signature_list.items[0 .. self.signature_list.items.len - 1 :0];
    }
};

/// Helper to decode values from a D-Bus message body according to its signature.
pub const BodyDecoder = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    signature: []const u8,
    pos: usize,
    sig_pos: usize,
    endian: std.builtin.Endian,

    /// Initializes a decoder with raw body and signature.
    pub fn init(allocator: std.mem.Allocator, body: []const u8, signature: []const u8, endian: std.builtin.Endian) BodyDecoder {
        return .{
            .allocator = allocator,
            .body = body,
            .signature = signature,
            .pos = 0,
            .sig_pos = 0,
            .endian = endian,
        };
    }

    /// Initializes a decoder from a Message, extracting the signature from header fields.
    pub fn fromMessage(allocator: std.mem.Allocator, msg: core.Message) BodyDecoder {
        var sig: []const u8 = "";
        for (msg.header.header_fields) |field| {
            if (field.code == .Signature) {
                sig = field.value.Signature;
                break;
            }
        }

        return .{
            .allocator = allocator,
            .body = msg.body,
            .signature = sig,
            .pos = 0,
            .sig_pos = 0,
            .endian = msg.header.endianess,
        };
    }

    fn alignTo(self: *BodyDecoder, alignment: usize) void {
        const rem = self.pos % alignment;
        if (rem != 0) {
            self.pos += (alignment - rem);
        }
    }

    /// Decodes the next value of type T from the body.
    /// Returns error.SignatureMismatch if the body signature doesn't match T's D-Bus representation.
    pub fn decode(self: *BodyDecoder, comptime T: type) anyerror!T {
        const sig_len = Value.reprLength(T);
        var expected_sig: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

        if (self.sig_pos + sig_len > self.signature.len) return error.SignatureEnd;
        if (!std.mem.eql(u8, self.signature[self.sig_pos .. self.sig_pos + sig_len], expected_sig[0..sig_len])) {
            return error.SignatureMismatch;
        }
        self.sig_pos += sig_len;

        self.alignTo(dbusAlignOf(T));

        return self.readVal(T, false);
    }

    /// Decodes the next value of type T and allocates memory for it (recursive deep-copy).
    /// This allows the returned value to outlive the decoder and the message body.
    pub fn decodeAlloc(self: *BodyDecoder, comptime T: type) anyerror!T {
        const sig_len = Value.reprLength(T);
        var expected_sig: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

        if (self.sig_pos + sig_len > self.signature.len) return error.SignatureEnd;
        if (!std.mem.eql(u8, self.signature[self.sig_pos .. self.sig_pos + sig_len], expected_sig[0..sig_len])) {
            return error.SignatureMismatch;
        }
        self.sig_pos += sig_len;

        self.alignTo(dbusAlignOf(T));

        return self.readVal(T, true);
    }

    fn readVal(self: *BodyDecoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
        if (comptime Value.isDict(T)) {
            const byte_len = try self.readVal(u32, false);
            self.alignTo(8);

            const start_pos = self.pos;
            if (self.pos + byte_len > self.body.len) return error.EndOfBody;

            var map = T.init(self.allocator);
            errdefer map.deinit();

            while (self.pos - start_pos < byte_len) {
                self.alignTo(8);
                const kv = Value.dictKV(T);
                const K = kv.key;
                const V = kv.val;
                const key = if (K == []const u8 or K == [:0]const u8 or K == []u8 or K == [:0]u8) blk: {
                    if (self.pos + 4 > self.body.len) return error.EndOfBody;
                    const len = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                    self.pos += 4;
                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;
                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;
                    if (deep_copy) {
                        const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        break :blk new_s;
                    } else {
                        break :blk s;
                    }
                } else try self.readVal(K, deep_copy);

                self.alignTo(dbusAlignOf(V));
                const val = try self.readVal(V, deep_copy);
                try map.put(key, val);
            }
            return map;
        }

        switch (@typeInfo(T)) {
            .int => |info| {
                const size = info.bits / 8;
                if (self.pos + size > self.body.len) return error.EndOfBody;
                const val = std.mem.readInt(T, self.body[self.pos..][0..size], self.endian);
                self.pos += size;
                return val;
            },
            .bool => {
                // Boolean is 4 bytes (u32)
                if (self.pos + 4 > self.body.len) return error.EndOfBody;
                const val = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                self.pos += 4;
                return val != 0;
            },
            .float => {
                if (self.pos + 8 > self.body.len) return error.EndOfBody;
                const val_bits = std.mem.readInt(u64, self.body[self.pos..][0..8], self.endian);
                self.pos += 8;
                return @bitCast(val_bits);
            },
            .@"struct" => |info| {
                if (T == core.value.GStr or T == core.value.GPath) {
                    // String reading: u32 len, bytes, null
                    if (self.pos + 4 > self.body.len) return error.EndOfBody;
                    const len = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                    self.pos += 4;

                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    // Verify null terminator
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;

                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;

                    if (deep_copy) {
                        const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        return T.new(new_s);
                    } else {
                        return T.new(s);
                    }
                } else if (T == core.value.GSig) {
                    // Signature reading: u8 len, bytes, null
                    if (self.pos + 1 > self.body.len) return error.EndOfBody;
                    const len = self.body[self.pos];
                    self.pos += 1;

                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;

                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;

                    if (deep_copy) {
                        const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        return T.new(new_s);
                    } else {
                        return T.new(s);
                    }
                }

                // Generic struct/tuple/dict-entry support
                // DBus aligns structs and dict-entries to 8.
                const is_dict_entry = info.fields.len == 2 and (std.mem.eql(u8, info.fields[0].name, "key") and std.mem.eql(u8, info.fields[1].name, "value"));
                var result: T = undefined;
                inline for (info.fields) |fld| {
                    self.alignTo(dbusAlignOf(fld.type));
                    if (is_dict_entry and (fld.type == []const u8 or fld.type == [:0]const u8 or fld.type == []u8 or fld.type == [:0]u8) and std.mem.eql(u8, fld.name, "key")) {
                        if (self.pos + 4 > self.body.len) return error.EndOfBody;
                        const len = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                        self.pos += 4;
                        if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                        if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;
                        const s = self.body[self.pos .. self.pos + len :0];
                        self.pos += len + 1;
                        if (deep_copy) {
                            const new_s = try self.allocator.allocSentinel(u8, s.len, 0);
                            @memcpy(new_s, s);
                            @field(result, fld.name) = new_s;
                        } else {
                            @field(result, fld.name) = s;
                        }
                    } else {
                        @field(result, fld.name) = try self.readVal(fld.type, deep_copy);
                    }
                }
                return result;
            },
            .pointer => |info| {
                if (info.size != .slice) return error.UnsupportedType;
                const Elem = info.child;

                // Read byte length (u32)
                const byte_len = try self.readVal(u32, false); // No need to deep copy length

                // Align to element boundary
                self.alignTo(dbusAlignOf(Elem));

                const start_pos = self.pos;
                if (self.pos + byte_len > self.body.len) return error.EndOfBody;

                var list = try std.ArrayList(Elem).initCapacity(self.allocator, 0);
                errdefer list.deinit(self.allocator);

                while (self.pos - start_pos < byte_len) {
                    self.alignTo(dbusAlignOf(Elem));
                    try list.append(self.allocator, try self.readVal(Elem, deep_copy));
                }
                return try list.toOwnedSlice(self.allocator);
            },
            .@"union" => |info| {
                // Variants on wire: signature ('g'), then aligned value.
                const GSig = core.value.GSig;
                const inner_sig_struct = try self.readVal(GSig, false); // Signature borrowed is fine here for comparison
                const inner_sig = inner_sig_struct.s;

                if (T == GVariant) {
                    return try self.readDynamicVariant(inner_sig, deep_copy);
                }

                inline for (info.fields) |fld| {
                    const fld_sig_len = Value.reprLength(fld.type);
                    var fld_sig_buf: [256]u8 = undefined;
                    Value.getRepr(fld.type, fld_sig_len, 0, fld_sig_buf[0..fld_sig_len]);

                    if (std.mem.eql(u8, inner_sig, fld_sig_buf[0..fld_sig_len])) {
                        self.alignTo(dbusAlignOf(fld.type));
                        return @unionInit(T, fld.name, try self.readVal(fld.type, deep_copy));
                    }
                }
                return error.NoMatchingUnionField;
            },
            else => return error.UnsupportedType,
        }
    }

    fn readDynamicVariant(self: *BodyDecoder, sig: []const u8, comptime deep_copy: bool) anyerror!GVariant {
        var pos: usize = 0;
        return self.readDynamicVariantInner(sig, &pos, deep_copy);
    }

    fn readDynamicVariantInner(self: *BodyDecoder, sig: []const u8, sig_pos: *usize, comptime deep_copy: bool) anyerror!GVariant {
        if (sig_pos.* >= sig.len) return error.SignatureEnd;
        const c = sig[sig_pos.*];
        sig_pos.* += 1;
        switch (c) {
            'y' => {
                self.alignTo(dbusAlignOf(u8));
                return GVariant{ .byte = try self.readVal(u8, deep_copy) };
            },
            'b' => {
                self.alignTo(dbusAlignOf(bool));
                return GVariant{ .boolean = try self.readVal(bool, deep_copy) };
            },
            'n' => {
                self.alignTo(dbusAlignOf(i16));
                return GVariant{ .int16 = try self.readVal(i16, deep_copy) };
            },
            'q' => {
                self.alignTo(dbusAlignOf(u16));
                return GVariant{ .uint16 = try self.readVal(u16, deep_copy) };
            },
            'i' => {
                self.alignTo(dbusAlignOf(i32));
                return GVariant{ .int32 = try self.readVal(i32, deep_copy) };
            },
            'u' => {
                self.alignTo(dbusAlignOf(u32));
                return GVariant{ .uint32 = try self.readVal(u32, deep_copy) };
            },
            'x' => {
                self.alignTo(dbusAlignOf(i64));
                return GVariant{ .int64 = try self.readVal(i64, deep_copy) };
            },
            't' => {
                self.alignTo(dbusAlignOf(u64));
                return GVariant{ .uint64 = try self.readVal(u64, deep_copy) };
            },
            'd' => {
                self.alignTo(dbusAlignOf(f64));
                return GVariant{ .double = try self.readVal(f64, deep_copy) };
            },
            'h' => {
                self.alignTo(dbusAlignOf(core.value.GUFd));
                return GVariant{ .ufd = try self.readVal(core.value.GUFd, deep_copy) };
            },
            's' => {
                self.alignTo(dbusAlignOf(core.value.GStr));
                return GVariant{ .string = try self.readVal(core.value.GStr, deep_copy) };
            },
            'o' => {
                self.alignTo(dbusAlignOf(core.value.GPath));
                return GVariant{ .object_path = try self.readVal(core.value.GPath, deep_copy) };
            },
            'g' => {
                self.alignTo(dbusAlignOf(core.value.GSig));
                return GVariant{ .signature = try self.readVal(core.value.GSig, deep_copy) };
            },
            'v' => {
                const inner_sig_struct = try self.readVal(core.value.GSig, false);
                const inner_sig = inner_sig_struct.s;
                const inner_v = try self.readDynamicVariant(inner_sig, deep_copy);
                if (deep_copy) {
                    const ptr = try self.allocator.create(GVariant);
                    ptr.* = inner_v;
                    return GVariant{ .variant = ptr };
                } else {
                    return error.VariantCannotBeBorrowed;
                }
            },
            'a' => {
                if (sig_pos.* >= sig.len) return error.SignatureEnd;
                const is_dict = sig[sig_pos.*] == '{';

                self.alignTo(dbusAlignOf(u32));
                const byte_len = try self.readVal(u32, false);

                if (is_dict) {
                    self.alignTo(8);

                    const start_pos = self.pos;
                    if (self.pos + byte_len > self.body.len) return error.EndOfBody;

                    if (!deep_copy) return error.DictCannotBeBorrowed;

                    var dict = std.StringHashMap(GVariant).init(self.allocator);
                    errdefer dict.deinit();

                    sig_pos.* += 1;
                    const key_type = sig[sig_pos.*];
                    if (key_type != 's' and key_type != 'o' and key_type != 'g') {
                        return error.UnsupportedDictKeyType;
                    }

                    const dict_entry_sig_start = sig_pos.*;

                    while (self.pos - start_pos < byte_len) {
                        self.alignTo(8);
                        sig_pos.* = dict_entry_sig_start;

                        const key_variant = try self.readDynamicVariantInner(sig, sig_pos, deep_copy);
                        const key_str = switch (key_variant) {
                            .string => |s| s.s,
                            .object_path => |o| o.s,
                            .signature => |s| s.s,
                            else => unreachable,
                        };

                        const val_variant = try self.readDynamicVariantInner(sig, sig_pos, deep_copy);

                        try dict.put(key_str, val_variant);

                        if (sig[sig_pos.*] != '}') return error.ExpectedDictEnd;
                    }

                    if (byte_len == 0) {
                        _ = try self.skipDynamicVariantInner(sig, sig_pos);
                    } else {
                        sig_pos.* += 1;
                    }

                    return GVariant{ .dict = dict };
                } else {
                    const elem_align = try self.alignOfDynamicType(sig, sig_pos.*);
                    self.alignTo(elem_align);

                    const start_pos = self.pos;
                    if (self.pos + byte_len > self.body.len) return error.EndOfBody;

                    if (!deep_copy) return error.ArrayCannotBeBorrowed;

                    var list = try std.ArrayList(GVariant).initCapacity(self.allocator, 0);
                    errdefer list.deinit(self.allocator);

                    const elem_sig_start = sig_pos.*;

                    while (self.pos - start_pos < byte_len) {
                        self.alignTo(elem_align);
                        sig_pos.* = elem_sig_start;
                        const elem_v = try self.readDynamicVariantInner(sig, sig_pos, deep_copy);
                        try list.append(self.allocator, elem_v);
                    }

                    if (byte_len == 0) {
                        _ = try self.skipDynamicVariantInner(sig, sig_pos);
                    }

                    return GVariant{ .array = try list.toOwnedSlice(self.allocator) };
                }
            },
            '(' => {
                self.alignTo(8);
                if (!deep_copy) return error.TupleCannotBeBorrowed;
                var list = try std.ArrayList(GVariant).initCapacity(self.allocator, 0);
                errdefer list.deinit(self.allocator);

                while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') {
                    const elem_v = try self.readDynamicVariantInner(sig, sig_pos, deep_copy);
                    try list.append(self.allocator, elem_v);
                }
                if (sig_pos.* >= sig.len or sig[sig_pos.*] != ')') return error.ExpectedTupleEnd;
                sig_pos.* += 1;

                return GVariant{ .tuple = try list.toOwnedSlice(self.allocator) };
            },
            else => return error.UnsupportedDynamicType,
        }
    }

    fn skipDynamicVariantInner(self: *BodyDecoder, sig: []const u8, sig_pos: *usize) anyerror!void {
        if (sig_pos.* >= sig.len) return error.SignatureEnd;
        const c = sig[sig_pos.*];
        sig_pos.* += 1;
        switch (c) {
            'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => return,
            'a' => {
                return self.skipDynamicVariantInner(sig, sig_pos);
            },
            '(' => {
                while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') {
                    try self.skipDynamicVariantInner(sig, sig_pos);
                }
                if (sig_pos.* >= sig.len) return error.SignatureEnd;
                sig_pos.* += 1;
            },
            '{' => {
                try self.skipDynamicVariantInner(sig, sig_pos); // key
                try self.skipDynamicVariantInner(sig, sig_pos); // val
                if (sig_pos.* >= sig.len or sig[sig_pos.*] != '}') return error.SignatureEnd;
                sig_pos.* += 1;
            },
            else => return error.UnsupportedDynamicType,
        }
    }

    fn alignOfDynamicType(self: *BodyDecoder, sig: []const u8, sig_pos: usize) anyerror!usize {
        _ = self;
        if (sig_pos >= sig.len) return error.SignatureEnd;
        switch (sig[sig_pos]) {
            'y', 'g', 'v' => return 1,
            'n', 'q' => return 2,
            'i', 'u', 'b', 'h', 'a', 's', 'o' => return 4,
            'x', 't', 'd', '(', '{' => return 8,
            else => return error.UnsupportedDynamicType,
        }
    }
};
