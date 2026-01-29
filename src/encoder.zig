//! A generic byte stream encoder for MQTT data types.

const mqtt = @import("mqtt.zig");

const Self = @This();

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
    b.* = nativeToBigEndian(u16, val);
}

pub fn writeU32(self: *Self, val: u32) void {
    const b = self.comptimeSplitBuf(@sizeOf(u32));
    b.* = nativeToBigEndian(u32, val);
}

pub fn writeUvar(self: *Self, uvar: mqtt.uvar) void {
    const bytes = uvar.encode();
    const slice = bytes.slice();

    if (slice.len > 4) unreachable;

    // Do a manual memcpy, since there will be at most 4 bytes to copy.
    for (slice, self.splitBuf(slice.len)) |*src, *dst|
        dst.* = src.*;
}

pub fn writeByteStr(self: *Self, string: []const u8) void {
    mqtt.assert(string.len <= mqtt.string.max_len);
    self.writeU16(@truncate(string.len));
    @memcpy(self.splitBuf(string.len), string);
}

fn comptimeSplitBuf(
    self: *Self,
    comptime byte_count: usize,
) *[byte_count]u8 {
    const bytes = self.splitBuf(byte_count);
    return bytes[0..byte_count];
}

fn splitBuf(self: *Self, byte_count: usize) []u8 {
    mqtt.assert(byte_count <= self.buf.len);
    const bytes = self.buf[0..byte_count];
    self.buf = self.buf[byte_count..];

    return bytes;
}

fn nativeToBigEndian(comptime T: type, val: T) [@sizeOf(T)]u8 {
    if (mqtt.target_endian == .big)
        return @bitCast(val);

    var bytes: [@sizeOf(T)]u8 = @bitCast(val);
    mqtt.reverseBytes(&bytes);

    return @bitCast(bytes);
}
