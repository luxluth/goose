const std = @import("std");
const goose = @import("goose");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        const prog_name = std.fs.path.basename(args[0]);
        std.debug.print("Usage: {s} <destination> <object_path> <bus_type>\n", .{prog_name});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
        std.debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
        std.debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});
        return;
    }

    const dest = args[1];
    const path = args[2];
    const bustype = std.meta.stringToEnum(goose.BusType, args[3]).?;

    var conn = try goose.Connection.init(allocator, bustype);
    defer conn.close();

    const dbus_proxy = goose.proxy.Proxy.init(&conn, @ptrCast(dest), @ptrCast(path), "org.freedesktop.DBus.Introspectable");
    var result = try dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer result.deinit();

    const xml = try result.expect(goose.core.value.GStr);

    const node = try goose.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    const generated = try goose.generator.generate(allocator, node, dest, path);
    defer allocator.free(generated);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(generated);
    try stdout.flush();
}
