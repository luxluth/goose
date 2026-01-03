const std = @import("std");
const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree.
pub fn generate(allocator: std.mem.Allocator, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("const goose = @import(\"goose\");\n");
    try w.writeAll("const proxy = goose.proxy;\n");
    try w.writeAll("const GStr = goose.core.value.GStr;\n\n");

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try w.writeAll("pub const ");
        try w.writeAll(short_name);
        try w.writeAll("Proxy = struct {\n");
        try w.writeAll("    inner: proxy.Proxy,\n\n");

        try w.writeAll("    pub fn init(conn: *goose.Connection");
        if (dest == null) try w.writeAll(", dest: [:0]const u8");
        if (path == null) try w.writeAll(", path: [:0]const u8");
        try w.writeAll(") ");
        try w.writeAll(short_name);
        try w.writeAll("Proxy {\n");
        try w.writeAll("        return .{ .inner = proxy.Proxy.init(conn, ");
        if (dest) |d| {
            try w.print("\"{s}\"", .{d});
        } else {
            try w.writeAll("dest");
        }
        try w.writeAll(", ");
        if (path) |p| {
            try w.print("\"{s}\"", .{p});
        } else {
            try w.writeAll("path");
        }
        try w.writeAll(", \"");
        try w.writeAll(iface.name);
        try w.writeAll("\") };\n");
        try w.writeAll("    }\n\n");

        for (iface.methods) |method| {
            try w.writeAll("    pub fn ");
            try w.writeAll(method.name);
            try w.writeAll("(self: ");
            try w.writeAll(short_name);
            try w.writeAll("Proxy");

            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    try w.writeAll(", ");
                    if (arg.name.len > 0) {
                        try w.writeAll(arg.name);
                    } else {
                        try w.print("arg{d}", .{in_idx});
                    }
                    try w.writeAll(": ");
                    try w.writeAll(try dbusTypeToZig(arg.type, true));
                    in_idx += 1;
                }
            }

            // Return type
            var out_sig: ?[]const u8 = null;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "out")) {
                    out_sig = arg.type;
                    break;
                }
            }

            const out_type = if (out_sig) |s| try dbusTypeToZig(s, false) else "void";
            const is_method_result = std.mem.eql(u8, out_type, "proxy.MethodResult");

            try w.writeAll(") !");
            try w.writeAll(out_type);
            try w.writeAll(" {\n");

            if (is_method_result) {
                try w.writeAll("        const res = try self.inner.call(\"");
            } else {
                try w.writeAll("        var res = try self.inner.call(\"");
            }
            try w.writeAll(method.name);
            try w.writeAll("\", .{");

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    if (!first) try w.writeAll(", ");
                    if (arg.name.len > 0) {
                        try w.writeAll(arg.name);
                    } else {
                        try w.print("arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try w.writeAll("});\n");

            if (std.mem.eql(u8, out_type, "void")) {
                try w.writeAll("        res.deinit();\n");
            } else if (is_method_result) {
                try w.writeAll("        return res;\n");
            } else {
                try w.writeAll("        return res.expect(");
                try w.writeAll(out_type);
                try w.writeAll(");\n");
            }
            try w.writeAll("    }\n");
        }

        try w.writeAll("};\n\n");
    }

    return out.toOwnedSlice(allocator);
}

fn dbusTypeToZig(sig: []const u8, is_param: bool) ![]const u8 {
    if (std.mem.eql(u8, sig, "s")) return "GStr";
    if (std.mem.eql(u8, sig, "u")) return "u32";
    if (std.mem.eql(u8, sig, "b")) return "bool";
    if (std.mem.eql(u8, sig, "as")) return "[]const GStr";
    if (std.mem.eql(u8, sig, "i")) return "i32";
    if (std.mem.eql(u8, sig, "x")) return "i64";
    if (std.mem.eql(u8, sig, "t")) return "u64";
    if (std.mem.eql(u8, sig, "d")) return "f64";

    if (is_param) return "anytype";
    return "proxy.MethodResult";
}
