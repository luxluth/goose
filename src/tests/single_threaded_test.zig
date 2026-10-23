pub fn main(i: std.process.Init) !void {
    const allocator = i.gpa;

    // Test default Connection.init in single-threaded mode (should default to .poll backend)
    var conn = try Connection.init(allocator, .Session, i.io, i.environ_map);
    defer conn.close();

    try std.testing.expectEqual(conn.backend, .poll);
    try std.testing.expectEqual(conn.worker_thread, null);
    try std.testing.expectEqual(conn.dispatch_thread, null);

    // Calling serve() in single-threaded mode must return InvalidBackend
    try std.testing.expectError(error.InvalidBackend, conn.serve());

    // Attempting to initialize with .threaded backend in single-threaded mode must return InvalidBackend
    try std.testing.expectError(error.InvalidBackend, Connection.initWithBackend(allocator, .Session, i.io, i.environ_map, .threaded));

    const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
    var result = try dbus_proxy.call("GetId", .{});
    defer result.deinit();
    const id = try result.expect(GStr);
    std.debug.print("Proxy GetId: {s}\n", .{id.s});

    var result2 = try dbus_proxy.call("NameHasOwner", .{GStr.new("org.freedesktop.DBus")});
    defer result2.deinit();
    const has_owner = try result2.expect(bool);
    std.debug.print("Proxy NameHasOwner: {}\n", .{has_owner});

    // Verify dispatch works without blocking
    while (try conn.dispatch()) {}

    // Verify explicit initWithBackend with .poll works as well
    var poll_conn = try Connection.initWithBackend(allocator, .Session, i.io, i.environ_map, .poll);
    defer poll_conn.close();
    try std.testing.expectEqual(poll_conn.backend, .poll);
    try std.testing.expectEqual(poll_conn.worker_thread, null);
    try std.testing.expectEqual(poll_conn.dispatch_thread, null);
}

const goose = @import("goose");
const GStr = goose.core.value.GStr;
const Connection = goose.Connection;
const proxy = goose.proxy;
const std = @import("std");
