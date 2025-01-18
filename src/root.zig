const std = @import("std");
pub const value = @import("value.zig");

const Value = value.Value;
const Allocator = std.mem.Allocator;

const HeaderFieldType = enum {};

const HeaderField = union(HeaderFieldType) {};

const MessageHeader = struct {
    endianess: u8,
    message_type: u8,
    flags: u8,
    proto_version: u8,

    body_length: u32,
    serial: u32,

    header_fields: []HeaderField,
};
