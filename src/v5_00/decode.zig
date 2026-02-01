//! Decoding of MQTT v5 messages.

const mqtt = @import("../mqtt.zig");

pub const property = @import("decode/property.zig");

pub const ConnectPropertyDecoder = property.ConnectPropertyDecoder;
pub const WillPropertyDecoder = property.WillPropertyDecoder;
pub const PublishPropertyDecoder = property.PublishPropertyDecoder;
pub const PubackPropertyDecoder = property.PubackPropertyDecoder;
pub const SubscribePropertyDecoder = property.SubscribePropertyDecoder;

const v5_00 = mqtt.v5_00;

/// Decodes an MQTT v5 PUBLISH message contained in the given decoder.
///
/// Asserts, that the decoder has already split off and validated the MQTT
/// protocol version.
pub fn connect(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
    strict: bool,
) !struct { v5_00.Connect, ConnectPropertyDecoder } {
    mqtt.assert(header.msg_type == .connect);
    mqtt.assert(decoder.len() == header.remaining_len.val - mqtt.Version.byte_count);

    const flags, const keep_alive = try mqtt.decode.connect.variableHeader(decoder);
    const client_id = try decoder.splitUtf8String();
    mqtt.validateClientID(client_id, strict) catch return error.InvalidClientId;

    // Decode the optional client will message and split off a separate decoder
    // for the will properties.
    const will = if (flags.will_flag) block: {
        const will = try mqtt.decode.connect.will(decoder, flags);
        const will_decoder: WillPropertyDecoder = try .splitOff(decoder);
        break :block .{ will, will_decoder };
    } else null;

    const auth = if (flags.user_flag)
        try mqtt.decode.connect.auth(decoder, flags)
    else
        null;

    const property_decoder: ConnectPropertyDecoder = try .splitOff(decoder);
    try decoder.finalize();

    const msg: v5_00.Connect = .{
        .clean_start = flags.clean_session,
        .will = will,
        .auth = auth,
        .keep_alive = keep_alive,
        .client_id = client_id,
    };

    return .{ msg, property_decoder };
}

/// Decodes an MQTT v5 PUBLISH message contained in the given decoder.
pub fn publish(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
    id_idx: ?*u32,
) !struct { mqtt.v5_00.Publish, PublishPropertyDecoder } {
    mqtt.assert(header.msg_type == .publish);

    const topic, const packet_id = try mqtt.decode.publish.variableHeader(
        decoder,
        header,
        id_idx,
    );

    const property_decoder: PublishPropertyDecoder = try .splitOff(decoder);
    const payload = try decoder.splitUtf8String();

    try decoder.finalize();
    const msg: mqtt.Publish = .{
        .flags = header.msg_flags,
        .topic = topic,
        .packet_id = packet_id,
        .payload = payload,
    };

    return .{ msg, property_decoder };
}

pub fn puback(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !struct { v5_00.Puback, PubackPropertyDecoder } {
    mqtt.assert(header.msg_type == .puback);

    const packet_id: mqtt.PacketID = try decoder.splitPacketID();
    const reason_code: v5_00.Puback.ReasonCode = switch (try decoder.split(u8)) {
        0x0 => .success,
        0x10 => .no_matching_subscribers,
        0x80 => .unspecified_error,
        0x83 => .implementation_specific_error,
        0x87 => .not_authorized,
        0x90 => .topic_name_invalid,
        0x91 => .packet_id_in_use,
        0x97 => .quota_exceeded,
        0x99 => .payload_format_invalid,
        else => return error.InvalidReasonCode,
    };

    const msg: v5_00.Puback = .{
        .packet_id = packet_id,
        .reason_code = reason_code,
    };
    const property_decoder: PubackPropertyDecoder = try .splitOff(decoder);

    return .{ msg, property_decoder };
}

pub fn subscribe(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !struct { mqtt.Subscribe, property.SubscribePropertyDecoder, SubDecoder } {
    mqtt.assert(header.msg_type == .subscribe);

    const sub = mqtt.Subscribe{ .packet_id = try decoder.splitPacketId() };
    const property_decoder: SubscribePropertyDecoder = try .splitOff(decoder);
    const sub_decoder = SubDecoder{};
    try decoder.finalize();

    return .{ sub, property_decoder, sub_decoder };
}

pub const SubDecoder = struct {
    const Self = @This();
};

const testing = @import("std").testing;

test {
    _ = property;
}

test "decode v5.00 CONNECT" {
    const buf: []const u8 = &.{
        0x10, 0x32, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x05, 0xC2, 0x00,
        0x3C, 0x13, 0x11, 0x00, 0x00, 0x00, 0x3C, 0x26, 0x00, 0x03, 0x61,
        0x70, 0x70, 0x00, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x0B, 0x63,
        0x6C, 0x69, 0x65, 0x6E, 0x74, 0x2D, 0x30, 0x30, 0x31, 0x00, 0x08,
        0x75, 0x73, 0x65, 0x72, 0x6E, 0x61, 0x6D, 0x65, 0x00, 0x08, 0x70,
        0x61, 0x73, 0x73, 0x77, 0x6F, 0x72, 0x64,
    };

    var streaming = mqtt.Decoder.streaming(buf);
    const header = try streaming.splitHeader(null);

    try testing.expectEqual(.connect, header.msg_type);
    try testing.expectEqual(0x32, header.remaining_len.val);

    var decoder = try streaming.splitPacket(&header);
    _ = try mqtt.decode.connect.version(&decoder);

    const msg, var property_decoder = try mqtt.v5_00.decode.connect(
        &decoder,
        &header,
        true,
    );

    try testing.expectEqual(true, msg.clean_start);
    try testing.expectEqual(60, msg.keep_alive);
    try testing.expectEqual(null, msg.will);
    try testing.expectEqual(null, msg.auth);

    const property1 = try property_decoder.decodeNext();
    var expected: ConnectPropertyDecoder.Payload = .{ .session_expiry_interval = 60 };
    try testing.expectEqual(expected, property1);
    const property2 = try property_decoder.decodeNext();
    expected = .{ .user_property = .{ .key = "app", .val = "test" } };
    try testing.expectEqual(expected, property2);
}
