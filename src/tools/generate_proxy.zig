const std = @import("std");
const goose = @import("goose");

pub fn usage(prog: [:0]const u8) void {
    const prog_name = std.fs.path.basename(prog);
    std.debug.print("Usage: {s} [OPTIONS] <destination> <object_path> <bus_type>\n", .{prog_name});
    std.debug.print("\nArguments:\n", .{});
    std.debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
    std.debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
    std.debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  .fromFile <FILE>  Generate proxy code from  an xml object definition\n", .{});
    std.debug.print("\nExample:\n", .{});
    std.debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});
    std.debug.print("  {s} .fromFile org.freedesktop.portal.FileChooser.xml\n", .{prog_name});
}

pub fn main(init: std.process.Init) !void {
    var arena = init.arena;
    const allocator = arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 3) {
        usage(args[0]);
        return;
    }

    var fromFile = false;
    if (std.mem.eql(u8, args[1], ".fromFile")) {
        fromFile = true;
    } else {
        if (args.len < 4) {
            usage(args[0]);
            return;
        }
    }

    var xml: goose.core.value.GStr = undefined;
    var dest: ?[:0]const u8 = undefined;
    var path: ?[:0]const u8 = undefined;

    if (!fromFile) {
        dest = args[1];
        path = args[2];
        const bustype = std.meta.stringToEnum(goose.BusType, args[3]).?;

        var conn = try goose.Connection.init(allocator, bustype, io, init.environ_map);
        defer conn.close();

        const dbus_proxy = goose.proxy.Proxy.init(&conn, @ptrCast(dest), @ptrCast(path), "org.freedesktop.DBus.Introspectable");
        var result = try dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
        defer result.deinit();
        xml = try result.expectAlloc(goose.core.value.GStr);
    } else {
        path = args[2];
        var dir = std.Io.Dir.cwd();
        var file = try dir.openFile(io, path.?, .{
            .follow_symlinks = true,
            .mode = .read_only,
        });
        const f_len = try file.length(io);
        var buff = try allocator.allocSentinel(u8, f_len, 0);
        _ = &buff;
        var temp: [2048]u8 = @splat(0);
        var reader = file.reader(io, &temp);
        const r = &reader.interface;
        r.readSliceAll(buff) catch {};
        defer file.close(io);
        xml = .new(buff);
    }

    const node = try goose.introspection.parse(allocator, xml.s);
    if (fromFile) {
        dest = null;
        path = null;
    }
    defer node.deinit(allocator);

    var writer = std.Io.File.stdout().writerStreaming(init.io, try allocator.alloc(u8, 0x100));
    defer allocator.free(writer.interface.buffer);

    try goose.generator.generate(&writer.interface, node, dest, path);
    try writer.flush();
    if (fromFile) allocator.free(xml.s);
}
