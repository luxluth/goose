const std = @import("std");

const goose = @import("goose");
const core = goose.core;
const message = goose.message;
const proxy = goose.proxy;
const Value = core.value.Value;
const GStr = core.value.GStr;
const GPath = core.value.GPath;
const GVariant = core.value.GVariant;
const Connection = goose.Connection;

const UPowerProxy = @import("batteries.zig").UPowerProxy;
const PropertiesProxy = @import("batteries.zig").PropertiesProxy;

fn printData(data: []const u8) void {
    for (data) |x| {
        if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
            std.debug.print("{c}", .{x});
        } else {
            std.debug.print("\\{o}", .{x});
        }
    }
    std.debug.print("\n", .{});
}

// Signal handler callbacks for generated proxies
fn onPropertiesChanged(
    ctx: *u32,
    args: @Tuple(&[_]type{ GStr, std.StringHashMap(GVariant), []const GStr }),
) void {
    ctx.* += 1;
    const interface_name = args[0];
    const changed_props = args[1];
    std.debug.print("SIGNAL [Typed Callback]: PropertiesChanged on '{s}' (count={d})\n", .{ interface_name.s, ctx.* });
    var it = changed_props.iterator();
    while (it.next()) |entry| {
        std.debug.print("  - {s}\n", .{entry.key_ptr.*});
    }
}

fn onDeviceAdded(ctx: *u32, args: @Tuple(&[_]type{GPath})) void {
    ctx.* += 1;
    std.debug.print("SIGNAL [Typed Callback]: DeviceAdded at '{s}' (count={d})\n", .{ args[0].s, ctx.* });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var conn = try Connection.init(allocator, .Session, init.io, init.environ_map);
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
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const id = try decoder.decode(GStr);
        std.debug.print("Bus ID: {s}\n", .{id.s});
    }

    // Example 2: Call NameHasOwner (takes string, returns bool)
    {
        std.debug.print("\nCalling NameHasOwner...\n", .{});
        var encoder = try message.BodyEncoder.encode(allocator, GStr.new("org.freedesktop.DBus"));
        defer encoder.deinit();

        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            encoder.signature(),
            encoder.body(),
        );
        defer conn.freeMessage(&reply);

        // Read response
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const exists = try decoder.decode(bool);
        std.debug.print("NameHasOwner('org.freedesktop.DBus'): {}\n", .{exists});
    }

    // Example 3: Call ListNames (returns array of strings)
    {
        std.debug.print("\nCalling ListNames...\n", .{});
        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            null,
            &.{},
        );
        defer conn.freeMessage(&reply);

        // Read response
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const names = try decoder.decode([]const GStr);
        defer allocator.free(names);

        std.debug.print("Found {d} names. First 5:\n", .{names.len});
        for (names[0..@min(5, names.len)]) |name| {
            std.debug.print(" - {s}\n", .{name.s});
        }
    }

    // Example 4: Manual Complex Type Test (Struct with Array and Dict)
    {
        std.debug.print("\nTesting Struct/Array/Dict Reading manually...\n", .{});

        const MyEntry = struct { key: GStr, value: i32 };
        const MyData = struct { id: i32, tags: []const GStr, scores: []const MyEntry };

        const entries = [_]MyEntry{ .{ .key = GStr.new("A"), .value = 10 }, .{ .key = GStr.new("B"), .value = 20 } };
        const tags = [_]GStr{ GStr.new("zig"), GStr.new("dbus") };
        const data = MyData{ .id = 42, .tags = &tags, .scores = &entries };

        // Use encode with a single complex argument
        var encoder = try message.BodyEncoder.encode(allocator, data);
        defer encoder.deinit();

        std.debug.print("Signature: {s}\n", .{encoder.signature()});

        var decoder = message.BodyDecoder.init(allocator, encoder.body(), encoder.signature(), .little);
        const decoded = try decoder.decode(MyData);
        defer {
            allocator.free(decoded.tags);
            allocator.free(decoded.scores);
        }

        std.debug.print("Decoded Struct:\n", .{});
        std.debug.print(" - ID: {d}\n", .{decoded.id});
        std.debug.print(" - Tags: {d} items\n", .{decoded.tags.len});
        std.debug.print(" - Scores: {d} entries\n", .{decoded.scores.len});
        for (decoded.scores) |e| {
            std.debug.print("   - {s} => {d}\n", .{ e.key.s, e.value });
        }
    }

    // Example 5: Using Proxy API
    {
        std.debug.print("\nTesting Proxy API...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

        // Call GetId via Proxy
        var result = try dbus_proxy.call("GetId", .{});
        defer result.deinit();
        const id = try result.expect(GStr);
        std.debug.print("Proxy GetId: {s}\n", .{id.s});

        // Call NameHasOwner via Proxy
        var result2 = try dbus_proxy.call("NameHasOwner", .{GStr.new("org.freedesktop.DBus")});
        defer result2.deinit();
        const has_owner = try result2.expect(bool);
        std.debug.print("Proxy NameHasOwner: {}\n", .{has_owner});
    }

    // Example 7: Error Handling Test
    {
        std.debug.print("\nTesting Proxy Error Handling (calling non-existent method)...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

        _ = dbus_proxy.call("ThisMethodDoesNotExist", .{}) catch |err| {
            std.debug.print("Caught expected error: {any}\n", .{err});
        };
    }

    // Example 8: Property Access Test
    {
        std.debug.print("\nTesting Property Access (Notifications Dnd)...\n", .{});
        const noti_proxy = proxy.Proxy.init(&conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications");

        const NotiProp = union(enum) { Bool: bool, String: GStr };
        const dnd = noti_proxy.getProperty(NotiProp, "Dnd") catch NotiProp{ .Bool = false };
        std.debug.print("Notifications Dnd: {}\n", .{dnd.Bool});
    }

    // Example 9: Owned Decoding Test
    {
        std.debug.print("\nTesting Owned Decoding (decodeAlloc)...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
        var result = try dbus_proxy.call("GetId", .{});

        var decoder = result.reader();
        // Decode and copy string
        const owned_id = try decoder.decodeAlloc(GStr);

        // owned_id should still be valid
        std.debug.print("Owned Bus ID (after deinit): {s}\n", .{owned_id.s});

        // Free result immediately
        result.deinit();
    }

    // Example 6: Listening to Signals via Generated Proxy Helpers
    {
        std.debug.print("\nExample 6: Subscribing to PropertiesChanged via generated proxy helper...\n", .{});
        var signal_count: u32 = 0;
        const props = PropertiesProxy.init(&conn);
        try props.connectPropertiesChanged(&signal_count, onPropertiesChanged);
        std.debug.print("Successfully subscribed to PropertiesChanged! (handler count={d})\n", .{conn.signal_handlers.items.len});
    }

    // Example 10: Using Generated proxy
    {
        var conn2 = try Connection.init(allocator, .System, init.io, init.environ_map);
        defer conn2.close();

        const power = UPowerProxy.init(&conn2);
        var dev_count: u32 = 0;
        try power.connectDeviceAdded(&dev_count, onDeviceAdded);
        std.debug.print("\nExample 10: Subscribed to UPower DeviceAdded signal! (handler count={d})\n", .{conn2.signal_handlers.items.len});

        const paths = try power.EnumerateDevices();

        for (paths) |path| {
            std.debug.print("{s}\n", .{path.s});
            allocator.free(path.s);
        }
        allocator.free(paths);
    }

    // Example 11: MPRIS Metadata Decoding Test
    {
        std.debug.print("\nExample 11: MPRIS Metadata Decoding Test\n", .{});

        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            null,
            &.{},
        );
        defer conn.freeMessage(&reply);

        var mpris_name: ?[:0]const u8 = null;
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const names = try decoder.decode([]const GStr);
        defer allocator.free(names);

        for (names) |name| {
            if (std.mem.startsWith(u8, name.s, "org.mpris.MediaPlayer2.")) {
                mpris_name = name.s;
                break;
            }
        }

        if (mpris_name) |name| {
            std.debug.print("Found MPRIS service: {s}\n", .{name});

            var encoder = try message.BodyEncoder.encode(allocator, GStr.new("org.mpris.MediaPlayer2.Player"));
            defer encoder.deinit();

            var prop_reply = conn.methodCall(
                name,
                "/org/mpris/MediaPlayer2",
                "org.freedesktop.DBus.Properties",
                "GetAll",
                encoder.signature(),
                encoder.body(),
            ) catch |err| {
                std.debug.print("Failed to get properties: {any}\n", .{err});
                return;
            };
            defer conn.freeMessage(&prop_reply);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            var prop_decoder = message.BodyDecoder.fromMessage(arena_alloc, prop_reply);
            const props = prop_decoder.decodeAlloc(std.StringHashMap(GVariant)) catch |err| {
                std.debug.print("Failed to decode properties (was the bug triggered ?): {any}\n", .{err});
                return;
            };

            if (props.get("Metadata")) |meta_var| {
                if (meta_var == .dict) {
                    std.debug.print("Successfully decoded MPRIS Metadata. Item count: {d}\n", .{meta_var.dict.count()});
                    var it = meta_var.dict.iterator();
                    while (it.next()) |entry| {
                        std.debug.print("  - {s}: ", .{entry.key_ptr.*});
                        const val = if (entry.value_ptr.* == .variant) entry.value_ptr.variant.* else entry.value_ptr.*;
                        switch (val) {
                            .string => |s| std.debug.print("\"{s}\"\n", .{s.s}),
                            .object_path => |o| std.debug.print("path(\"{s}\")\n", .{o.s}),
                            .int32 => |i| std.debug.print("{d}\n", .{i}),
                            .uint32 => |u| std.debug.print("{d}\n", .{u}),
                            .int64 => |i| std.debug.print("{d}\n", .{i}),
                            .uint64 => |u| std.debug.print("{d}\n", .{u}),
                            .double => |d| std.debug.print("{d}\n", .{d}),
                            .boolean => |b| std.debug.print("{}\n", .{b}),
                            .array => |arr| {
                                std.debug.print("[", .{});
                                for (arr, 0..) |item, i| {
                                    if (i > 0) std.debug.print(", ", .{});
                                    const inner = if (item == .variant) item.variant.* else item;
                                    switch (inner) {
                                        .string => |s_inner| std.debug.print("\"{s}\"", .{s_inner.s}),
                                        .object_path => |o_inner| std.debug.print("path(\"{s}\")", .{o_inner.s}),
                                        .int32 => |num| std.debug.print("{d}", .{num}),
                                        .int64 => |num| std.debug.print("{d}", .{num}),
                                        .double => |num| std.debug.print("{d}", .{num}),
                                        else => std.debug.print("{s}", .{@tagName(inner)}),
                                    }
                                }
                                std.debug.print("]\n", .{});
                            },
                            .dict => |d_map| std.debug.print("[dict of {d} items]\n", .{d_map.count()}),
                            .variant => |v| std.debug.print("[variant containing {s}]\n", .{@tagName(v.*)}),
                            else => |v| std.debug.print("[{s}]\n", .{@tagName(v)}),
                        }
                    }
                } else {
                    std.debug.print("Metadata property is not a dict. It is: {s}\n", .{@tagName(meta_var)});
                }
            } else {
                std.debug.print("No Metadata property found in MPRIS player.\n", .{});
            }
        } else {
            std.debug.print("No MPRIS service running. Skipping live metadata test.\n", .{});
        }
    }
}
