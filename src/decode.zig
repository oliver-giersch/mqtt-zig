//! Generic (version-agnostic) MQTT type decoding functions.

const mqtt = @import("mqtt.zig");

/// Decodes the given message fixed header byte.
pub fn msgHeader(
    byte: u8,
    comptime expected: ?mqtt.MessageType,
) !mqtt.Header.Byte {
    const msg_type = try msgType(@truncate(byte >> 4));
    if (comptime expected) |e| {
        if (msg_type != e)
            return error.UnexpectedMsgType;
    }

    const msg_flags = try msgFlags(msg_type, @truncate(byte));
    return .{ .msg_type = msg_type, .msg_flags = msg_flags };
}

/// Decodes the given message type bits.
pub fn msgType(bits: u4) mqtt.InvalidMessageType!mqtt.MessageType {
    if (bits == 0)
        return error.InvalidMessageType;
    return @enumFromInt(bits);
}

/// Decodes the given message flags and validates them for the given message
/// type.
pub fn msgFlags(
    msg_type: mqtt.MessageType,
    byte: u4,
) mqtt.InvalidMessageFlags!mqtt.MessageFlags {
    // The QoS is encoded at bits 1 and 2.
    _ = try mqtt.decode.qos(@truncate(byte >> 1));
    const flags: mqtt.MessageFlags = @bitCast(byte);

    const expected = mqtt.MessageFlags.requiredFor(msg_type) orelse return flags;
    return if (flags.eql(expected))
        flags
    else
        error.InvalidFlags;
}

/// Decodes the given QoS bits.
pub fn qos(bits: u2) mqtt.InvalidQos!mqtt.Qos {
    if (bits == 3)
        return error.InvalidQos;
    return @enumFromInt(bits);
}

/// The namespace for CONNECT message decoding
///
/// # Examples
///
/// ```
/// var streaming = mqtt.Decoder.streaming(buf);
/// const header = try streaming.splitHeaderType(.connect);
///
/// var decoder = try decoder.splitPacket(&header);
/// const version = try mqtt.decode.connect.version(&decoder);
/// if (version == .v3_11) {
///     const connect = try mqtt.v3_11.decode.connect(&decoder, true);
///     // ...
/// } else if (version == .v5) {
///     const connect = try mqtt.v5.decode.connect(&decoder, true);
///     // ...
/// }
/// ```
pub const connect = struct {
    /// Decodes the CONNECT message MQTT version and validates the supplied
    /// protocol name.
    pub fn version(decoder: *mqtt.Decoder) mqtt.Decoder.Error(mqtt.InvalidVersion)!mqtt.Version {
        const protocol_name = decoder.splitByteStringLength(4) catch |err| return switch (err) {
            error.UnexpectedLength => error.InvalidProtocolName,
            else => |other| other,
        };

        if (!mqtt.eql("MQTT", protocol_name))
            return error.InvalidProtocolName;

        const version_byte = try decoder.split(u8);
        return switch (version_byte) {
            4 => mqtt.Version.v3_11,
            5 => mqtt.Version.v5,
            else => return error.InvalidProtocolVersion,
        };
    }

    /// Decodes the CONNECT message variable header.
    pub fn variableHeader(decoder: *mqtt.Decoder) !struct { mqtt.ConnectFlags, u16 } {
        const byte = try decoder.split(u8);
        const flags = try connectFlags(byte);
        const keep_alive = try decoder.split(u16);

        return .{ flags, keep_alive };
    }

    pub fn will(decoder: *mqtt.Decoder, flags: mqtt.ConnectFlags) !mqtt.Will {
        const topic = try decoder.splitUtf8String();
        const payload = try decoder.splitByteString();

        return .{
            .retain = flags.will_retain,
            .qos = flags.will_qos,
            .topic = topic,
            .payload = payload,
        };
    }

    pub fn auth(decoder: *mqtt.Decoder, flags: mqtt.ConnectFlags) !mqtt.Auth {
        const user = try decoder.splitUtf8String();
        if (flags.pass_flag) {
            const pass = try decoder.splitByteString();
            return .{ .full = .{ .user = user, .pass = pass } };
        } else {
            return .{ .user_only = user };
        }
    }

    fn connectFlags(byte: u8) !mqtt.ConnectFlags {
        const bits = struct {
            const reserved = 0x1 << 0;
            const clean_session = 0x1 << 1;
            const will = struct {
                const flag = 0x1 << 2;
                const qos_shift = 3;
                const qos_mask = 0b11 << qos_shift;
                const retain = 0x1 << 5;
                const mask = qos_mask | retain;
            };
            const pass_flag = 0x1 << 6;
            const user_flag = 0x1 << 7;
        };

        // c.f. MQTT §3.1.2-3
        if ((byte & bits.reserved) != 0)
            return error.InvalidConnectFlags;

        const clean_session = (byte & bits.clean_session) != 0;
        const will_flag = (byte & bits.will.flag) != 0;

        // c.f. MQTT §3.1.2-11
        if (!will_flag and ((byte & bits.will.mask)) != 0)
            return error.InvalidConnectFlags;

        const will_qos = mqtt.decode.qos(@truncate(byte >> bits.will.qos_shift)) catch
            return error.InvalidConnectFlags;
        const will_retain = (byte & bits.will.retain) != 0;

        const user_flag = (byte & bits.user_flag) != 0;
        const pass_flag = (byte & bits.pass_flag) != 0;
        // c.f. MQTT §3.1.2-22
        if (pass_flag and !user_flag)
            return error.InvalidConnectFlags;

        return .{
            .clean_session = clean_session,
            .will_flag = will_flag,
            .will_qos = will_qos,
            .will_retain = will_retain,
            .pass_flag = pass_flag,
            .user_flag = user_flag,
        };
    }
};

pub fn numbered(comptime msg_type: mqtt.MessageType, decoder: *mqtt.Decoder) !mqtt.NumberedPacket(msg_type) {
    const packet_id = try decoder.splitPacketID();
    try decoder.finalize();
    return .{
        .packet_id = packet_id,
    };
}

const testing = @import("std").testing;

test "decode header" {
    var streaming = mqtt.Decoder.streaming(&.{ 0x10, 0x10 });
    const header = try streaming.splitHeader(.connect);

    try testing.expectEqual(header.msg_type, .connect);
    try testing.expectEqual(header.remaining_len.val, 0x10);
    try testing.expectError(error.IncompleteBuffer, streaming.splitPacket(&header));
}
