const mqtt = @import("../../mqtt.zig");

const Property = mqtt.v5_00.property.Property;

pub const PublishPropertyDecoder = Decoder(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .subscription_identifier,
    .topic_alias,
    .user_property,
});

pub const PubackPropertyDecoder = Decoder(&.{
    .reason_string,
    .user_property,
});

pub const SubscribePropertyDecoder = Decoder(&.{
    .subscription_identifier,
    .user_property,
});

pub const WillPropertyDecoder = Decoder(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .user_property,
});

fn Decoder(comptime properties: []const Property) type {
    return struct {
        const Self = @This();

        pub const Payload = mqtt.v5_00.property.Payload(properties);

        const BitSet = u16;

        const unique_properties = mqtt.v5_00.property.uniqueProperties(properties);
        comptime {
            if (unique_properties.len >= @bitSizeOf(BitSet))
                @compileError("unique properties can't be tracked with bit set size");
        }

        inner: mqtt.Decoder,
        unique_mask: BitSet = 0,

        pub fn splitOff(decoder: *mqtt.Decoder) !Self {
            const property_len = try decoder.split(mqtt.uvar);
            const inner = try decoder.splitOff(property_len);

            return .{ .inner = inner };
        }

        pub fn decodeNext(self: *Self) !?Self.Payload {
            const property = try self.decodeId() orelse return null;
            const payload = inline for (properties) |p| {
                if (property == p) {
                    const payload = self.decodePayload(p) catch
                        return error.InvalidPropertyPayload;
                    break payload;
                }
            } else unreachable;

            if (property.isUnique()) {
                const bit = Self.uniqueBit(property);
                if (self.unique_mask & bit != 0)
                    return error.InvalidDuplicateProperty;
                self.unique_mask |= bit;
            }

            return payload;
        }

        fn decodeId(self: *Self) !?Property {
            const id = self.inner.split(mqtt.uvar) catch |err| return switch (err) {
                error.PacketLengthMismatch => null,
                else => err,
            };

            for (properties) |property| {
                if (@intFromEnum(property) == id.val)
                    return property;
            }

            return error.InvalidProperty;
        }

        fn decodePayload(self: *Self, comptime property: Property) !Payload {
            const value = switch (comptime property.payload()) {
                .bool => try self.inner.splitBool(),
                .u8 => try self.inner.split(u8),
                .u16 => try self.inner.split(u16),
                .u32 => try self.inner.split(u32),
                .uvar => try self.inner.split(mqtt.uvar),
                .binary_data => try self.inner.splitByteStr(),
                .utf8_string => try self.inner.splitUtf8String(),
                .utf8_string_pair => block: {
                    const key = try self.inner.splitUtf8String();
                    const val = try self.inner.splitUtf8String();
                    break :block mqtt.v5_00.StringPair{
                        .key = key,
                        .val = val,
                    };
                },
            };

            try property.validate(value);
            return @unionInit(Payload, @tagName(property), value);
        }

        inline fn uniqueBit(property: Property) u4 {
            for (unique_properties, 0..) |unique, bit| {
                if (property == unique)
                    return @intCast(bit);
            }

            unreachable;
        }
    };
}

const testing = @import("std").testing;

test "will property payload" {
    const Payload = WillPropertyDecoder.Payload;
    try comptime testing.expectEqual(u8, @FieldType(Payload, "payload_format_indicator"));
    try comptime testing.expectEqual(u32, @FieldType(Payload, "message_expiry_interval"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "content_type"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "response_topic"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "correlation_data"));
    try comptime testing.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));
}

test "subscribe property decode" {
    const Payload = SubscribePropertyDecoder.Payload;
    try comptime testing.expectEqual(mqtt.uvar, @FieldType(Payload, "subscription_identifier"));
    try comptime testing.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));

    var decoder = mqtt.Decoder{ .buf = &.{ 0x0b, 0x00 } };
    var sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    try testing.expectError(error.InvalidPropertyPayload, sub_decoder.decodeNext());
    try testing.expect(try sub_decoder.decodeNext() == null);

    decoder = mqtt.Decoder{ .buf = &.{ 0x0b, 0x0a, 0x26, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54 } };
    sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    var next = try sub_decoder.decodeNext();
    try testing.expect(next.?.subscription_identifier.val == 0xa);
    next = try sub_decoder.decodeNext();
    const pair = next.?.user_property;
    try testing.expectEqualStrings("MQTT", pair.key);
    try testing.expectEqualStrings("MQTT", pair.val);
    try testing.expect(try sub_decoder.decodeNext() == null);
}
