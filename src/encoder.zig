//! A generic byte stream encoder for MQTT data types.

const Self = @This();

const mqtt = @import("mqtt.zig");

buf: []u8,

/// Writes the given MQTT header into the underlying buffer.
pub fn writeHeader(self: *Self, header: *const mqtt.Header) void {
    self.writeU8(@bitCast(mqtt.Header.Byte{
        .msg_flags = header.msg_flags,
        .msg_type = header.msg_type,
    }));
    self.writeUvar(header.remaining_len);
}

pub fn writeU8(self: *Self, val: u8) void {
    const b = self.comptimeSplitBuf(@sizeOf(u8));
    b.*[0] = val;
}

pub fn writeU16(self: *Self, val: u16) void {
    const b = self.comptimeSplitBuf(@sizeOf(u16));
    b.* = nativeToBig(u16, val);
}

pub fn writeU32(self: *Self, val: u32) void {
    const b = self.comptimeSplitBuf(@sizeOf(u32));
    b.* = nativeToBig(u32, val);
}

pub fn writeUvar(self: *Self, uvar: mqtt.uvar) void {
    const bytes = uvar.encode();
    const slice = bytes.slice();

    for (slice, self.splitBuf(slice.len)) |*src, *dst| {
        dst.* = src.*;
    }
}

pub fn writeByteStr(self: *Self, string: []const u8) void {
    mqtt.assert(string.len <= mqtt.string.max_len);
    self.writeU16(@truncate(string.len));
    @memcpy(self.splitBuf(string.len), string);
}

inline fn comptimeSplitBuf(self: *Self, comptime bytes: usize) *[bytes]u8 {
    const b = self.splitBuf(bytes);
    return b[0..bytes];
}

inline fn splitBuf(self: *Self, bytes: usize) []u8 {
    const b = self.buf[0..bytes];
    self.buf = self.buf[bytes..];
    return b;
}

fn nativeToBig(comptime T: type, val: T) [@sizeOf(T)]u8 {
    if (mqtt.target_endian == .big)
        return @bitCast(val);
    var bytes: [@sizeOf(T)]u8 = @bitCast(val);
    mqtt.reverseBytes(&bytes);
    return @bitCast(bytes);
}
