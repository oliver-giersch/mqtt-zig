const mqtt = @import("../mqtt.zig");

const std = @import("std");

const v3_11 = mqtt.v3_11;

pub const connect = struct {
    pub fn validate(msg: *const v3_11.Connect) !struct { mqtt.uvar, usize } {
        var remaining_len: usize = 1 + @sizeOf(u16);

        const id_len = try mqtt.encode.stringBytes(msg.client_id);
        try mqtt.string.validate(msg.client_id);
        remaining_len = try mqtt.encode.checkedAdd(remaining_len, id_len);

        if (msg.will) |will| {
            const topic_len = try mqtt.encode.stringBytes(will.topic);
            try mqtt.string.validate(will.topic);
            remaining_len = try mqtt.encode.checkedAdd(remaining_len, topic_len);

            const payload_len = try mqtt.encode.stringBytes(will.payload);
            remaining_len = try mqtt.encode.checkedAdd(remaining_len, payload_len);
        }

        if (msg.auth) |auth| {
            const user, const maybe_pass = auth.strings();
            const user_len = try mqtt.encode.stringBytes(user);
            try mqtt.string.validate(user);

            remaining_len = try mqtt.encode.checkedAdd(remaining_len, user_len);
            if (maybe_pass) |pass| {
                const pass_len = try mqtt.encode.stringBytes(pass);
                remaining_len = try mqtt.encode.checkedAdd(remaining_len, pass_len);
            }
        }

        return mqtt.encode.packetSize(remaining_len);
    }

    pub fn populate(
        msg: *const v3_11.Connect,
        remaining_len: mqtt.uvar,
        buf: []u8,
    ) void {
        var header = msgHeader(.connect);
        header.remaining_len = remaining_len;

        var encoder = mqtt.Encoder{ .buf = buf };
        encoder.writeHeader(&header);
        encoder.writeU8(@bitCast(connectFlags(msg)));
        encoder.writeU16(msg.keep_alive);

        if (msg.will) |will| {
            encoder.writeByteStr(will.topic);
            encoder.writeByteStr(will.payload);
        }

        if (msg.auth) |auth| {
            const user, const maybe_pass = auth.strings();
            encoder.writeByteStr(user);
            if (maybe_pass) |pass| encoder.writeByteStr(pass);
        }
    }
};

pub const connack = struct {
    pub fn populate(msg: *const v3_11.Connack, buf: *[4]u8) !void {
        if (msg.session_present and msg.return_code != .connection_accepted)
            return error.InvalidConnack;

        var header = msgHeader(.connack);
        header.remaining_len = mqtt.uvar{ .val = 2 };

        var encoder = mqtt.Encoder{ .buf = buf[0..] };
        encoder.writeHeader(&header);
        encoder.writeU8(@intFromBool(msg.session_present));
        encoder.writeU8(@intFromEnum(msg.return_code));
    }
};

pub const publish = struct {
    pub fn alloc(
        allocator: std.mem.Allocator,
        msg: *const v3_11.Publish,
    ) ![]u8 {
        const remaining_len, const bytes = try publish.validate(msg);
        const buf = try allocator.alloc(u8, bytes);
        publish.populate(msg, remaining_len, buf);
        return buf;
    }

    pub fn validate(msg: *const v3_11.Publish) !struct { mqtt.uvar, usize } {
        var remaining_len: usize = block: {
            if (msg.flags.qos == .at_most_once) {
                if (msg.packet_id != mqtt.no_packet_id)
                    return error.InvalidPacketId;
                break :block 0;
            } else {
                if (msg.packet_id == mqtt.no_packet_id)
                    return error.InvalidPacketId;
                break :block @sizeOf(mqtt.PacketId);
            }
        };

        const topic_len = try mqtt.encode.stringBytes(msg.topic);
        try mqtt.topic.validate(msg.topic);

        remaining_len = try mqtt.encode.checkedAdd(remaining_len, topic_len);
        remaining_len = try mqtt.encode.checkedAdd(remaining_len, msg.payload.len);

        return mqtt.encode.packetSize(remaining_len);
    }

    pub fn populate(msg: *const v3_11.Publish, remaining_len: mqtt.uvar, buf: []u8) void {
        const header = mqtt.Header{
            .msg_type = .publish,
            .msg_flags = msg.flags,
            .remaining_len = remaining_len,
        };

        var encoder = mqtt.Encoder{ .buf = buf };
        encoder.writeHeader(&header);
        encoder.writeByteStr(msg.topic);
        if (msg.flags.qos != .at_most_once)
            encoder.writeU16(msg.packet_id);

        @memcpy(encoder.buf, msg.payload);
    }
};

pub const subscribe = struct {
    pub fn alloc(
        allocator: std.mem.Allocator,
        msg: *const v3_11.Subscribe,
        subs: []const v3_11.Subscription,
    ) ![]u8 {
        const remaining_len, const bytes = try validate(msg, subs);
        const buf = try allocator.alloc(u8, bytes);
        populate(msg, subs, remaining_len, buf);
        return buf;
    }

    /// Validates the given SUBSCRIBE message contents and returns the total
    /// size in bytes of the encoded packet as well as the "remaining length"
    /// encoded in the message header.
    pub fn validate(
        msg: *const v3_11.Subscribe,
        subs: []const v3_11.Subscription,
    ) !struct { mqtt.uvar, usize } {
        if (msg.packet_id == mqtt.no_packet_id)
            return error.InvalidPacketId;

        var remaining_len: usize = @sizeOf(mqtt.PacketId);
        for (subs) |*sub| {
            const filter_len = try mqtt.encode.stringBytes(sub.topic_filter);
            try mqtt.string.validate(sub.topic_filter);
            try mqtt.topic.validate(sub.topic_filter);

            remaining_len = try mqtt.encode.checkedAdd(remaining_len, filter_len);
        }

        return mqtt.encode.packetSize(remaining_len);
    }

    /// Populates the given `buf` with the SUBSCRIBE message contents.
    ///
    /// Performs no validation and should only be called after calling
    /// `mqtt.v3_11.encode.subscribe.validate`.
    ///
    /// Expects `buf` to hold exactly the number of bytes returned by
    /// `validate`.
    pub fn populate(
        msg: *const v3_11.Subscribe,
        subs: []const v3_11.Subscription,
        remaining_len: mqtt.uvar,
        buf: []u8,
    ) void {
        var header = msgHeader(.subscribe);
        header.remaining_len = remaining_len;

        var encoder = mqtt.Encoder{ .buf = buf };
        encoder.writeHeader(&header);
        encoder.writeU16(msg.packet_id);

        for (subs) |*sub| {
            encoder.writeByteStr(sub.topic_filter);
            encoder.writeU8(@intFromEnum(sub.requested_qos));
        }
    }
};

fn connectFlags(msg: *const mqtt.v3_11.Connect) mqtt.ConnectFlags {
    var flags: mqtt.ConnectFlags = @bitCast(@as(u8, 0));

    if (msg.clean_session)
        flags.clean_session = true;
    if (msg.will) |*will| {
        flags.will_flag = true;
        flags.will_retain = will.retain;
        flags.will_qos = will.qos;
    }
    if (msg.auth) |*auth| {
        flags.user_flag = true;
        if (auth.* == .full)
            flags.pass_flag = true;
    }

    return flags;
}

inline fn msgHeader(comptime msg_type: mqtt.MsgType) mqtt.Header {
    const msg_flags = comptime mqtt.MsgFlags.requiredFor(msg_type) orelse
        @compileError("no predescribed message flags for message type " ++ @tagName(msg_type));
    return .{
        .msg_flags = msg_flags,
        .msg_type = msg_type,
        .remaining_len = undefined,
    };
}

const tt = @import("std").testing;

test "encode conenct" {
    const msg = mqtt.v3_11.Connect{
        .clean_session = true,
        .will = null,
        .auth = null,
        .keep_alive = 0,
        .client_id = "MQTT",
    };

    var buf: [64]u8 = undefined;

    const remaining_len, const bytes = try mqtt.v3_11.encode.connect.validate(&msg);
    mqtt.v3_11.encode.connect.populate(&msg, remaining_len, buf[0..bytes]);
}
