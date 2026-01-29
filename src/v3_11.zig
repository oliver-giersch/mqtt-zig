const mqtt = @import("mqtt.zig");

/// The namespace for MQTT 3.11 specific message decoding functions.
pub const decode = @import("v3_11/decode.zig");
/// The namespace for MQTT 3.11 specific message encoding functions.
pub const encode = @import("v3_11/encode.zig");

/// The decoded MQTT v3.11 CONNECT message contents.
pub const Connect = struct {
    clean_session: bool,
    will: ?mqtt.Will,
    auth: ?mqtt.Auth,
    keep_alive: u16,
    /// The desired session client ID.
    client_id: []const u8,
};

/// The decoded MQTT v3.11 CONNACK message contents.
pub const Connack = struct {
    /// The return code sent in a CONNACK packet.
    pub const ReturnCode = enum(u8) {
        /// The connection was succesfully accepted.
        connection_accepted = 0x00,
        /// The supplied protocol version is unsupported by the server.
        unacceptable_protocol_version = 0x01,
        /// The server rejected the client ID.
        identifier_rejected = 0x02,
        /// The server is unavailable.
        server_unavailable = 0x03,
        /// The client's supplied authorization was malformed.
        malformed_auth = 0x04,
        not_authorized = 0x05,
    };

    session_present: bool,
    return_code: Connack.ReturnCode,
};

/// The decoded MQTT v3.11 PUBLISH message contents.
pub const Publish = struct {
    /// The PUBLISH message's specific flags.
    flags: mqtt.MessageFlags,
    /// The MQTT topic string.
    topic: []const u8,
    /// The MQTT packet ID.
    packet_id: mqtt.PacketID,
    /// The binary MQTT message payload.
    payload: []const u8,
};

/// An MQTT v3.11 PUBACK packet.
pub const Puback = mqtt.NumberedPacket(.puback);

/// An MQTT v3.11  PUBREL packet.
pub const Pubrel = mqtt.NumberedPacket(.pubrel);

/// An MQTT v3.11 PUBCOMP packet.
pub const Pubcomp = mqtt.NumberedPacket(.pubcomp);

/// An MQTT v3.11 SUBSCRIBE packet.
pub const Subscribe = mqtt.Subscribe;

pub const Subscription = struct {
    topic_filter: []const u8,
    requested_qos: mqtt.Qos,
};

/// An MQTT v3.11 SUBACK packet.
pub const Suback = struct {
    pub const ResultCode = enum(u8) {
        max_qos_0 = 0x00,
        max_qos_1 = 0x01,
        max_qos_2 = 0x02,
        failure = 0x80,

        pub fn encode(maybe_qos: ?mqtt.Qos) Suback.ResultCode {
            if (maybe_qos) |qos|
                return @enumFromInt(@intFromEnum(qos));
            return .failure;
        }

        pub fn decode(rc: u8) !Suback.ResultCode {
            return switch (rc) {
                0x00, 0x01, 0x02, 0x80 => @enumFromInt(rc),
                else => error.InvalidSubackCode,
            };
        }

        pub fn getQos(self: ResultCode) ?mqtt.Qos {
            return switch (self) {
                .max_qos_0, .max_qos_1, .max_qos_2 => @enumFromInt(@intFromEnum(self)),
                else => null,
            };
        }
    };

    packet_id: mqtt.PacketId,
    payload: []const Suback.ResultCode,
};

/// The decoded MQTT v3.11 UNSUBSCRIBE message contents.
pub const Unsubscribe = mqtt.NumberedPacket(.unsubscribe);

/// The decoded MQTT v3.11 UNSUBACK message contents.
pub const Unsuback = mqtt.NumberedPacket(.unsuback);

test {
    _ = decode;
    _ = encode;
}
