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
    const flags, const keep_alive = try mqtt.decode.connect.variableHeader(decoder);
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
pub fn publish(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !v3_11.Publish {
    const topic = try decoder.splitUtf8String();
    try mqtt.topic.validate(topic);

    // FIXME: Note the index of the PacketID
    const packet_id: mqtt.PacketID = if (header.msg_flags.qos.get() != 0)
        try decoder.splitPacketID()
    else
        .invalid;
    const payload = try decoder.splitUtf8StringRest();

    try decoder.finalize();
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
            _ = decoder.splitByteString() catch return error.PacketLengthMismatch;
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

const testing = @import("std").testing;

test "decode v3.11 CONNACK" {
    var streaming = mqtt.Decoder.streaming(&.{ 0x20, 0x2, 0x1, 0x00 });
    const header = try streaming.splitHeader(null);
    try testing.expectEqual(.connack, header.msg_type);

    var decoder = try streaming.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.connack(&decoder);
    try testing.expectEqual(true, msg.session_present);
    try testing.expectEqual(.connection_accepted, msg.return_code);
}

test "decode v3.11 PUBLISH" {
    const buf: []const u8 = &.{
        0x30, 0x0a, 0x00, 0x04, 0x74, 0x65,
        0x73, 0x74, 0x74, 0x65, 0x73, 0x74,
    };

    var streaming = mqtt.Decoder.streaming(buf);
    const header = try streaming.splitHeader(null);

    try testing.expectEqual(.publish, header.msg_type);
    try testing.expectEqual(false, header.msg_flags.retain);
    try testing.expectEqual(.at_most_once, header.msg_flags.qos);
    try testing.expectEqual(false, header.msg_flags.dup);
    try testing.expectEqual(10, header.remaining_len.val);

    var decoder = try streaming.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.publish(&decoder, &header);

    try testing.expectEqual(.invalid, msg.packet_id);
    try testing.expectEqualSlices(u8, "test", msg.topic);
    try testing.expectEqualSlices(u8, "test", msg.payload);
}

test "decode v3.11 PUBLISH qos 2" {
    const buf: []const u8 = &.{
        0x34, 0x14, 0x00, 0x05, 0x61, 0x2F, 0x62, 0x2F, 0x63, 0x00, 0x01,
        0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64,
    };

    var streaming = mqtt.Decoder.streaming(buf);
    const header = try streaming.splitHeader(null);

    try testing.expectEqual(.publish, header.msg_type);
    try testing.expectEqual(false, header.msg_flags.retain);
    try testing.expectEqual(.exactly_once, header.msg_flags.qos);
    try testing.expectEqual(false, header.msg_flags.dup);
    try testing.expectEqual(20, header.remaining_len.val);

    var decoder = try streaming.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.publish(&decoder, &header);

    try testing.expectEqual(mqtt.PacketID.from(1) catch unreachable, msg.packet_id);
    try testing.expectEqualSlices(u8, "a/b/c", msg.topic);
    try testing.expectEqualSlices(u8, "hello world", msg.payload);
}

test "decode incomplete message(s)" {
    const buf: []const u8 = &.{
        0x10, 0x10, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3c, 0x00,
        0x04, 0x44, 0x49, 0x47, 0x49, 0x30, 0x0a, 0x00, 0x04, 0x74, 0x65, 0x73,
    };

    var streaming = mqtt.Decoder.streaming(buf);
    const header = try streaming.splitHeader(null);

    try testing.expectEqual(.connect, header.msg_type);
    try testing.expectEqual(16, header.remaining_len.val);

    var decoder = try streaming.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.connect(&decoder, true);

    try testing.expectEqual("DIGI", msg.client_id);

    const next_header = try streaming.splitHeader(null);

    try testing.expectEqual(.publish, next_header.msg_type);
    try testing.expectEqual(16, next_header.remaining_len.val);

    const result = streaming.splitPacket(&next_header);

    try testing.expectError(error.IncompleteBuffer, result);
}

test "decode subscriptions" {
    var decoder = mqtt.v3_11.decode.SubDecoder{
        .inner = mqtt.Decoder{
            .buf = &.{ 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x02 },
        },
    };

    try testing.expectEqual(decoder.count(), 1);
    while (try decoder.decodeNext()) |sub| {
        try testing.expectEqualStrings(sub.topic_filter, "MQTT");
        try testing.expectEqual(sub.requested_qos, .exactly_once);
    }
}
