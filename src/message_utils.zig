const NATIVE_ENDIAN = @import("builtin").target.cpu.arch.endian();
const std = @import("std");
const core = @import("core.zig");
const Value = core.value.Value;
const DBusWriter = core.value.DBusWriter;
const Serializer = core.value.Serializer;
const dbusAlignOf = core.value.dbusAlignOf;

pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8),
    signature: std.ArrayList(u8),
    endian: std.builtin.Endian,

    pub fn init(allocator: std.mem.Allocator) !MessageBuilder {
        return .{
            .allocator = allocator,
            .body = try std.ArrayList(u8).initCapacity(allocator, 256),
            .signature = try std.ArrayList(u8).initCapacity(allocator, 32),
            .endian = NATIVE_ENDIAN,
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        self.body.deinit(self.allocator);
        self.signature.deinit(self.allocator);
    }

    pub fn append(self: *MessageBuilder, value: anytype) !void {
        const T = @TypeOf(value);
        const sig_len = Value.reprLength(T);
        var sig_buf: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, sig_buf[0..sig_len]);
        try self.signature.appendSlice(self.allocator, sig_buf[0..sig_len]);

        var writer = DBusWriter.init(&self.body, self.allocator, self.endian);
        try writer.padTo(dbusAlignOf(T));
        try Serializer.trySerialize(T, value, &writer);
    }

    pub fn finish(self: *MessageBuilder) !struct { body: []const u8, signature: [:0]const u8 } {
        // Ensure signature is null-terminated
        try self.signature.append(self.allocator, 0);
        return .{
            .body = self.body.items,
            .signature = self.signature.items[0 .. self.signature.items.len - 1 :0],
        };
    }
};

pub const MessageReader = struct {
    body: []const u8,
    signature: []const u8,
    pos: usize,
    sig_pos: usize,
    endian: std.builtin.Endian,

    pub fn init(body: []const u8, signature: []const u8, endian: std.builtin.Endian) MessageReader {
        return .{
            .body = body,
            .signature = signature,
            .pos = 0,
            .sig_pos = 0,
            .endian = endian,
        };
    }

    pub fn fromMessage(msg: core.Message) MessageReader {
        var sig: []const u8 = "";
        for (msg.header.header_fields) |field| {
            if (field.code == .Signature) {
                sig = field.value.Signature;
                break;
            }
        }

        return .{
            .body = msg.body,
            .signature = sig,
            .pos = 0,
            .sig_pos = 0,
            .endian = msg.header.endianess,
        };
    }

    fn alignTo(self: *MessageReader, alignment: usize) void {
        const rem = self.pos % alignment;
        if (rem != 0) {
            self.pos += (alignment - rem);
        }
    }

    pub fn read(self: *MessageReader, comptime T: type) !T {
        const sig_len = Value.reprLength(T);
        var expected_sig: [256]u8 = undefined;
        Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

        if (self.sig_pos + sig_len > self.signature.len) return error.SignatureEnd;
        if (!std.mem.eql(u8, self.signature[self.sig_pos .. self.sig_pos + sig_len], expected_sig[0..sig_len])) {
            return error.SignatureMismatch;
        }
        self.sig_pos += sig_len;

        self.alignTo(dbusAlignOf(T));

        return self.readVal(T);
    }

    fn readVal(self: *MessageReader, comptime T: type) !T {
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
            .@"struct" => {
                if (T == core.value.GStr or T == core.value.GPath or T == core.value.GSig) {
                    // String reading: u32 len, bytes, null
                    // Alignment 4 for length
                    if (self.pos + 4 > self.body.len) return error.EndOfBody;
                    const len = std.mem.readInt(u32, self.body[self.pos..][0..4], self.endian);
                    self.pos += 4;

                    if (self.pos + len + 1 > self.body.len) return error.EndOfBody;
                    // Verify null terminator
                    if (self.body[self.pos + len] != 0) return error.MissingNullTerminator;

                    const s = self.body[self.pos .. self.pos + len :0];
                    self.pos += len + 1;

                    return T.new(s);
                }
                return error.UnsupportedType;
            },
            else => return error.UnsupportedType,
        }
    }
};

