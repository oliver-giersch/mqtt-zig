const mqtt = @import("../mqtt.zig");

pub const property = @import("decode/property.zig");

pub fn subscribe(decoder: *mqtt.Decoder) !struct { mqtt.Subscribe, property.SubscribePropertyDecoder, SubDecoder } {
    const sub = mqtt.Subscribe { .packet_id = try decoder.splitPacketId() };
    const property_len = try decoder.split(mqtt.uvar);
    const property_decoder = property.SubscribePropertyDecoder{
        .inner = decoder.splitOff(property_len.val)
    };

    const sub_decoder = SubDecoder{ };
    try decoder.finalize();

    return .{ sub, property_decoder, sub_decoder };
}

pub const SubDecoder = struct {
    const Self = @This();
};

test {
    _ = property;
}