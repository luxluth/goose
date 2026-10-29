const std = @import("std");
const goose = @import("goose");
const proxy = goose.proxy;
const GStr = goose.core.value.GStr;
const GPath = goose.core.value.GPath;
const GSig = goose.core.value.GSig;
const GUFd = goose.core.value.GUFd;
const GVariant = goose.core.value.GVariant;
pub const PropertiesProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) PropertiesProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties") };
    }

    pub fn Get(self: PropertiesProxy, interface_name: GStr, property_name: GStr) !GVariant {
        var res = try self.inner.call("Get", .{ interface_name, property_name });
        defer res.deinit();
        return res.expectAlloc(GVariant);
    }

    pub fn GetAll(self: PropertiesProxy, interface_name: GStr) !std.StringHashMap(GVariant) {
        var res = try self.inner.call("GetAll", .{interface_name});
        defer res.deinit();
        return res.expectAlloc(std.StringHashMap(GVariant));
    }

    pub fn Set(self: PropertiesProxy, interface_name: GStr, property_name: GStr, value: GVariant) !void {
        var res = try self.inner.call("Set", .{ interface_name, property_name, value });
        defer res.deinit();
    }

    pub fn connectPropertiesChanged(
        self: PropertiesProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct { GStr, std.StringHashMap(GVariant), []const GStr }) void,
    ) !void {
        try self.inner.connectSignal(struct { GStr, std.StringHashMap(GVariant), []const GStr }, "PropertiesChanged", ctx, callback);
    }
};

pub const IntrospectableProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) IntrospectableProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Introspectable") };
    }

    pub fn Introspect(self: IntrospectableProxy) !GStr {
        var res = try self.inner.call("Introspect", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }
};

pub const PeerProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) PeerProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Peer") };
    }

    pub fn Ping(self: PeerProxy) !void {
        var res = try self.inner.call("Ping", .{});
        defer res.deinit();
    }

    pub fn GetMachineId(self: PeerProxy) !GStr {
        var res = try self.inner.call("GetMachineId", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }
};

pub const UPowerProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) UPowerProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower") };
    }

    pub fn EnumerateDevices(self: UPowerProxy) ![]const GPath {
        var res = try self.inner.call("EnumerateDevices", .{});
        defer res.deinit();
        return res.expectAlloc([]const GPath);
    }

    pub fn EnumerateKbdBacklights(self: UPowerProxy) ![]const GPath {
        var res = try self.inner.call("EnumerateKbdBacklights", .{});
        defer res.deinit();
        return res.expectAlloc([]const GPath);
    }

    pub fn GetDisplayDevice(self: UPowerProxy) !GPath {
        var res = try self.inner.call("GetDisplayDevice", .{});
        defer res.deinit();
        return res.expectAlloc(GPath);
    }

    pub fn GetCriticalAction(self: UPowerProxy) !GStr {
        var res = try self.inner.call("GetCriticalAction", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }

    pub fn connectDeviceAdded(
        self: UPowerProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct { GPath }) void,
    ) !void {
        try self.inner.connectSignal(struct { GPath }, "DeviceAdded", ctx, callback);
    }
    pub fn connectDeviceRemoved(
        self: UPowerProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct { GPath }) void,
    ) !void {
        try self.inner.connectSignal(struct { GPath }, "DeviceRemoved", ctx, callback);
    }
};
