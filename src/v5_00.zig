const mqtt = @import("mqtt.zig");

pub const decode = @import("v5_00/decode.zig");
pub const encode = @import("v5_00/encode.zig");

pub const Property = property.Property;
pub const ConnectProperty = property.ConnectProperty;
pub const WillProperty = property.WillProperty;
pub const PublishProperty = property.PublishProperty;
pub const PubackProperty = property.PubackProperty;
pub const SubscribeProperty = property.SubscribeProperty;

const property = @import("v5_00/property.zig");

/// The decoded MQTT v5 CONNECT message contents.
pub const Connect = struct {
    clean_start: bool,
    will: ?struct { mqtt.Will, decode.WillPropertyDecoder },
    auth: ?mqtt.Auth,
    keep_alive: u16,
    /// The desired session client ID.
    client_id: []const u8,
};

/// The decoded MQTT v5 CONNACK message contents.
pub const Connack = struct {
    /// The return code sent in a CONNACK packet.
    pub const ReturnCode = enum(u8) {
        success = 0x00,
        unspecified_error = 0x80,
        malformed_packet = 0x81,
        protocol_error = 0x82,
        implementation_specific_error = 0x83,
        unsupported_protocol_version = 0x84,
        invalid_client_id = 0x85,
        bad_username_or_password = 0x86,
        not_authorized = 0x87,
        server_unavailable = 0x88,
        server_busy = 0x89,
        banned = 0x8A,
        bad_auth_method = 0x8C,
        invalid_topic_name = 0x90,
        packet_too_large = 0x95,
        quota_exceeded = 0x97,
        invalid_payload_format = 0x99,
        qos_not_supported = 0x9B,
        use_another_server = 0x9C,
        server_moved = 0x9D,
        connection_rate_exceeded = 0x9F,
    };

    session_present: bool,
    return_code: Connack.ReturnCode,
};

/// The decoded MQTT v5 PUBLISH message contents.
pub const Publish = mqtt.Publish;

/// An MQTT v5 PUBACK packet.
pub const Puback = struct {
    pub const ReasonCode = enum(u8) {
        success = 0x0,
        no_matching_subscribers = 0x10,
        unspecified_error = 0x80,
        implementation_specific_error = 0x83,
        not_authorized = 0x87,
        topic_name_invalid = 0x90,
        packet_id_in_use = 0x91,
        quota_exceeded = 0x97,
        payload_format_invalid = 0x99,
    };

    packet_id: mqtt.PacketID,
    reason_code: Puback.ReasonCode,
};

/// A MQTT v5 subscription.
pub const Subscription = struct {
    pub const Options = packed struct(u8) {
        pub const Retain = enum(u2) {
            send_at_subscribe = 0,
            send_at_subscribe_if_new = 1,
            do_not_send_at_subscribe = 2,
        };

        requested_qos: mqtt.Qos,
        no_local: bool = false,
        retain_as_published: bool = false,
        retain_handling: Options.Retain = .send_at_subscribe,
        reserved: u2 = 0,
    };

    topic_filter: []const u8,
    options: Options,
};

/// An MQTT v5 user property UTF-8 string pair.
pub const StringPair = struct {
    key: []const u8,
    val: []const u8,
};

/// The MQTT v5 payload format indicator.
pub const PayloadFormat = enum(u1) {
    /// The payload format is an unspecified binary string.
    binary = 0,
    /// The payload format is UTF-8.
    utf_8 = 1,
};

pub const InvalidPropertyID = error{InvalidPropertyID};
pub const InvalidPropertyPayload = error{InvalidPropertyPayload};
pub const InvalidZeroValue = error{InvalidZeroValue};

test {
    _ = decode;
    _ = encode;
    _ = Property;
}
