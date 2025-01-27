pub const std = @import("std");
pub const value = @import("value.zig");
pub const convertInteger = @import("utils.zig").convertInteger;

const Value = value.Value;
const Allocator = std.mem.Allocator;

pub const HeaderFieldValueTag = enum {
    /// The object to send a call to, or the object a signal is emitted from.
    /// The special path `/org/freedesktop/DBus/Local` is reserved; implementations
    /// should not send messages with this path, and the reference implementation
    /// of the bus daemon will disconnect any application that attempts to do so.
    /// This header field is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Path,
    ///  The interface to invoke a method call on, or that a signal is emitted from.
    ///  Optional for method calls, required for signals.
    ///  The special interface `org.freedesktop.DBus.Local` is reserved;
    ///  implementations should not send messages with this interface,
    ///  and the reference implementation of the bus daemon will disconnect any
    ///  application that attempts to do so. This header field is controlled by
    ///  the message sender.
    ///
    ///  **Required In**: Signal
    Interface,
    ///  The member, either the method name or signal name. This header field
    ///  is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Member,
    /// The name of the error that occurred, for errors
    ///
    /// **Required In**: `Error`
    ErrorName,
    ///  The serial number of the message this message is a reply to.
    ///  (The serial number is the second UINT32 in the header.)
    ///  This header field is controlled by the message sender.
    ///
    ///  **Required In**: `Error`, `MethodReturn`
    ReplySerial,
    ///  The name of the connection this message is intended for. This field is
    ///  usually only meaningful in combination with the message bus¹ but other
    ///  servers may define their own meanings for it. This header field is
    ///  controlled by the message sender.
    ///
    ///  ¹see [the section called "Message Bus Specification"](https://dbus.freedesktop.org/doc/dbus-specification.html#message-bus)
    ///
    /// **~optional**
    Destination,
    /// Unique name of the sending connection. This field is usually only
    /// meaningful in combination with the message bus, but other servers may
    /// define their own meanings for it. On a message bus, this header field
    /// is controlled by the message bus, so it is as reliable and trustworthy
    /// as the message bus itself. Otherwise, this header field is controlled
    /// by the message sender, unless there is out-of-band information that
    /// indicates otherwise.
    ///
    /// **~optional**
    Sender,
    /// The signature of the message body.
    /// If omitted, it is assumed to be the empty signature "" (i.e. the body must be 0-length).
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    Signature,
    /// The number of Unix file descriptors that accompany the message.
    /// If omitted, it is assumed that no Unix file descriptors accompany the message.
    /// The actual file descriptors need to be transferred via platform specific
    /// mechanism out-of-band. They must be sent at the same time as part of the
    /// message itself. They may not be sent before the first byte of the message
    /// itself is transferred or after the last byte of the message itself.
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    UnixFds,
};

pub const HeaderFieldValue = union(HeaderFieldValueTag) {
    Path: [:0]const u8,
    Interface: [:0]const u8,
    Member: [:0]const u8,
    ErrorName: [:0]const u8,
    ReplySerial: u32,
    Destination: [:0]const u8,
    Sender: [:0]const u8,
    Signature: [:0]const u8,
    UnixFds: u32,

    pub fn ser(self: HeaderFieldValue, buffer: *std.ArrayList(u8)) !void {
        const Sig = Value.Signature();
        const Str = Value.String();
        const Path = Value.ObjectPath();
        const U32 = Value.Uint32();

        switch (self) {
            .UnixFds, .ReplySerial => |x| {
                try U32.new(x).ser(buffer);
            },
            .Path => |v| {
                try Path.new(v).ser(buffer);
            },
            .Interface,
            .Member,
            .ErrorName,
            .Destination,
            .Sender,
            => |v| {
                try Str.new(v).ser(buffer);
            },
            .Signature,
            => |v| {
                try Sig.new(v).ser(buffer);
            },
        }
    }
};

pub const HeaderFieldCode = enum(u8) {
    Invalid = 0x0,
    Path = 0x1,
    Interface = 0x2,
    Member = 0x3,
    ErrorName = 0x4,
    ReplySerial = 0x5,
    Destination = 0x6,
    Sender = 0x7,
    Signature = 0x8,
    UnixFds = 0x9,
};

pub const HeaderField = struct {
    code: u8,
    value: HeaderFieldValue,
};

/// Message type
pub const MessageType = enum(u8) {
    /// This is an invalid type.
    Invalid = 0,
    /// Method call. This message type may prompt a reply.
    MethodCall = 1,
    /// Method reply with returned data.
    MethodReturn = 2,
    /// Error reply. If the first argument exists and is a string, it is an error message.
    Error = 3,
    /// Signal emission.
    Signal = 4,
};

pub const MessageFlag = enum(u8) {
    __EMPTY = 0x0,
    /// This message does not expect method return replies or error replies,
    /// even if it is of a type that can have a reply; the reply should be omitted.
    /// Note that `METHOD_CALL` is the only message type currently defined in
    /// this specification that can expect a reply, so the presence or absence
    /// of this flag in the other three message types that are currently documented
    /// is meaningless: replies to those message types should not be sent, whether
    /// this flag is present or not.
    NoReplyExpected = 0x1,
    /// The bus must not launch an owner for the destination name in response
    /// to this message.
    NoAutoStart = 0x2,
    /// This flag may be set on a method call message to inform the receiving
    /// side that the caller is prepared to wait for interactive authorization,
    /// which might take a considerable time to complete. For instance, if this
    /// flag is set, it would be appropriate to query the user for passwords or
    /// confirmation via Polkit or a similar framework.
    ///
    /// This flag is only useful when unprivileged code calls a more privileged
    /// method call, and an authorization framework is deployed that allows possibly
    /// interactive authorization. If no such framework is deployed it has no
    /// effect. This flag should not be set by default by client implementations.
    /// If it is set, the caller should also set a suitably long timeout on
    /// the method call to make sure the user interaction may complete.
    /// This flag is only valid for method call messages, and shall be
    /// ignored otherwise.
    ///
    /// Interaction that takes place as a part of the effect of the method being
    /// called is outside the scope of this flag, even if it could also be
    /// characterized as authentication or authorization. For instance, in a
    /// method call that directs a network management service to attempt to connect
    /// to a virtual private network, this flag should control how the network
    /// management service makes the decision
    /// "is this user allowed to change system network configuration?",
    /// but it should not affect how or whether the network management service
    /// interacts with the user to obtain the credentials that are required
    /// for access to the VPN.
    ///
    /// If a this flag is not set on a method call, and a service determines
    /// that the requested operation is not allowed without interactive authorization,
    /// but could be allowed after successful interactive authorization, it may
    /// return the `org.freedesktop.DBus.Error.InteractiveAuthorizationRequired` error.
    ///
    /// The absence of this flag does not guarantee that interactive authorization
    /// will not be applied, since existing services that pre-date this flag
    /// might already use interactive authorization. However, existing D-Bus APIs
    /// that will use interactive authorization should document that the call may
    /// take longer than usual, and new D-Bus APIs should avoid interactive authorization
    /// in the absence of this flag.
    AllowInteractiveAuthorization = 0x4,
};

pub const MessageHeader = struct {
    /// Endianness flag; ASCII 'l' for little-endian or ASCII 'B' for big-endian.
    /// Both header and body are in this endianness.
    /// By default this library default to big-endian
    endianess: u8 = 'B',
    /// Message type. Unknown types must be ignored
    message_type: u8,
    /// Bitwise OR of flags. Unknown flags must be ignored.
    flags: u8,
    /// Major protocol version of the sending application. If the major protocol
    /// version of the receiving application does not match, the applications
    /// will not be able to communicate and the D-Bus connection must be
    /// disconnected. The major protocol version for this version of the
    /// specification is 1.
    proto_version: u8,

    /// Length in bytes of the message body, starting from the end of the header.
    /// The header ends after its alignment padding to an 8-boundary.
    body_length: u32,
    /// The serial of this message, used as a cookie by the sender to identify
    /// the reply corresponding to this request. This must not be zero.
    serial: u32,

    /// An array of zero or more header fields where the byte is the field code,
    /// and the variant is the field value. The message type determines which
    /// fields are required.
    header_fields: []const HeaderField,

    ///  The length of the header must be a multiple of 8, allowing the body to begin
    ///  on an 8-byte boundary when storing the entire message in a single buffer.
    ///  If the header does not naturally end on an 8-byte boundary up to 7 bytes
    ///  of nul-initialized alignment padding must be added.
    pub fn pack(self: MessageHeader, allocator: std.mem.Allocator) !std.ArrayList(u8) {
        const Byte = Value.Byte();
        const U32 = Value.Uint32();

        var buffer = std.ArrayList(u8).init(allocator);

        try Byte.new(self.endianess).ser(&buffer);
        try Byte.new(self.message_type).ser(&buffer);
        try Byte.new(self.flags).ser(&buffer);
        try Byte.new(self.proto_version).ser(&buffer);

        try U32.new(self.body_length).ser(&buffer); // Only big endian for now
        try U32.new(self.serial).ser(&buffer);

        for (self.header_fields) |field| {
            try buffer.append(field.code);
            try field.value.ser(&buffer);
        }

        const header_length = buffer.items.len;
        const padding_needed = (8 - (header_length % 8)) % 8;
        if (padding_needed > 0) {
            try buffer.appendNTimes(0, padding_needed);
        }

        return buffer;
    }
};

pub const Message = struct {
    header: MessageHeader,
    body: []const u8,

    pub fn new(header: MessageHeader, body: []const u8) Message {
        return Message{
            .header = header,
            .body = body,
        };
    }

    pub fn pack(self: Message, allocator: std.mem.Allocator) !std.ArrayList(u8) {
        var headerBytes = try self.header.pack(allocator);
        try headerBytes.appendSlice(self.body);

        return headerBytes;
    }
};
