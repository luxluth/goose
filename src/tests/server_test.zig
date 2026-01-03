const std = @import("std");
const goose = @import("goose");
const Connection = goose.Connection;
const signal = goose.signal;
const GStr = goose.core.value.GStr;

const MyInterface = struct {
    conn: *Connection,
    // Properties (not yet supported in dispatch logic, but struct field is fine)
    ThisIsAProps: goose.Property(i32, .ReadWrite) = goose.property(i32, .ReadWrite, 43),
    // Signal
    thisIsAsignal: goose.Signal(GStr) = signal("thisIsAsignal", GStr),

    pub const INTERFACE_NAME = "dev.myinterface.test";

    pub fn init(conn: *Connection, _: void) @This() {
        return MyInterface{
            .conn = conn,
        };
    }

    pub fn Testing(self: *MyInterface) !GStr {
        std.debug.print("MyInterface.Testing called!\n", .{});
        std.debug.print("Prop value: {d}\n", .{self.ThisIsAProps.value});
        try self.thisIsAsignal.trigger(self.conn, GStr.new("from the random Signal"));
        return GStr.new("Hello");
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Initializing connection...\n", .{});
    // Note: This requires a running DBus session bus.
    var conn = try Connection.init(allocator);
    defer conn.close();

    std.debug.print("Registering interface {s}...\n", .{MyInterface.INTERFACE_NAME});
    const handle = try conn.registerObject(MyInterface, "dev.myinterface.test", "/dev/myinterface/test");

    std.debug.print("Service registered. Handle: {d}\n", .{handle});
    std.debug.print("Ready to serve requests.\n", .{});

    // Uncomment to run loop:
    try conn.waitOnHandle(handle);
}
