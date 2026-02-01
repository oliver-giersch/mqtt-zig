const mqtt = @import("mqtt.zig");

pub const decode = @import("v5_00/decode.zig");
pub const encode = @import("v5_00/encode.zig");
pub const property = @import("v5_00/property.zig");

/// An MQTT user property UTF-8 string pair.
pub const StringPair = struct {
    key: []const u8,
    val: []const u8,
};

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

test {
    _ = decode;
    _ = encode;
    _ = property;
}
