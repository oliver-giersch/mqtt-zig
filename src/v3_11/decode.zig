//! Decoding of MQTT v3.11 messages.

const mqtt = @import("../mqtt.zig");

const v3_11 = mqtt.v3_11;

/// Decodes a CONNECT message.
///
/// Asserts, that the decoder has already split off and validated the MQTT
/// protocol version.
pub fn connect(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
    strict: bool,
) !v3_11.Connect {
    mqtt.assert(header.msg_type == .connect);
    mqtt.assert(decoder.len() == header.remaining_len.val - mqtt.Version.byte_count);

    const flags, const keep_alive = try mqtt.decode.connect.variableHeader(decoder);
    const client_id = try decoder.splitUtf8String();
    mqtt.validateClientID(client_id, strict) catch return error.InvalidClientId;

    // Decode the optional client will message.
    const will = if (flags.will_flag)
        try mqtt.decode.connect.will(decoder, flags)
    else
        null;

    // Decode the optional client authentication data.
    const auth = if (flags.user_flag)
        try mqtt.decode.connect.auth(decoder, flags)
    else
        null;

    try decoder.finalize();
    return .{
        .clean_session = flags.clean_session,
        .will = will,
        .auth = auth,
        .keep_alive = keep_alive,
        .client_id = client_id,
    };
}

/// Decodes an CONNACK message in `decoder`.
pub fn connack(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !v3_11.Connack {
    mqtt.assert(header.msg_type == .connack);

    const session_present = try decoder.splitBool();
    const return_code = mqtt.decode.code(
        v3_11.Connack.ReturnCode,
        try decoder.split(u8),
    ) orelse return error.InvalidReturnCode;

    try decoder.finalize();
    return .{
        .session_present = session_present,
        .return_code = return_code,
    };
}

/// Decodes an PUBLISH message contained in `decoder`.
pub fn publish(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
    id_idx: ?*u32,
) !v3_11.Publish {
    mqtt.assert(header.msg_type == .publish);

    const topic, const packet_id = try mqtt.decode.publish.variableHeader(
        decoder,
        header,
        id_idx,
    );
    const payload = try decoder.splitUtf8StringRest();

    try decoder.finalize();
    return .{
        .flags = header.msg_flags,
        .topic = topic,
        .packet_id = packet_id,
        .payload = payload,
    };
}

pub fn puback(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !v3_11.Puback {
    mqtt.assert(header.msg_type == .puback);
    return mqtt.decode.stateless(.puback, decoder);
}

pub fn pubrel(decoder: *mqtt.Decoder) !v3_11.Pubrel {
    return mqtt.decode.stateless(.pubrel, decoder);
}

pub fn pubcomp(decoder: *mqtt.Decoder) !v3_11.Pubcomp {
    return mqtt.decode.stateless(.pubcomp, decoder);
}

/// Decodes a SUBSCRIBE message contained in `decoder`.
///
/// Returns the message contents and a decoding iterator for the individual
/// subscriptions.
///
/// # Example
///
/// ```
/// var streaming = mqtt.Decoder.streaming(buf);
/// const header = try streaming.splitHeader(.subscribe);
/// var decoder = try streaming.splitPacket(&header);
/// const msg, var sub_decoder = try mqtt.v3_11.decode.subscribe(&decoder, &header);
///
/// var subs: [8]mqtt.v3_11.Subscription = undefined;
/// var i: usize = 0;
/// while (try sub_decoder.decodeNext()) |sub| {
///     subs[i] = sub;
///     i += 1;
///
///     if (i == subs.len)
///         return error.OutOfMemory;
/// }
/// ```
pub fn subscribe(
    decoder: *mqtt.Decoder,
    header: *const mqtt.Header,
) !struct { v3_11.Subscribe, v3_11.decode.SubscribeDecoder } {
    mqtt.assert(header.msg_type == .subscribe);

    const sub = mqtt.Subscribe{ .packet_id = try decoder.splitPacketID() };
    const sub_decoder = SubscribeDecoder{ .inner = decoder.splitOffRest() };

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

pub fn unsubscribe(
    decoder: *mqtt.Decoder,
) !struct { v3_11.Unsubscribe, v3_11.decode.UnsubDecoder } {
    const unsub = v3_11.Unsubscribe{ .packet_id = try decoder.splitPacketID() };
    const unsub_decoder = UnsubDecoder{ .inner = decoder.splitOffRest() };
    try decoder.finalize();

    return .{ unsub, unsub_decoder };
}

/// Decodes
pub fn unsuback(decoder: *mqtt.Decoder) !v3_11.Unsubscribe {
    return mqtt.decode.stateless(.unsuback, decoder);
}

/// An MQTT v3.11 Subscription decoder.
pub const SubscribeDecoder = struct {
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
        // c.f. §MQTT-3-8.3-4: remaining bits must be zeroed
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
            _ = try decoder.splitByteString();
            _ = try decoder.split(u8);
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
    var streaming = mqtt.Decoder.streaming(&.{ 0x20, 0x02, 0x01, 0x00 });
    const header = try streaming.splitHeader(null);
    try testing.expectEqual(.connack, header.msg_type);

    var decoder = try streaming.splitPacket(&header);
    const msg = try mqtt.v3_11.decode.connack(&decoder, &header);
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
    const msg = try mqtt.v3_11.decode.publish(&decoder, &header, null);

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
    const msg = try mqtt.v3_11.decode.publish(&decoder, &header, null);

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
    _ = try mqtt.decode.connect.version(&decoder);
    const msg = try mqtt.v3_11.decode.connect(&decoder, &header, true);

    try testing.expectEqualStrings("DIGI", msg.client_id);

    const next_header = try streaming.splitHeader(null);

    try testing.expectEqual(.publish, next_header.msg_type);
    try testing.expectEqual(10, next_header.remaining_len.val);

    const result = streaming.splitPacket(&next_header);

    try testing.expectError(error.IncompleteBuffer, result);
}

test "decode subscriptions" {
    var decoder = mqtt.v3_11.decode.SubscribeDecoder{
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
