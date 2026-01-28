//! Decoding of MQTT v3.11 messages.

const mqtt = @import("../mqtt.zig");

const v3_11 = mqtt.v3_11;

// fixme:
// naming? connectLessVersion? connectWithoutVersion? connectNoVersion?
// connectPartial? connectTrunc? connect

pub fn connectWithVersion(decoder: *mqtt.Decoder, strict: bool) !v3_11.Connect {
    const version = try mqtt.decode.connect.version(decoder);
    if (version != .v3_11)
        return error.UnexpectedVersion;
    return connect(decoder, strict);
}

/// Decodes a CONNECT message.
///
/// Assumes, that the MQTT version has already been split off from `decoder`.
pub fn connect(decoder: *mqtt.Decoder, strict: bool) !v3_11.Connect {
    const flags, const keep_alive = try mqtt.decode.connect.varHeader(decoder);
    const client_id = try decoder.splitUtf8String();
    mqtt.validateClientId(client_id, strict) catch return error.InvalidClientId;

    const will = if (flags.will_flag)
        try mqtt.decode.connect.will(decoder, flags)
    else
        null;
    const auth = if (flags.user_flag)
        try mqtt.decode.connect.auth(decoder, flags)
    else
        null;

    return .{
        .clean_session = flags.clean_session,
        .will = will,
        .auth = auth,
        .keep_alive = keep_alive,
        .client_id = client_id,
    };
}

/// Decodes an CONNACK message in `decoder`.
pub fn connack(decoder: *mqtt.Decoder) !v3_11.Connack {
    const session_present = try decoder.splitBool();
    const return_code: v3_11.Connack.ReturnCode = switch (try decoder.split(u8)) {
        0...5 => |rc| block: {
            if (rc != 0 and session_present)
                return error.InvalidConnack;
            break :block @enumFromInt(rc);
        },
        else => return error.InvalidReturnCode,
    };

    return .{
        .session_present = session_present,
        .return_code = return_code,
    };
}

/// Decodes an PUBLISH message contained in `decoder`.
pub fn publish(decoder: *mqtt.Decoder, header: mqtt.Header) !v3_11.Publish {
    const topic = try decoder.splitUtf8String();
    try mqtt.topic.validate(topic);
    const packet_id = if (@intFromEnum(header.msg_flags.qos) != 0)
        try decoder.splitPacketID()
    else
        0;
    const payload = try decoder.splitUtf8StringRest();

    return .{
        .flags = header.msg_flags,
        .topic = topic,
        .packet_id = packet_id,
        .payload = payload,
    };
}

pub fn puback(decoder: *mqtt.Decoder) !v3_11.Puback {
    return mqtt.decode.numbered(.puback, decoder);
}

pub fn pubrel(decoder: *mqtt.Decoder) !v3_11.Pubrel {
    return mqtt.decode.numbered(.pubrel, decoder);
}

pub fn pubcomp(decoder: *mqtt.Decoder) !v3_11.Pubcomp {
    return mqtt.decode.numbered(.pubcomp, decoder);
}

pub fn subscribe(decoder: *mqtt.Decoder) !struct { v3_11.Subscribe, v3_11.decode.SubDecoder } {
    const sub = mqtt.Subscribe{ .packet_id = try decoder.splitPacketID() };
    const sub_decoder = SubDecoder{ .inner = decoder.splitOffRest() };

    return .{ sub, sub_decoder };
}

pub fn suback(decoder: *mqtt.Decoder) !v3_11.Suback {
    const packet_id = try decoder.splitPacketID();
    const return_codes = decoder.splitBufRest();
    for (return_codes) |rc| {
        _ = try v3_11.Suback.ResultCode.decode(rc);
    }

    // We have validated the layout of the return codes, so it's valid to do
    // this following pointer cast.
    const ptr: [*]const v3_11.Suback.ResultCode = @ptrCast(return_codes.ptr);
    return .{
        .packet_id = packet_id,
        .payload = ptr[0..return_codes.len],
    };
}

pub fn unsubscribe(decoder: *mqtt.Decoder) !struct { v3_11.Unsubscribe, v3_11.decode.UnsubDecoder } {
    const unsub = v3_11.Unsubscribe{ .packet_id = try decoder.splitPacketID() };
    const unsub_decoder = UnsubDecoder{ .inner = decoder.splitOffRest() };
    try decoder.finalize();

    return .{ unsub, unsub_decoder };
}

/// Decodes
pub fn unsuback(decoder: *mqtt.Decoder) !v3_11.Unsubscribe {
    return mqtt.decode.numbered(.unsuback, decoder);
}

/// An MQTT v3.11 Subscription decoder.
pub const SubDecoder = struct {
    const Self = @This();

    pub const Error = mqtt.Decoder.StringError || mqtt.topic.FilterError || mqtt.InvalidQos || error{InvalidSubscriptionReservedBits};

    inner: mqtt.Decoder,

    pub fn decodeNext(self: *Self) Self.Error!?v3_11.Subscription {
        if (self.inner.buf.len == 0)
            return null;

        const topic_filter = try self.inner.splitUtf8String();
        try mqtt.topic.validateFilter(topic_filter);

        const qos_byte = try self.inner.split(u8);
        const requested_qos = try mqtt.decode.qos(@truncate(qos_byte));
        // c.f. §MQTT-3-8.3-4
        if ((qos_byte >> 2) != 0)
            return error.InvalidSubscriptionReservedBits;

        return .{
            .topic_filter = topic_filter,
            .requested_qos = requested_qos,
        };
    }

    /// Returns the count of subscriptions contained within the decoder,
    /// without doing a full validation of its contents.
    pub fn count(self: *const Self) mqtt.PacketLengthMismatch!usize {
        var decoder = self.inner;
        var c: usize = 0;

        while (decoder.len() > 0) {
            _ = decoder.splitByteStr() catch return error.PacketLengthMismatch;
            _ = decoder.split(u8) catch return error.PacketLengthMismatch;
            c += 1;
        }

        return c;
    }
};

/// An MQTT v3.11 Unsubscription decoder.
pub const UnsubDecoder = struct {
    const Self = @This();

    inner: mqtt.Decoder,

    pub fn decodeNext(self: *Self) !?[]const u8 {
        if (self.inner.len() == 0)
            return null;

        const topic_filter = try self.inner.splitUtf8String();
        try mqtt.topic.validateFilter(topic_filter);
        return topic_filter;
    }

    pub fn count(self: *const Self) mqtt.PacketLengthMismatch!usize {
        var decoder = self.inner;
        var c: usize = 0;

        while (decoder.len() > 0) {
            _ = decoder.splitByteStr() catch return error.PacketLengthMismatch;
            c += 1;
        }

        return c;
    }
};

const tt = @import("std").testing;

test "decode CONNACK" {
    var decoder = mqtt.Decoder.stream(&.{ 0x20, 0x2, 0x1, 0x00 });
    const header = try mqtt.decode.header(&decoder);
    try tt.expectEqual(.connack, header.msg_type);

    var msg_decoder = try decoder.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.connack(&msg_decoder);
    try tt.expectEqual(true, msg.session_present);
    try tt.expectEqual(.connection_accepted, msg.return_code);
}

test "decode subscriptions" {
    var decoder = mqtt.v3_11.decode.SubDecoder{
        .inner = mqtt.Decoder{
            .buf = &.{ 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x02 },
        },
    };

    try tt.expectEqual(decoder.count(), 1);
    while (try decoder.decodeNext()) |sub| {
        try tt.expectEqualStrings(sub.topic_filter, "MQTT");
        try tt.expectEqual(sub.requested_qos, .exactly_once);
    }
}
