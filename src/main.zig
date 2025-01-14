const std = @import("std");
const dbus = @import("root.zig");
// const DBusConnection = dbus.DBusConnection;
// const BusType = DBusConnection.BusType;
const Value = dbus.value.Value;
const ValueTag = dbus.value.ValueTag;

const Coord = struct {
    x: f64,
    y: f64,
    speed: Speed,
};

const Speed = struct {
    vel: f64,
    acc: u64,
    stopped: bool,
};

const Tup = std.meta.Tuple(&[_]type{ i32, i32, f64 });

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const a = Value.Bool().new(false);
    std.debug.print("{s}\n", .{a.repr});

    const xs = Value.Array(i64).new(&[_]i64{ 1, 2, 3 });
    std.debug.print("{s}\n", .{xs.repr});

    const c = Value.Double().new(3.0);
    std.debug.print("{s}\n", .{c.repr});

    const coord = Coord{
        .x = 98,
        .y = 199,
        .speed = .{
            .acc = 23,
            .stopped = false,
            .vel = 455,
        },
    };

    const t = Value.Struct(Coord).new(coord);
    std.debug.print("{s}\n", .{t.repr});

    const cx = Value.Array(Coord).new(&[_]Coord{coord});
    std.debug.print("{s}\n", .{cx.repr});

    const tup = Value.Tuple(Tup).new(.{ 4, 4, 4 });
    std.debug.print("{s}\n", .{tup.repr});

    const va = Value.Variant(Tup).new(.{ 4, 4, 4 });
    std.debug.print("{s}\n", .{va.repr});

    const dico = Value.Dict(i32, f64).init(allocator);
    std.debug.print("{s}\n", .{dico.repr});
}
