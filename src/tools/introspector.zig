const std = @import("std");
const goose = @import("goose");
const proxy = goose.proxy;
const message = goose.message;
const GStr = goose.core.value.GStr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <dest> <path>\n", .{args[0]});
        std.debug.print("Example: {s} org.freedesktop.DBus /org/freedesktop/DBus\n", .{args[0]});
        return;
    }

    const dest = args[1];
    const path = args[2];

    var conn = try goose.Connection.init(allocator);
    defer conn.close();

    std.debug.print("Target: {s} {s}\n", .{ dest, path });

    const dbus_proxy = proxy.Proxy.init(&conn, dest, path, "org.freedesktop.DBus.Introspectable");

    var result = dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{}) catch |err| {
        std.debug.print("Error calling Introspect: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const xml = try result.expect(GStr);

    const node = try goose.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    std.debug.print("Found {d} interfaces.\n", .{node.interfaces.len});
    for (node.interfaces) |iface| {
        std.debug.print("\nInterface: {s}\n", .{iface.name});
        for (iface.methods) |m| {
            std.debug.print("  Method: {s}(", .{m.name});
            for (m.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(", ", .{});
                if (arg.name.len > 0) {
                    std.debug.print("{s}: {s}", .{ arg.name, arg.type });
                } else {
                    std.debug.print("{s}", .{arg.type});
                }
            }
            std.debug.print(")\n", .{});
        }
    }

    if (node.children.len > 0) {
        std.debug.print("\nChild nodes:\n", .{});
        for (node.children) |child| {
            std.debug.print(" - {s}\n", .{child.name});
        }
    }
}
