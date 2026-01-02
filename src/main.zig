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
}
