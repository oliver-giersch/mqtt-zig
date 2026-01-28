const mqtt = @import("mqtt.zig");

pub const decode = @import("v5_00/decode.zig");
pub const encode = @import("v5_00/encode.zig");
pub const property = @import("v5_00/property.zig");

/// An MQTT v5 subscription.
pub const Subscription = struct {
    pub const Options = packed struct(u8) {
        requested_qos: mqtt.Qos,
        no_local: bool = false,
        retain_as_published: bool = false,
        retain_handling: enum(u2) {
            send_at_subscribe = 0,
            send_at_subscribe_if_new = 1,
            do_not_send_at_subscribe = 2,
        } = .send_at_subscribe,
        reserved: u2 = 0,
    };

    topic_filter: []const u8,
    options: Options,
};

/// An MQTT user property UTF-8 string pair.
pub const StringPair = struct {
    key: []const u8,
    val: []const u8,
};

test {
    _ = decode;
    _ = encode;
    _ = property;
}
