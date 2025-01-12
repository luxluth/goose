const std = @import("std");
const dbus = @import("root.zig");
// const DBusConnection = dbus.DBusConnection;
// const BusType = DBusConnection.BusType;
const V = dbus.value.Value;

pub fn main() !void {
    std.debug.print("{d}\n", .{@bitSizeOf(V)});
}
