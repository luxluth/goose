const std = @import("std");
const dbus = @import("root.zig");
const DBusConnection = dbus.DBusConnection;
const BusType = DBusConnection.BusType;

pub fn main() !void {
    var conn = try DBusConnection.init(BusType.Session);
    defer conn.deinit();

    conn.requestName("test.luxluth.zig_bus") catch |e| {
        std.debug.print("{any}", .{e});
    };

    _ = try conn.createInterface("/test/luxluth/zig_bus");

    while (true) {
        try conn.waitForMessage();
    }
}
