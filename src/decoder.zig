//! A generic byte stream decoder for MQTT data types.

const mqtt = @import("mqtt.zig");

const Decoder = @This();

///
pub fn Error(comptime error_union: type) type {
    return error_union || mqtt.PacketLengthMismatch;
}

/// The error union for decoding the given MQTT supported type.
pub fn SplitError(comptime T: type) type {
    const invalid_type = "`" ++ @typeName(Decoder) ++ ".split` takes one of [u8|u16|u32|uvar]";
    return switch (T) {
        u8, u16, u32 => error{},
        mqtt.uvar => mqtt.InvalidUvar,
        else => @compileError(invalid_type),
    };
}

pub fn SplitByteStringLengthError(comptime expected: ?u16) type {
    return if (expected == null)
        mqtt.PacketLengthMismatch
    else
        error{UnexpectedLength} || mqtt.PacketLengthMismatch;
}

pub const DecodeHeaderError = mqtt.InvalidMessageHeader || mqtt.InvalidUvar || mqtt.IncompleteBuffer;

/// A streaming MQTT message decoder.
pub const Streaming = struct {
    /// ...
    decoder: Decoder,

    pub fn splitHeader(self: *Decoder.Streaming) DecodeHeaderError!mqtt.Header {
        return self.splitHeaderType(null);
    }

    pub fn splitHeaderType(
        self: *Decoder.Streaming,
        comptime expected: ?mqtt.MessageType,
    ) DecodeHeaderError!mqtt.Header {
        // Split off the fixed header byte and decode it.
        const byte = self.decoder.split(u8) catch
            return error.IncompleteBuffer;
        const header = try mqtt.decode.msgHeader(byte, expected);
        // Split off the variable integer representing the packet's remaining length.
        const remaining_len = self.decoder.split(mqtt.uvar) catch |err| return switch (err) {
            error.PacketLengthMismatch => error.IncompleteBuffer,
            else => |other| other,
        };

        return .{
            .msg_type = header.msg_type,
            .msg_flags = header.msg_flags,
            .remaining_len = remaining_len,
        };
    }

    pub fn splitPacket(
        self: *Decoder.Streaming,
        header: *const mqtt.Header,
    ) mqtt.IncompleteBuffer!Decoder {
        const byte_count = header.packetLen();
        return self.decoder.splitOff(byte_count) catch
            error.IncompleteBuffer;
    }
};

/// The byte buffer containing the encoded MQTT packet contents.
buf: []const u8,
/// The current offset into the original buffer upon construction.
cursor: usize,

/// Returns a new streaming decoder for the given byte slice.
///
/// # Examples
///
/// ```
/// var decoder = mqtt.Decoder.streaming(buf);
///
/// ```
pub fn streaming(buf: []const u8) Decoder.Streaming {
    return .{ .decoder = .{
        .buf = buf,
        .cursor = 0,
    } };
}

pub fn splitOffRest(self: *Decoder) mqtt.Decoder {
    return self.splitOffUnchecked(self.len());
}

/// Splits of a number of the decoder's buffer and wraps them in a
/// separate `Decoder` instance.
pub fn splitOff(
    self: *Decoder,
    byte_count: usize,
) mqtt.PacketLengthMismatch!mqtt.Decoder {
    if (self.len() < byte_count)
        return error.PacketLengthMismatch;
    return self.splitOffUnchecked(byte_count);
}

/// Splits and validates a bool from the decoder's buffer.
pub fn splitBool(self: *Decoder) Error(mqtt.InvalidBool)!bool {
    const byte = try self.split(u8);
    return switch (byte) {
        0 => false,
        1 => true,
        else => error.InvalidBool,
    };
}

/// Splits and validates a packet ID from the decoder's buffer.
pub fn splitPacketID(
    self: *Decoder,
) Error(mqtt.InvalidPacketID)!mqtt.PacketID {
    // c.f. §MQTT-2.3.1-1: packet IDs must be non-zero.
    const val = try self.split(u16);
    return mqtt.PacketID.from(val);
}

/// Splits an integer of the given type from the decoder's buffer.
///
/// Allowed types are:
///     - u8
///     - u16
///     - u32
///     - mqtt.uvar
///
/// # Errors
///
/// Fails, with `IncompleteBuffer`, if the decoder buffer holds insufficient
/// bytes for splitting the specified `T`.
///
/// For `mqtt.uvar`, fails if the decoder buffer holds an invalid uvar value.
pub fn split(self: *Decoder, comptime T: type) Error(SplitError(T))!T {
    if (T == mqtt.uvar) {
        const uvar, const byte_count = mqtt.uvar.decode(self.buf) catch |err| return switch (err) {
            error.IncompleteBuffer => error.PacketLengthMismatch,
            else => |other| other,
        };

        self.buf = self.buf[byte_count..];
        self.cursor += byte_count;

        return uvar;
    }

    const byte_count = @sizeOf(T);
    const bytes = try self.comptimeSplitBuf(byte_count);
    return switch (T) {
        u8 => bytes[0],
        u16, u32 => bigEndianToNative(T, bytes.*),
        else => comptime unreachable,
    };
}

/// Splits a byte string from the decoder's buffer.
pub fn splitByteString(self: *Decoder) mqtt.PacketLengthMismatch![]const u8 {
    return self.splitByteStringLength(null);
}

pub fn splitByteStringLength(
    self: *Decoder,
    comptime expected: ?u16,
) SplitByteStringLengthError(expected)![]const u8 {
    const byte_count = try self.split(u16);
    if (comptime expected) |e| {
        if (byte_count != e)
            return error.UnexpectedLength;
    }

    return self.splitBuf(byte_count);
}

pub fn splitUtf8String(
    self: *Decoder,
) Error(mqtt.string.DecodeError)![]const u8 {
    const bytes = try self.splitByteString();
    try mqtt.string.validate(bytes);
    return bytes;
}

pub fn splitUtf8StringRest(self: *Decoder) mqtt.string.DecodeError![]const u8 {
    const bytes = self.splitBufRest();
    try mqtt.string.validate(bytes);
    return bytes;
}

pub fn splitBufRest(self: *Decoder) []const u8 {
    return self.splitBufUnchecked(self.len());
}

pub fn len(self: *const Decoder) usize {
    return self.buf.len;
}

pub fn finalize(self: *const Decoder) mqtt.PacketLengthMismatch!void {
    if (self.len() != 0)
        return error.PacketLengthMismatch;
}

fn splitOffUnchecked(self: *Decoder, byte_count: usize) Decoder {
    const cursor = self.cursor;
    const buf = self.splitBufUnchecked(byte_count);
    return .{ .buf = buf, .cursor = cursor };
}

fn comptimeSplitBuf(
    self: *Decoder,
    comptime byte_count: usize,
) mqtt.PacketLengthMismatch!*const [byte_count]u8 {
    const bytes = try self.splitBuf(byte_count);
    return bytes[0..byte_count];
}

fn splitBuf(
    self: *Decoder,
    byte_count: usize,
) mqtt.PacketLengthMismatch![]const u8 {
    if (self.len() < byte_count)
        return error.PacketLengthMismatch;
    return self.splitBufUnchecked(byte_count);
}

fn splitBufUnchecked(self: *Decoder, byte_count: usize) []const u8 {
    const bytes = self.buf[0..byte_count];
    self.buf = self.buf[byte_count..];
    self.cursor += byte_count;

    return bytes;
}

fn bigEndianToNative(comptime T: type, bytes: [@sizeOf(T)]u8) T {
    if (mqtt.target_endian == .big)
        return @bitCast(bytes);

    var buf = bytes;
    mqtt.reverseBytes(&buf);
    return @bitCast(buf);
}

const testing = @import("std").testing;

test "split off decoder" {
    var buf: [128]u8 = @splat(0);
    var decoder = mqtt.Decoder{ .buf = &buf };

    const subdecoder = decoder.splitOff(64);
    try testing.expectEqual(decoder.buf.len, 64);
    try testing.expectEqual(decoder.cursor, 64);
    try testing.expectEqual(subdecoder.cursor, 0);
    try testing.expect(@hasDecl(@TypeOf(subdecoder), "splitOff"));
    //const ss = subdecoder.splitOff(5);
    //try tt.expectEqual(ss.cursor, 0);
}
