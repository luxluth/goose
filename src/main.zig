const std = @import("std");

const goose = @import("goose");
const core = goose.core;
const message = goose.message;
const Value = core.value.Value;
const GStr = core.value.GStr;
const Connection = goose.Connection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var conn = try Connection.init(allocator);
    defer conn.close();

    // Example 1: Call GetId (no args, returns string)
    {
        std.debug.print("Calling GetId...\n", .{});
        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetId",
            null,
            &.{},
        );
        defer conn.freeMessage(&reply);

        // Read response
        var reader = message.MessageReader.fromMessage(reply);
        const id_struct = try reader.read(GStr);
        std.debug.print("Bus ID: {s}\n", .{id_struct.s});
    }

    // Example 2: Call NameHasOwner (takes string, returns bool)
    {
        std.debug.print("Calling NameHasOwner...\n", .{});
        var builder = try message.MessageBuilder.init(allocator);
        defer builder.deinit();

        try builder.append(GStr.new("org.freedesktop.DBus"));
        const built = try builder.finish();

        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            built.signature,
            built.body,
        );
        defer conn.freeMessage(&reply);

        // Read response
        var reader = message.MessageReader.fromMessage(reply);
        const exists = try reader.read(bool);
        std.debug.print("NameHasOwner('org.freedesktop.DBus'): {}\n", .{exists});
    }
}