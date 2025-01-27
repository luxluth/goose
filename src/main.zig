const std = @import("std");
// const net = std.net;
// const core = @import("./root.zig").core;
// const Value = @import("./value.zig").Value;

const goose = @import("root.zig");
// const core = @import("root.zig").core;
// const Value = core.value.Value;
// const Connection = goose.Connection;
const T = goose.core.HeaderFieldValue;

fn fields(comptime S: type) std.builtin.Type.StructField {
    if (std.meta.hasMethod(S, "ser")) {
        const Args = std.meta.ArgsTuple(@TypeOf(S.ser));
        const fx_ = std.meta.fields(Args);
        if (fx_.len == 2)
            return fx_[1];
    } else {
        @compileError("iiiiiiiiiiii");
    }
}

const fx = fields(T);

pub fn main() !void {
    std.debug.print("{any}\n", .{fx});
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const allocator = gpa.allocator();
    // defer _ = gpa.deinit();

    // var arr = std.ArrayList(u8).init(allocator);
    // defer arr.deinit();
    //
    // try Value.String().new("Hello world").ser(&arr);
    // try Value.Double().new(13.45).ser(&arr);
    // std.debug.print("{any}\n", .{arr.items});
    // try Value.Bool().new(false).ser(&arr);
    // std.debug.print("{any}\n", .{arr.items});

    // var conn = try Connection.init(allocator);
    // defer conn.close();
    //
    // try conn.requestName("dev.goose.zig");
}
