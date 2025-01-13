const std = @import("std");
const dbus = @import("root.zig");
// const DBusConnection = dbus.DBusConnection;
// const BusType = DBusConnection.BusType;
const Value = dbus.value.Value;
const ValueTag = dbus.value.ValueTag;

pub fn main() !void {
    const a = Value.Bool().new(false);
    std.debug.print("{s}\n", .{a.repr});
    const xs = Value.Array(i32).new(&[_]i32{ 1, 2, 3 });
    std.debug.print("{s}\n", .{xs.repr});
    const c = Value.Double().new(3.0);
    std.debug.print("{s}\n", .{c.repr});

    // switch (@typeInfo(u16)) {
    //     .Int => |info| {
    //         std.debug.print("{any}\n", .{info});
    //     },
    //     else => unreachable,
    // }
}
