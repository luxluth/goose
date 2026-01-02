const std = @import("std");
const core = @import("core.zig");
const message = @import("message_utils.zig");
const Connection = @import("root.zig").Connection;
const BodyEncoder = message.BodyEncoder;
const BodyDecoder = message.BodyDecoder;

/// Result of a D-Bus method call.
/// Owns the reply message and provides methods to decode its body.
pub const MethodResult = struct {
    msg: core.Message,
    conn: *Connection,

    /// Releases resources associated with the result message.
    pub fn deinit(self: *MethodResult) void {
        self.conn.freeMessage(&self.msg);
    }

    /// Returns a BodyDecoder to read the result body.
    /// Note: The decoder's lifetime is tied to the result.
    pub fn reader(self: *MethodResult) BodyDecoder {
        return BodyDecoder.fromMessage(self.conn.__allocator, self.msg);
    }

    /// Convenience method to decode a single value of type T.
    /// Note: The MethodResult must still be explicitly deinitialized after use
    /// if T borrows memory (like strings or slices) from the message body.
    pub fn expect(self: *MethodResult, comptime T: type) !T {
        var dec = self.reader();
        return try dec.decode(T);
    }
};

/// A local representation of a remote D-Bus object.
pub const Proxy = struct {
    conn: *Connection,
    dest: [:0]const u8,
    path: [:0]const u8,
    interface: [:0]const u8,

    /// Creates a new Proxy for a remote object.
    pub fn init(conn: *Connection, dest: [:0]const u8, path: [:0]const u8, interface: [:0]const u8) Proxy {
        return .{
            .conn = conn,
            .dest = dest,
            .path = path,
            .interface = interface,
        };
    }

    /// Invokes a method on the remote object.
    /// `args` can be a single value or a tuple of values.
    /// Returns a MethodResult owning the reply message.
    pub fn call(self: Proxy, method: [:0]const u8, args: anytype) !MethodResult {
        var encoder = try BodyEncoder.encode(self.conn.__allocator, args);
        defer encoder.deinit();

        const reply = try self.conn.methodCall(
            self.dest,
            self.path,
            self.interface,
            method,
            encoder.signature(),
            encoder.body(),
        );

        return MethodResult{
            .msg = reply,
            .conn = self.conn,
        };
    }
};