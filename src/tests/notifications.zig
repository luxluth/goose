const std = @import("std");
const goose = @import("goose");
const proxy = goose.proxy;
const GStr = goose.core.value.GStr;
const GPath = goose.core.value.GPath;
const GSig = goose.core.value.GSig;
const GUFd = goose.core.value.GUFd;
const GVariant = goose.core.value.GVariant;
pub const NotificationsProxy = struct {
  inner: proxy.Proxy,

  pub fn init(conn: *goose.Connection) NotificationsProxy {
      return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications") };
}

   pub fn GetCapabilities(self: NotificationsProxy) ![]const GStr {
      var res = try self.inner.call("GetCapabilities", .{});
      defer res.deinit();
        return res.expectAlloc([]const GStr);
    }

   pub fn Notify(self: NotificationsProxy, appName: GStr, replacesId: u32, appIcon: GStr, summary: GStr, body: GStr, actions: []const GStr, hints: std.StringHashMap(GVariant), expireTimeout: i32) !u32 {
      var res = try self.inner.call("Notify", .{ appName, replacesId, appIcon, summary, body, actions, hints, expireTimeout});
      defer res.deinit();
        return res.expectAlloc(u32);
    }

   pub fn CloseNotification(self: NotificationsProxy, id: u32) !void {
      var res = try self.inner.call("CloseNotification", .{ id});
      defer res.deinit();
    }

   pub fn GetServerInformation(self: NotificationsProxy) !GStr {
      var res = try self.inner.call("GetServerInformation", .{});
      defer res.deinit();
        return res.expectAlloc(GStr);
    }

    pub fn connectNotificationClosed(
        self: NotificationsProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct{ u32, u32}) void,
  ) !void {
      try self.inner.connectSignal(struct{ u32, u32}, "NotificationClosed", ctx, callback);
  }
    pub fn connectActionInvoked(
        self: NotificationsProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct{ u32, GStr}) void,
  ) !void {
      try self.inner.connectSignal(struct{ u32, GStr}, "ActionInvoked", ctx, callback);
  }
    pub fn connectNotificationReplied(
        self: NotificationsProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct{ u32, GStr}) void,
  ) !void {
      try self.inner.connectSignal(struct{ u32, GStr}, "NotificationReplied", ctx, callback);
  }
    pub fn connectActivationToken(
        self: NotificationsProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct{ u32, GStr}) void,
  ) !void {
      try self.inner.connectSignal(struct{ u32, GStr}, "ActivationToken", ctx, callback);
  }
};

pub const PropertiesProxy = struct {
  inner: proxy.Proxy,

  pub fn init(conn: *goose.Connection) PropertiesProxy {
      return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.DBus.Properties") };
}

   pub fn Get(self: PropertiesProxy, interface_name: GStr, property_name: GStr) !GVariant {
      var res = try self.inner.call("Get", .{ interface_name, property_name});
      defer res.deinit();
        return res.expectAlloc(GVariant);
    }

   pub fn Set(self: PropertiesProxy, interface_name: GStr, property_name: GStr, value: GVariant) !void {
      var res = try self.inner.call("Set", .{ interface_name, property_name, value});
      defer res.deinit();
    }

   pub fn GetAll(self: PropertiesProxy, interface_name: GStr) !std.StringHashMap(GVariant) {
      var res = try self.inner.call("GetAll", .{ interface_name});
      defer res.deinit();
        return res.expectAlloc(std.StringHashMap(GVariant));
    }

    pub fn connectPropertiesChanged(
        self: PropertiesProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), struct{ GStr, std.StringHashMap(GVariant), []const GStr}) void,
  ) !void {
      try self.inner.connectSignal(struct{ GStr, std.StringHashMap(GVariant), []const GStr}, "PropertiesChanged", ctx, callback);
  }
};

pub const IntrospectableProxy = struct {
  inner: proxy.Proxy,

  pub fn init(conn: *goose.Connection) IntrospectableProxy {
      return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.DBus.Introspectable") };
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
      return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.DBus.Peer") };
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

