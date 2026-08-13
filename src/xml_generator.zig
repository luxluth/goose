const std = @import("std");
const core = @import("core.zig");
const Value = core.value.Value;

pub const xml_prelude =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
;
// .. Introspection XML for actual interfaces gets sandwiched inbetween these two fragments ..
pub const xml_postlude =
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect">
    \\      <arg name="xml_data" type="s" direction="out"/>
    \\    </method>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Properties">
    \\    <method name="Get">
    \\      <arg name="interface_name" type="s" direction="in"/>
    \\      <arg name="property_name" type="s" direction="in"/>
    \\      <arg name="value" type="v" direction="out"/>
    \\    </method>
    \\    <method name="Set">
    \\      <arg name="interface_name" type="s" direction="in"/>
    \\      <arg name="property_name" type="s" direction="in"/>
    \\      <arg name="value" type="v" direction="in"/>
    \\    </method>
    \\    <method name="GetAll">
    \\      <arg name="interface_name" type="s" direction="in"/>
    \\      <arg name="props" type="a{sv}" direction="out"/>
    \\    </method>
    \\    <signal name="PropertiesChanged">
    \\      <arg name="interface_name" type="s"/>
    \\      <arg name="changed_properties" type="a{sv}"/>
    \\      <arg name="invalidated_properties" type="as"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

/// Generates a D-Bus introspection XML string for a Zig type T.
pub fn generateIntrospectionXml(allocator: std.mem.Allocator, comptime T: type, interface_name: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer out.deinit(allocator);

    try out.print(allocator, "  <interface name=\"{s}\">\n", .{interface_name});

    // Methods
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        const field_val = @field(T, decl.name);
        const field_type = @TypeOf(field_val);

        if (@typeInfo(field_type) == .@"fn") {
            if (!std.mem.eql(u8, decl.name, "init")) {
                const fn_info = @typeInfo(field_type).@"fn";
                // Check if it looks like a method (first arg is *T)
                if (fn_info.params.len > 0 and fn_info.params[0].type == *T) {
                    try out.print(allocator, "    <method name=\"{s}\">\n", .{decl.name});

                    // Args (skip first which is self)
                    inline for (fn_info.params[1..], 0..) |param, i| {
                        if (param.type) |PT| {
                            const sig = try getSignature(allocator, PT);
                            defer allocator.free(sig);
                            try out.print(allocator, "      <arg name=\"arg{d}\" type=\"{s}\" direction=\"in\"/>\n", .{ i, sig });
                        }
                    }

                    // Return type
                    const RetT = fn_info.return_type.?;
                    const CleanRetT = switch (@typeInfo(RetT)) {
                        .error_union => |eu| eu.payload,
                        else => RetT,
                    };

                    if (CleanRetT != void) {
                        const sig = try getSignature(allocator, CleanRetT);
                        defer allocator.free(sig);
                        try out.print(allocator, "      <arg name=\"ret\" type=\"{s}\" direction=\"out\"/>\n", .{sig});
                    }

                    try out.appendSlice(allocator, "    </method>\n");
                }
            }
        }
    }

    // Signals
    inline for (std.meta.fields(T)) |field| {
        const FieldType = field.type;
        if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "__is_goose_signal")) {
            const PayloadT = FieldType.PayloadType;
            try out.print(allocator, "    <signal name=\"{s}\">\n", .{@field(field, "name")});
            if (PayloadT != void) {
                const sig = try getSignature(allocator, PayloadT);
                defer allocator.free(sig);
                try out.print(allocator, "      <arg type=\"{s}\" />\n", .{sig});
            }
            try out.appendSlice(allocator, "    </signal>\n");
        }
    }

    // Properties
    inline for (std.meta.fields(T)) |field| {
        const FieldType = field.type;
        const type_info = @typeInfo(FieldType);

        // Skip signals and connection
        if (type_info == .@"struct" and @hasDecl(FieldType, "__is_goose_signal")) continue;
        if (comptime std.mem.eql(u8, field.name, "conn")) continue;
        if (type_info == .pointer and type_info.pointer.size != .slice) continue; // Skip unsupported pointers

        const is_wrapped = type_info == .@"struct" and @hasDecl(FieldType, "__is_goose_property");
        const access: []const u8 = if (is_wrapped) switch (FieldType.AccessMode) {
            .Read => "read",
            .Write => "write",
            .ReadWrite => "readwrite",
        } else "read";
        const DataType = if (is_wrapped) FieldType.DataType else FieldType;

        const sig = try getSignature(allocator, DataType);
        defer allocator.free(sig);
        try out.print(allocator, "    <property name=\"{s}\" type=\"{s}\" access=\"{s}\"/>\n", .{ field.name, sig, access });
    }

    try out.appendSlice(allocator, "  </interface>\n");

    return try out.toOwnedSlice(allocator);
}

fn getSignature(allocator: std.mem.Allocator, comptime T: type) ![:0]const u8 {
    const len = Value.reprLength(T);
    var sig_buf: [256]u8 = undefined;
    if (len > 256) return error.SignatureTooLong;
    Value.getRepr(T, len, 0, sig_buf[0..len]);
    return try allocator.dupeZ(u8, sig_buf[0..len]);
}
