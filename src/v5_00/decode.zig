const mqtt = @import("../mqtt.zig");

pub const property = @import("decode/property.zig");

pub const PublishPropertyDecoder = property.PublishPropertyDecoder;
pub const PubackPropertyDecoder = property.PubackPropertyDecoder;
pub const SubscribePropertyDecoder = property.SubscribePropertyDecoder;

const v5_00 = mqtt.v5_00;

/// Decodes an MQTT v.5 PUBLISH message contained in the given decoder.
pub fn publish(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
    id_idx: ?*u32,
) !struct { mqtt.Publish, PublishPropertyDecoder } {
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

test {
    _ = property;
}
